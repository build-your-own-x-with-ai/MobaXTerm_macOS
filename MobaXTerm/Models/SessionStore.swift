import Foundation

struct SessionStore {
    let fileURL: URL

    static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["MOBAXTERM_SESSIONS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("MobaXTerm/sessions.json")
    }

    func load() throws -> [Session] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Session].self, from: data)
    }

    func save(_ sessions: [Session]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sessions)
        try data.write(to: fileURL, options: .atomic)
    }
}
