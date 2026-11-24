import Darwin
import XCTest
@testable import MobaXTerm

final class SerialConfigTests: XCTestCase {
    func testEightNoneOne() {
        let term = configured(.init(dataBits: 8, parity: .none, stopBits: 1, flowControl: .none))
        XCTAssertEqual(term.c_cflag & tcflag_t(CSIZE), tcflag_t(CS8))
        XCTAssertEqual(term.c_cflag & tcflag_t(PARENB), 0)
        XCTAssertEqual(term.c_cflag & tcflag_t(CSTOPB), 0)
        XCTAssertEqual(term.c_cflag & tcflag_t(CRTSCTS), 0)
        XCTAssertEqual(term.c_iflag & tcflag_t(IXON | IXOFF), 0)
        XCTAssertEqual(term.c_cflag & tcflag_t(CREAD | CLOCAL), tcflag_t(CREAD | CLOCAL))
    }

    func testSevenEvenOne() {
        let term = configured(.init(dataBits: 7, parity: .even, stopBits: 1, flowControl: .none))
        XCTAssertEqual(term.c_cflag & tcflag_t(CSIZE), tcflag_t(CS7))
        XCTAssertEqual(term.c_cflag & tcflag_t(PARENB), tcflag_t(PARENB))
        XCTAssertEqual(term.c_cflag & tcflag_t(PARODD), 0)
        XCTAssertEqual(term.c_cflag & tcflag_t(CSTOPB), 0)
    }

    func testTwoStopBits() {
        let term = configured(.init(dataBits: 8, parity: .none, stopBits: 2, flowControl: .none))
        XCTAssertEqual(term.c_cflag & tcflag_t(CSTOPB), tcflag_t(CSTOPB))
    }

    func testHardwareFlowControl() {
        let term = configured(.init(flowControl: .rtscts))
        XCTAssertEqual(term.c_cflag & tcflag_t(CRTSCTS), tcflag_t(CRTSCTS))
        XCTAssertEqual(term.c_iflag & tcflag_t(IXON | IXOFF), 0)
    }

    func testSoftwareFlowControl() {
        let term = configured(.init(flowControl: .xonxoff))
        XCTAssertEqual(term.c_iflag & tcflag_t(IXON | IXOFF), tcflag_t(IXON | IXOFF))
        XCTAssertEqual(term.c_cflag & tcflag_t(CRTSCTS), 0)
    }

    func testOddParitySetsBothBits() {
        let term = configured(.init(parity: .odd))
        XCTAssertEqual(term.c_cflag & tcflag_t(PARENB | PARODD), tcflag_t(PARENB | PARODD))
    }

    func testKnownAndCustomBaud() {
        XCTAssertEqual(posixSpeed(for: 115200), speed_t(B115200))
        XCTAssertNil(posixSpeed(for: 921600))
    }

    func testNewlineTranslation() {
        XCTAssertEqual(translateOutgoing([0x61, 0x0D], newline: .raw), [0x61, 0x0D])
        XCTAssertEqual(translateOutgoing([0x0A], newline: .cr), [0x0D])
        XCTAssertEqual(translateOutgoing([0x0D], newline: .cr), [0x0D])
        XCTAssertEqual(translateOutgoing([0x0D], newline: .lf), [0x0A])
        XCTAssertEqual(translateOutgoing([0x0D], newline: .crlf), [0x0D, 0x0A])
        XCTAssertEqual(translateOutgoing([0x0A, 0x62], newline: .crlf), [0x0D, 0x0A, 0x62])
    }

    func testLineSummary() {
        let settings = SerialSettings(baudRate: 115200, dataBits: 8, parity: .none, stopBits: 1)
        XCTAssertEqual(settings.lineSummary, "115200 8N1")
    }

    private func configured(
        _ settings: SerialSettings = SerialSettings()
    ) -> termios {
        var term = termios()
        applySerialLineSettings(settings, to: &term)
        return term
    }
}
