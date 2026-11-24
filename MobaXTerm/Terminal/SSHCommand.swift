import Foundation

enum SSHCommand {
    /// Builds argv for `/usr/bin/ssh`. `-F` is intentionally omitted so OpenSSH
    /// keeps reading the user's config, keys, and agent.
    static func arguments(for settings: SSHSettings) -> [String] {
        var args = ["-tt"]
        if settings.port != 22 {
            args.append("-p")
            args.append(String(settings.port))
        }
        let identity = settings.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identity.isEmpty {
            args.append("-i")
            args.append(identity)
        }
        args.append(contentsOf: splitArguments(settings.extraArguments))

        let user = settings.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = settings.host.trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty {
            args.append(host)
        } else {
            args.append("\(user)@\(host)")
        }

        let remote = settings.remoteCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remote.isEmpty {
            args.append(remote)
        }
        return args
    }

    static func splitArguments(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func childEnvironment() -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    static func homeDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }
}
