import Darwin
import Foundation

enum Parity: String, Codable, CaseIterable, Identifiable {
    case none
    case even
    case odd

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "无"
        case .even: return "偶"
        case .odd: return "奇"
        }
    }

    var mark: String {
        switch self {
        case .none: return "N"
        case .even: return "E"
        case .odd: return "O"
        }
    }
}

enum FlowControl: String, Codable, CaseIterable, Identifiable {
    case none
    case rtscts
    case xonxoff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "无"
        case .rtscts: return "RTS/CTS"
        case .xonxoff: return "XON/XOFF"
        }
    }
}

enum NewlineMode: String, Codable, CaseIterable, Identifiable {
    case raw
    case cr
    case lf
    case crlf

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw: return "不转换"
        case .cr: return "CR"
        case .lf: return "LF"
        case .crlf: return "CRLF"
        }
    }
}

struct SerialSettings: Codable, Equatable {
    var devicePath: String = ""
    var baudRate: Int = 115200
    var dataBits: Int = 8
    var parity: Parity = .none
    var stopBits: Int = 1
    var flowControl: FlowControl = .none
    var localEcho: Bool = false
    var newline: NewlineMode = .raw

    static let baudPresets = [9600, 19200, 38400, 57600, 115200, 230400, 460800, 921600]

    var lineSummary: String {
        "\(baudRate) \(dataBits)\(parity.mark)\(stopBits)"
    }
}

func posixSpeed(for baud: Int) -> speed_t? {
    switch baud {
    case 0: return speed_t(B0)
    case 50: return speed_t(B50)
    case 75: return speed_t(B75)
    case 110: return speed_t(B110)
    case 134: return speed_t(B134)
    case 150: return speed_t(B150)
    case 200: return speed_t(B200)
    case 300: return speed_t(B300)
    case 600: return speed_t(B600)
    case 1200: return speed_t(B1200)
    case 1800: return speed_t(B1800)
    case 2400: return speed_t(B2400)
    case 4800: return speed_t(B4800)
    case 9600: return speed_t(B9600)
    case 19200: return speed_t(B19200)
    case 38400: return speed_t(B38400)
    case 57600: return speed_t(B57600)
    case 115200: return speed_t(B115200)
    case 230400: return speed_t(B230400)
    default: return nil
    }
}

func applySerialLineSettings(_ settings: SerialSettings, to term: inout termios) {
    cfmakeraw(&term)
    term.c_cflag |= tcflag_t(CLOCAL | CREAD)
    term.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
    term.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)

    switch settings.dataBits {
    case 5: term.c_cflag |= tcflag_t(CS5)
    case 6: term.c_cflag |= tcflag_t(CS6)
    case 7: term.c_cflag |= tcflag_t(CS7)
    default: term.c_cflag |= tcflag_t(CS8)
    }

    switch settings.parity {
    case .none:
        break
    case .even:
        term.c_cflag |= tcflag_t(PARENB)
    case .odd:
        term.c_cflag |= tcflag_t(PARENB | PARODD)
    }

    if settings.stopBits >= 2 {
        term.c_cflag |= tcflag_t(CSTOPB)
    }

    switch settings.flowControl {
    case .none:
        break
    case .rtscts:
        term.c_cflag |= tcflag_t(CRTSCTS)
    case .xonxoff:
        term.c_iflag |= tcflag_t(IXON | IXOFF)
    }
}

func translateOutgoing(_ input: [UInt8], newline: NewlineMode) -> [UInt8] {
    switch newline {
    case .raw:
        return input
    case .cr:
        return input.flatMap { byte in
            byte == 0x0A || byte == 0x0D ? [UInt8(0x0D)] : [byte]
        }
    case .lf:
        return input.flatMap { byte in
            byte == 0x0A || byte == 0x0D ? [UInt8(0x0A)] : [byte]
        }
    case .crlf:
        return input.flatMap { byte in
            byte == 0x0A || byte == 0x0D ? [UInt8(0x0D), UInt8(0x0A)] : [byte]
        }
    }
}
