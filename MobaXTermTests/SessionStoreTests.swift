import XCTest
@testable import MobaXTerm

final class SessionStoreTests: XCTestCase {
    func testMissingFileReturnsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sessions.json")
        let store = SessionStore(fileURL: url)
        let loaded = try store.load()
        XCTAssertEqual(loaded, [])
    }

    func testRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = SessionStore(fileURL: directory.appendingPathComponent("sessions.json"))
        var serial = SerialSettings()
        serial.devicePath = "/dev/cu.usbserial-1"
        serial.baudRate = 57600
        serial.parity = .even
        serial.newline = .crlf
        serial.localEcho = true
        let sessions = [
            Session(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "跳板",
                kind: .ssh,
                ssh: SSHSettings(
                    host: "lab.example",
                    port: 2222,
                    username: "me",
                    identityFile: "/tmp/id",
                    extraArguments: "-J bastion",
                    remoteCommand: ""
                ),
                serial: nil,
                local: nil
            ),
            Session(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "板子",
                kind: .serial,
                ssh: nil,
                serial: serial,
                local: nil
            ),
            Session(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                name: "zsh",
                kind: .local,
                ssh: nil,
                serial: nil,
                local: LocalSettings(executable: "/bin/zsh", arguments: "-l")
            )
        ]
        try store.save(sessions)
        let loaded = try store.load()
        XCTAssertEqual(loaded, sessions)
    }
}
