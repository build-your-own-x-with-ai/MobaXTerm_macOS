import Foundation

enum ZmodemKind {
    static let zrinit: UInt8 = 1
    static let zack: UInt8 = 3
    static let zfile: UInt8 = 4
    static let zskip: UInt8 = 5
    static let znak: UInt8 = 6
    static let zabort: UInt8 = 7
    static let zfin: UInt8 = 8
    static let zrpos: UInt8 = 9
    static let zdata: UInt8 = 10
    static let zeof: UInt8 = 11
    static let zcrce: UInt8 = 0x68
    static let zcrcg: UInt8 = 0x69
    static let zcrcq: UInt8 = 0x6A
    static let zcrcw: UInt8 = 0x6B
    static let zpad: UInt8 = 0x2A
    static let zdle: UInt8 = 0x18
    static let zbin: UInt8 = 0x41
    static let zhex: UInt8 = 0x42
    static let zbin32: UInt8 = 0x43
    static let zcbin: UInt8 = 1
    static let zmclob: UInt8 = 4
    static let canfc32: UInt8 = 0x20
}

enum ZmodemCRC {
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                if crc & 0x8000 != 0 {
                    crc = (crc << 1) ^ 0x1021
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    /// Complemented CRC-32. lrzsz writes these four bytes little-endian.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        ~runningCRC32(bytes)
    }

    /// Value left in the register after consuming a frame and its CRC bytes.
    static func residue32(_ bytes: [UInt8]) -> UInt32 {
        runningCRC32(bytes)
    }

    private static func runningCRC32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB8_8320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }
}

struct ZmodemHeader {
    var type: UInt8
    var b0: UInt8
    var b1: UInt8
    var b2: UInt8
    var b3: UInt8

    var position: Int {
        Int(b0) | (Int(b1) << 8) | (Int(b2) << 16) | (Int(b3) << 24)
    }

    /// CANFC32 is the last byte of a ZRINIT header.
    var acceptsCRC32: Bool {
        b3 & ZmodemKind.canfc32 != 0
    }
}

enum ZmodemEvent {
    case header(ZmodemHeader)
    case packet(data: [UInt8], frameEnd: UInt8)
    case abort
}

/// Pulls headers, and the data subpackets that follow ZFILE or ZDATA, out of a byte stream.
struct ZmodemScanner {
    private var buffer: [UInt8] = []
    private var dataCRC32 = true
    private var expectingPacket = false

    mutating func feed(_ bytes: [UInt8]) -> [ZmodemEvent] {
        buffer.append(contentsOf: bytes)
        var events: [ZmodemEvent] = []
        var index = 0
        while index < buffer.count {
            if expectingPacket {
                switch takePacket(from: index) {
                case .needMore:
                    buffer.removeFirst(index)
                    return events
                case .invalid:
                    expectingPacket = false
                    index += 1
                case let .found(event, next):
                    events.append(event)
                    index = next
                }
                continue
            }
            if buffer[index] == ZmodemKind.zdle, cancelRun(at: index) >= 5 {
                let run = cancelRun(at: index)
                events.append(.abort)
                index += run
                continue
            }
            guard buffer[index] == ZmodemKind.zpad else {
                index += 1
                continue
            }
            switch takeHeader(from: index) {
            case .needMore:
                buffer.removeFirst(index)
                return events
            case .invalid:
                index += 1
            case let .found(event, next):
                events.append(event)
                if case let .header(header) = event,
                   header.type == ZmodemKind.zfile || header.type == ZmodemKind.zdata {
                    expectingPacket = true
                }
                index = next
            }
        }
        buffer.removeAll(keepingCapacity: true)
        return events
    }

    private func cancelRun(at index: Int) -> Int {
        var run = 0
        while index + run < buffer.count, buffer[index + run] == ZmodemKind.zdle {
            run += 1
        }
        return run
    }

    private mutating func takeHeader(from start: Int) -> Scan {
        var index = start
        while index < buffer.count, buffer[index] == ZmodemKind.zpad {
            index += 1
        }
        guard index < buffer.count else { return .needMore }
        guard buffer[index] == ZmodemKind.zdle else { return .invalid }
        guard index + 1 < buffer.count else { return .needMore }
        switch buffer[index + 1] {
        case ZmodemKind.zhex:
            return takeHexHeader(from: index + 2)
        case ZmodemKind.zbin:
            dataCRC32 = false
            return takeBinaryHeader(from: index + 2, crcBytes: 2)
        case ZmodemKind.zbin32:
            dataCRC32 = true
            return takeBinaryHeader(from: index + 2, crcBytes: 4)
        default:
            return .invalid
        }
    }

    private func takeHexHeader(from start: Int) -> Scan {
        var index = start
        var digits: [UInt8] = []
        while index < buffer.count, digits.count < 14 {
            let byte = buffer[index]
            if isHex(byte) {
                digits.append(byte)
                index += 1
                continue
            }
            if byte == 0x0D || byte == 0x0A || byte == 0x11 || byte == 0x7F {
                index += 1
                continue
            }
            return .invalid
        }
        guard digits.count == 14 else { return .needMore }
        var decoded: [UInt8] = []
        var pair = 0
        while pair < 14 {
            guard let high = hexValue(digits[pair]), let low = hexValue(digits[pair + 1]) else {
                return .invalid
            }
            decoded.append((high << 4) | low)
            pair += 2
        }
        let body = Array(decoded.prefix(5))
        let claimed = (UInt16(decoded[5]) << 8) | UInt16(decoded[6])
        guard ZmodemCRC.crc16(body) == claimed else { return .invalid }
        return .found(.header(header(from: body)), index)
    }

    private func takeBinaryHeader(from start: Int, crcBytes: Int) -> Scan {
        switch readEscaped(from: start, count: 5 + crcBytes) {
        case .needMore:
            return .needMore
        case .invalid:
            return .invalid
        case let .bytes(payload, next):
            let body = Array(payload.prefix(5))
            if crcBytes == 4 {
                guard ZmodemCRC.residue32(payload) == 0xDEBB_20E3 else { return .invalid }
            } else {
                let claimed = (UInt16(payload[5]) << 8) | UInt16(payload[6])
                guard ZmodemCRC.crc16(body) == claimed else { return .invalid }
            }
            return .found(.header(header(from: body)), next)
        }
    }

    private mutating func takePacket(from start: Int) -> Scan {
        var index = start
        var data: [UInt8] = []
        while index < buffer.count {
            let byte = buffer[index]
            if byte != ZmodemKind.zdle {
                data.append(byte)
                index += 1
                continue
            }
            guard index + 1 < buffer.count else { return .needMore }
            let marker = buffer[index + 1]
            if marker == ZmodemKind.zcrce || marker == ZmodemKind.zcrcw
                || marker == ZmodemKind.zcrcg || marker == ZmodemKind.zcrcq {
                let width = dataCRC32 ? 4 : 2
                switch readEscaped(from: index + 2, count: width) {
                case .needMore:
                    return .needMore
                case .invalid:
                    return .invalid
                case let .bytes(crc, end):
                    var covered = data
                    covered.append(marker)
                    covered.append(contentsOf: crc)
                    if dataCRC32 {
                        guard ZmodemCRC.residue32(covered) == 0xDEBB_20E3 else { return .invalid }
                    } else {
                        let claimed = (UInt16(crc[0]) << 8) | UInt16(crc[1])
                        guard ZmodemCRC.crc16(Array(covered.prefix(data.count + 1))) == claimed else {
                            return .invalid
                        }
                    }
                    if marker == ZmodemKind.zcrce || marker == ZmodemKind.zcrcw {
                        expectingPacket = false
                    }
                    return .found(.packet(data: data, frameEnd: marker), end)
                }
            }
            data.append(marker ^ 0x40)
            index += 2
        }
        return .needMore
    }

    private func readEscaped(from start: Int, count: Int) -> Read {
        var index = start
        var decoded: [UInt8] = []
        while decoded.count < count {
            guard index < buffer.count else { return .needMore }
            if buffer[index] == ZmodemKind.zdle {
                guard index + 1 < buffer.count else { return .needMore }
                decoded.append(buffer[index + 1] ^ 0x40)
                index += 2
            } else {
                decoded.append(buffer[index])
                index += 1
            }
        }
        return .bytes(decoded, index)
    }

    private func header(from body: [UInt8]) -> ZmodemHeader {
        ZmodemHeader(type: body[0], b0: body[1], b1: body[2], b2: body[3], b3: body[4])
    }
}

private enum Scan {
    case needMore
    case invalid
    case found(ZmodemEvent, Int)
}

private enum Read {
    case needMore
    case invalid
    case bytes([UInt8], Int)
}

private func isHex(_ byte: UInt8) -> Bool {
    hexValue(byte) != nil
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39:
        return byte - 0x30
    case 0x61...0x66:
        return byte - 0x61 + 10
    case 0x41...0x46:
        return byte - 0x41 + 10
    default:
        return nil
    }
}

/// Byte escaping used by lrzsz when the receiver did not ask for escaped controls.
/// `0x7F` and `0xFF` go out unchanged. Escaping either one makes `rz` abort.
struct ZmodemEncoder {
    private var lastSent: UInt8 = 0

    mutating func encode(_ bytes: [UInt8]) -> [UInt8] {
        var encoded: [UInt8] = []
        encoded.reserveCapacity(bytes.count)
        for byte in bytes {
            switch escapeClass(byte) {
            case 1:
                encoded.append(ZmodemKind.zdle)
                let masked = byte ^ 0x40
                encoded.append(masked)
                lastSent = masked
            case 2 where lastSent & 0x7F == UInt8(ascii: "@"):
                encoded.append(ZmodemKind.zdle)
                let masked = byte ^ 0x40
                encoded.append(masked)
                lastSent = masked
            default:
                encoded.append(byte)
                lastSent = byte
            }
        }
        return encoded
    }

    /// 0 raw, 1 always escaped, 2 carriage return escaped only after `@`.
    private func escapeClass(_ byte: UInt8) -> Int {
        if byte & 0x60 != 0 {
            return 0
        }
        switch byte {
        case 0x18, 0x11, 0x13, 0x91, 0x93, 0x10, 0x90:
            return 1
        case 0x0D, 0x8D:
            return 2
        default:
            return 0
        }
    }
}

enum ZmodemFrames {
    static func hexHeader(type: UInt8, b0: UInt8, b1: UInt8, b2: UInt8, b3: UInt8) -> [UInt8] {
        let body: [UInt8] = [type, b0, b1, b2, b3]
        let crc = ZmodemCRC.crc16(body)
        var text = ""
        for byte in body {
            text += String(format: "%02x", byte)
        }
        text += String(format: "%04x", crc)
        var frame: [UInt8] = [ZmodemKind.zpad, ZmodemKind.zpad, ZmodemKind.zdle, ZmodemKind.zhex]
        frame.append(contentsOf: text.utf8)
        frame.append(contentsOf: [0x0D, 0x0A])
        return frame
    }

    static func binaryHeader(type: UInt8, b0: UInt8, b1: UInt8, b2: UInt8, b3: UInt8, crc32: Bool, encoder: inout ZmodemEncoder) -> [UInt8] {
        var body: [UInt8] = [type, b0, b1, b2, b3]
        var frame: [UInt8] = [ZmodemKind.zpad, ZmodemKind.zdle]
        if crc32 {
            frame.append(ZmodemKind.zbin32)
            let crc = ZmodemCRC.crc32(body)
            body.append(UInt8(truncatingIfNeeded: crc))
            body.append(UInt8(truncatingIfNeeded: crc >> 8))
            body.append(UInt8(truncatingIfNeeded: crc >> 16))
            body.append(UInt8(truncatingIfNeeded: crc >> 24))
        } else {
            frame.append(ZmodemKind.zbin)
            let crc = ZmodemCRC.crc16(body)
            body.append(UInt8(crc >> 8))
            body.append(UInt8(crc & 0xFF))
        }
        frame.append(contentsOf: encoder.encode(body))
        return frame
    }

    static func subpacket(_ data: [UInt8], frameEnd: UInt8, crc32: Bool, encoder: inout ZmodemEncoder) -> [UInt8] {
        var covered = data
        covered.append(frameEnd)
        var frame = encoder.encode(data)
        frame.append(ZmodemKind.zdle)
        frame.append(frameEnd)
        if crc32 {
            let crc = ZmodemCRC.crc32(covered)
            frame.append(contentsOf: encoder.encode([
                UInt8(truncatingIfNeeded: crc),
                UInt8(truncatingIfNeeded: crc >> 8),
                UInt8(truncatingIfNeeded: crc >> 16),
                UInt8(truncatingIfNeeded: crc >> 24)
            ]))
        } else {
            let crc = ZmodemCRC.crc16(covered)
            frame.append(contentsOf: encoder.encode([UInt8(crc >> 8), UInt8(crc & 0xFF)]))
        }
        if frameEnd == ZmodemKind.zcrcw {
            frame.append(0x11)
        }
        return frame
    }

    static func position(_ value: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let position = UInt32(value)
        return (
            UInt8(truncatingIfNeeded: position),
            UInt8(truncatingIfNeeded: position >> 8),
            UInt8(truncatingIfNeeded: position >> 16),
            UInt8(truncatingIfNeeded: position >> 24)
        )
    }
}

struct ZmodemFile {
    var name: String
    var bytes: [UInt8]
    var modified: Date
    var mode: UInt16
}

enum ZmodemPhase: Equatable {
    case launching
    case waiting
    case sending
}

struct ZmodemProgress: Equatable {
    var name: String
    var sent: Int
    var total: Int
    var fileIndex: Int
    var fileCount: Int
    var phase: ZmodemPhase
}

struct ZmodemStep {
    var outgoing: [UInt8] = []
    var status: String?
    var progress: ZmodemProgress?
    var finished: String?
    var failure: String?
}

/// Sends files to an `rz` that is already waiting on the byte stream.
final class ZmodemSender {
    private let files: [ZmodemFile]
    private var index = 0
    private var offset = 0
    private var useCRC32 = true
    private var stage: Stage = .waitInit
    private var lastOutgoing: [UInt8] = []
    private var scanner = ZmodemScanner()
    private var encoder = ZmodemEncoder()
    private var echoRemote = true

    /// Text from the shell, such as the `rz` banner, is still visible until the first protocol frame.
    var showsRemoteText: Bool { echoRemote }

    private enum Stage {
        case waitInit
        case waitPos
        case waitAck
        case waitInitAfterFile
        case waitFin
        case done
    }

    init(files: [ZmodemFile]) {
        self.files = files
    }

    func start() -> ZmodemStep {
        guard let file = files.first else {
            return ZmodemStep(failure: "没有要发送的文件")
        }
        return ZmodemStep(
            status: "等待 rz 接收 \(file.name)",
            progress: progress(for: file, sent: 0, phase: .waiting)
        )
    }

    func receive(_ bytes: [UInt8]) -> ZmodemStep {
        guard stage != .done else { return ZmodemStep() }
        var step = ZmodemStep()
        for event in scanner.feed(bytes) {
            switch event {
            case let .header(header):
                handle(header, step: &step)
            case .abort:
                step.failure = "远端中止了传输"
                stage = .done
            case .packet:
                break
            }
            if step.failure != nil || step.finished != nil {
                break
            }
        }
        if !step.outgoing.isEmpty {
            echoRemote = false
        }
        return step
    }

    private func progress(for file: ZmodemFile, sent: Int, phase: ZmodemPhase) -> ZmodemProgress {
        ZmodemProgress(
            name: file.name,
            sent: sent,
            total: file.bytes.count,
            fileIndex: index + 1,
            fileCount: files.count,
            phase: phase
        )
    }

    private func handle(_ header: ZmodemHeader, step: inout ZmodemStep) {
        switch header.type {
        case ZmodemKind.zrinit:
            useCRC32 = header.acceptsCRC32
            guard stage == .waitInit || stage == .waitInitAfterFile else { return }
            if index >= files.count {
                emit(ZmodemFrames.hexHeader(type: ZmodemKind.zfin, b0: 0, b1: 0, b2: 0, b3: 0), step: &step)
                stage = .waitFin
            } else {
                sendFileOffer(step: &step)
                stage = .waitPos
            }
        case ZmodemKind.zrpos:
            guard stage == .waitPos || stage == .waitAck, index < files.count else { return }
            offset = min(max(header.position, 0), files[index].bytes.count)
            sendChunk(newHeader: true, step: &step)
        case ZmodemKind.zack:
            guard stage == .waitAck, index < files.count else { return }
            let total = files[index].bytes.count
            offset = min(max(header.position, 0), total)
            sendChunk(newHeader: true, step: &step)
        case ZmodemKind.zskip:
            guard stage == .waitPos || stage == .waitAck else { return }
            index += 1
            offset = 0
            if index >= files.count {
                emit(ZmodemFrames.hexHeader(type: ZmodemKind.zfin, b0: 0, b1: 0, b2: 0, b3: 0), step: &step)
                stage = .waitFin
            } else {
                sendFileOffer(step: &step)
                stage = .waitPos
            }
        case ZmodemKind.zfin:
            guard stage == .waitFin else { return }
            emit([UInt8(ascii: "O"), UInt8(ascii: "O")], step: &step, remember: false)
            stage = .done
            let summary = files.count == 1 ? "已发送 \(files[0].name)" : "已发送 \(files.count) 个文件"
            step.finished = summary
        case ZmodemKind.znak:
            guard !lastOutgoing.isEmpty else { return }
            step.outgoing.append(contentsOf: lastOutgoing)
        case ZmodemKind.zabort:
            step.failure = "远端中止了传输"
            stage = .done
        default:
            break
        }
    }

    private func sendFileOffer(step: inout ZmodemStep) {
        let file = files[index]
        let modified = Int(file.modified.timeIntervalSince1970)
        let mode = String(file.mode == 0 ? 0o100644 : Int(file.mode), radix: 8)
        var info = Array(file.name.utf8)
        info.append(0)
        info.append(contentsOf: Array("\(file.bytes.count) \(String(modified, radix: 8)) \(mode)".utf8))
        info.append(0)
        var frame = ZmodemFrames.binaryHeader(
            type: ZmodemKind.zfile,
            b0: 0,
            b1: 0,
            b2: ZmodemKind.zmclob,
            b3: ZmodemKind.zcbin,
            crc32: useCRC32,
            encoder: &encoder
        )
        frame.append(contentsOf: ZmodemFrames.subpacket(info, frameEnd: ZmodemKind.zcrcw, crc32: useCRC32, encoder: &encoder))
        emit(frame, step: &step)
        step.status = "发送 \(file.name)"
        step.progress = progress(for: file, sent: 0, phase: .sending)
    }

    private func sendChunk(newHeader: Bool, step: inout ZmodemStep) {
        let file = files[index]
        let total = file.bytes.count
        if offset >= total {
            let placed = ZmodemFrames.position(offset)
            var frame = ZmodemFrames.binaryHeader(
                type: ZmodemKind.zdata,
                b0: placed.0,
                b1: placed.1,
                b2: placed.2,
                b3: placed.3,
                crc32: useCRC32,
                encoder: &encoder
            )
            frame.append(contentsOf: ZmodemFrames.subpacket([], frameEnd: ZmodemKind.zcrce, crc32: useCRC32, encoder: &encoder))
            frame.append(contentsOf: eofHeader(total))
            emit(frame, step: &step)
            step.status = "发送 \(file.name) \(total)/\(total)"
            step.progress = progress(for: file, sent: total, phase: .sending)
            index += 1
            offset = 0
            stage = .waitInitAfterFile
            return
        }
        let end = min(offset + 1024, total)
        let chunk = Array(file.bytes[offset..<end])
        var frame: [UInt8] = []
        if newHeader {
            let placed = ZmodemFrames.position(offset)
            frame.append(contentsOf: ZmodemFrames.binaryHeader(
                type: ZmodemKind.zdata,
                b0: placed.0,
                b1: placed.1,
                b2: placed.2,
                b3: placed.3,
                crc32: useCRC32,
                encoder: &encoder
            ))
        }
        let fileIndex = index + 1
        if end == total {
            frame.append(contentsOf: ZmodemFrames.subpacket(chunk, frameEnd: ZmodemKind.zcrce, crc32: useCRC32, encoder: &encoder))
            frame.append(contentsOf: eofHeader(end))
            emit(frame, step: &step)
            index += 1
            offset = 0
            stage = .waitInitAfterFile
        } else {
            frame.append(contentsOf: ZmodemFrames.subpacket(chunk, frameEnd: ZmodemKind.zcrcw, crc32: useCRC32, encoder: &encoder))
            emit(frame, step: &step)
            stage = .waitAck
        }
        step.status = "发送 \(file.name) \(end)/\(total)"
        step.progress = ZmodemProgress(
            name: file.name,
            sent: end,
            total: total,
            fileIndex: fileIndex,
            fileCount: files.count,
            phase: .sending
        )
    }

    private func eofHeader(_ length: Int) -> [UInt8] {
        let placed = ZmodemFrames.position(length)
        return ZmodemFrames.binaryHeader(
            type: ZmodemKind.zeof,
            b0: placed.0,
            b1: placed.1,
            b2: placed.2,
            b3: placed.3,
            crc32: useCRC32,
            encoder: &encoder
        )
    }

    private func emit(_ bytes: [UInt8], step: inout ZmodemStep, remember: Bool = true) {
        if remember {
            lastOutgoing = bytes
        }
        step.outgoing.append(contentsOf: bytes)
    }
}
