import XCTest
@testable import MobaXTerm

final class ZmodemTests: XCTestCase {
    func testCRC16MatchesWaitingReceiver() {
        let body: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x23]
        XCTAssertEqual(ZmodemCRC.crc16(body), 0xBE50)
    }

    func testScannerReadsHexZRINIT() {
        var scanner = ZmodemScanner()
        let events = scanner.feed(Array("**\u{18}B0100000023be50\r\n".utf8))
        guard case let .header(header) = events.first else {
            return XCTFail("missing header")
        }
        XCTAssertEqual(header.type, ZmodemKind.zrinit)
        XCTAssertTrue(header.acceptsCRC32)
        XCTAssertEqual(header.position, 0x2300_0000)
    }

    func testRoundTripEscapesControlsAndRestoresBytes() throws {
        var payload = [UInt8](0...255)
        payload.append(contentsOf: Array(repeating: 0x18, count: 3))
        payload.append(contentsOf: [0x00, 0x0D, 0x11, 0x13, 0x7F, 0xFF])
        let file = ZmodemFile(name: "blob.bin", bytes: payload, modified: Date(timeIntervalSince1970: 1_700_000_000), mode: 0o100644)
        let received = try transfer([file])
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].name, "blob.bin")
        XCTAssertEqual(received[0].bytes, payload)
    }

    func testHighBytesStayUnescaped() {
        var encoder = ZmodemEncoder()
        let frame = ZmodemFrames.subpacket(
            [0xFF, 0x7F, 0xE5, 0x89, 0x41, 0x18],
            frameEnd: ZmodemKind.zcrce,
            crc32: true,
            encoder: &encoder
        )
        XCTAssertEqual(Array(frame.prefix(7)), [0xFF, 0x7F, 0xE5, 0x89, 0x41, 0x18, 0x58])
    }

    func testCarriageReturnAfterAtIsEscaped() {
        var encoder = ZmodemEncoder()
        let escaped = ZmodemFrames.subpacket([0x40, 0x0D], frameEnd: ZmodemKind.zcrce, crc32: true, encoder: &encoder)
        XCTAssertEqual(Array(escaped.prefix(3)), [0x40, 0x18, 0x4D])
        var plain = ZmodemEncoder()
        let raw = ZmodemFrames.subpacket([0x41, 0x0D], frameEnd: ZmodemKind.zcrce, crc32: true, encoder: &plain)
        XCTAssertEqual(Array(raw.prefix(2)), [0x41, 0x0D])
    }

    func testUTF8NameAndBinaryPayload() throws {
        let name = "副本MS 功能列表.xlsx"
        var payload = [UInt8](repeating: 0xFF, count: 300)
        payload.append(contentsOf: [0x00, 0x0A, 0x7F, 0x89, 0xE5])
        let file = ZmodemFile(name: name, bytes: payload, modified: Date(timeIntervalSince1970: 1_700_000_000), mode: 0o100644)
        let received = try transfer([file])
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].name, name)
        XCTAssertEqual(received[0].bytes, payload)
    }

    func testReportsProgressWhileSending() {
        var encoder = ZmodemEncoder()
        let zrpos = ZmodemFrames.binaryHeader(
            type: ZmodemKind.zrpos,
            b0: 0,
            b1: 0,
            b2: 0,
            b3: 0,
            crc32: true,
            encoder: &encoder
        )
        let file = ZmodemFile(
            name: "报表.pdf",
            bytes: [UInt8](repeating: 0x61, count: 1500),
            modified: Date(timeIntervalSince1970: 10),
            mode: 0
        )
        let sender = ZmodemSender(files: [file])
        let started = sender.start()
        XCTAssertEqual(started.progress?.phase, .waiting)
        XCTAssertEqual(started.progress?.name, "报表.pdf")
        let offered = sender.receive(ZmodemFrames.hexHeader(type: ZmodemKind.zrinit, b0: 0, b1: 0, b2: 0, b3: 0x23))
        XCTAssertEqual(offered.progress?.phase, .sending)
        XCTAssertEqual(offered.progress?.sent, 0)
        let chunk = sender.receive(zrpos)
        XCTAssertEqual(chunk.progress?.sent, 1024)
        XCTAssertEqual(chunk.progress?.total, 1500)
    }

    func testSplitsAboveOneSubpacket() throws {
        let payload = [UInt8](repeating: 0x41, count: 2500)
        let file = ZmodemFile(name: "big.txt", bytes: payload, modified: Date(timeIntervalSince1970: 10), mode: 0)
        let received = try transfer([file])
        XCTAssertEqual(received.first?.bytes, payload)
    }

    private func transfer(_ files: [ZmodemFile]) throws -> [(name: String, bytes: [UInt8])] {
        let sender = ZmodemSender(files: files)
        var receiver = FakeReceiver()
        var incoming = ZmodemFrames.hexHeader(type: ZmodemKind.zrinit, b0: 0, b1: 0, b2: 0, b3: 0x23)
        for _ in 0..<40 {
            let step = sender.receive(incoming)
            if let failure = step.failure {
                XCTFail(failure)
                return []
            }
            if step.finished != nil {
                return receiver.files
            }
            incoming = receiver.accept(step.outgoing)
            if incoming.isEmpty, step.outgoing.isEmpty {
                XCTFail("transfer stalled")
                return []
            }
        }
        XCTFail("transfer did not finish")
        return []
    }
}

private final class FakeReceiver {
    var files: [(name: String, bytes: [UInt8])] = []
    private var scanner = ZmodemScanner()
    private var encoder = ZmodemEncoder()
    private var collecting = false
    private var current = [UInt8]()
    private var name = ""

    func accept(_ outgoing: [UInt8]) -> [UInt8] {
        var reply: [UInt8] = []
        for event in scanner.feed(outgoing) {
            switch event {
            case let .header(header):
                if header.type == ZmodemKind.zfile {
                    collecting = false
                } else if header.type == ZmodemKind.zdata {
                    collecting = true
                } else if header.type == ZmodemKind.zeof {
                    files.append((name, current))
                    current = []
                    reply.append(contentsOf: ZmodemFrames.hexHeader(type: ZmodemKind.zrinit, b0: 0, b1: 0, b2: 0, b3: 0x23))
                } else if header.type == ZmodemKind.zfin {
                    reply.append(contentsOf: ZmodemFrames.hexHeader(type: ZmodemKind.zfin, b0: 0, b1: 0, b2: 0, b3: 0))
                }
            case let .packet(data, frameEnd):
                if collecting {
                    current.append(contentsOf: data)
                    if frameEnd == ZmodemKind.zcrcw {
                        let position = ZmodemFrames.position(current.count)
                        reply.append(contentsOf: ZmodemFrames.hexHeader(
                            type: ZmodemKind.zack,
                            b0: position.0,
                            b1: position.1,
                            b2: position.2,
                            b3: position.3
                        ))
                    }
                } else if frameEnd == ZmodemKind.zcrcw {
                    if let zero = data.firstIndex(of: 0) {
                        name = String(bytes: data[..<zero], encoding: .utf8) ?? ""
                    }
                    reply.append(contentsOf: ZmodemFrames.binaryHeader(
                        type: ZmodemKind.zrpos,
                        b0: 0,
                        b1: 0,
                        b2: 0,
                        b3: 0,
                        crc32: true,
                        encoder: &encoder
                    ))
                }
            case .abort:
                break
            }
        }
        return reply
    }
}
