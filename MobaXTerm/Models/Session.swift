import Foundation

enum SessionKind: String, Codable, CaseIterable, Identifiable {
    case ssh
    case serial
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ssh: return "SSH"
        case .serial: return "串口"
        case .local: return "本地"
        }
    }

    var symbolName: String {
        switch self {
        case .ssh: return "network"
        case .serial: return "cable.connector"
        case .local: return "terminal"
        }
    }
}

struct SSHSettings: Codable, Equatable {
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    var identityFile: String = ""
    var extraArguments: String = ""
    var remoteCommand: String = ""
}

struct LocalSettings: Codable, Equatable {
    var executable: String = ""
    var arguments: String = "-l"

    var resolvedExecutable: String {
        let trimmed = executable.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }

    var resolvedArguments: [String] {
        SSHCommand.splitArguments(arguments)
    }
}

struct Session: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var kind: SessionKind
    var ssh: SSHSettings?
    var serial: SerialSettings?
    var local: LocalSettings?

    static func makeSSH() -> Session {
        Session(id: UUID(), name: "SSH 会话", kind: .ssh, ssh: SSHSettings(), serial: nil, local: nil)
    }

    static func makeSerial(path: String = "", name: String = "串口") -> Session {
        var settings = SerialSettings()
        settings.devicePath = path
        return Session(id: UUID(), name: name, kind: .serial, ssh: nil, serial: settings, local: nil)
    }

    static func makeLocal() -> Session {
        Session(id: UUID(), name: "本地终端", kind: .local, ssh: nil, serial: nil, local: LocalSettings())
    }

    var statusText: String {
        switch kind {
        case .ssh:
            let settings = ssh ?? SSHSettings()
            let user = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = user.isEmpty ? host : "\(user)@\(host)"
            return "\(target):\(settings.port)"
        case .serial:
            let settings = serial ?? SerialSettings()
            return "\(settings.devicePath) · \(settings.lineSummary)"
        case .local:
            return (local ?? LocalSettings()).resolvedExecutable
        }
    }
}
