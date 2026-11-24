import XCTest
@testable import MobaXTerm

final class SSHCommandTests: XCTestCase {
    func testDefaultPortOmitsFlagAndUsesUser() {
        let settings = SSHSettings(host: "example.com", port: 22, username: "alice")
        XCTAssertEqual(
            SSHCommand.arguments(for: settings),
            ["-tt", "alice@example.com"]
        )
    }

    func testNonStandardPort() {
        let settings = SSHSettings(host: "example.com", port: 2222, username: "alice")
        XCTAssertEqual(
            SSHCommand.arguments(for: settings),
            ["-tt", "-p", "2222", "alice@example.com"]
        )
    }

    func testIdentityExtraArgumentsAndRemoteCommand() {
        let settings = SSHSettings(
            host: "example.com",
            port: 22,
            username: "",
            identityFile: " /keys/id_ed25519 ",
            extraArguments: " -J  jump@bastion ",
            remoteCommand: "uptime -p"
        )
        XCTAssertEqual(
            SSHCommand.arguments(for: settings),
            ["-tt", "-i", "/keys/id_ed25519", "-J", "jump@bastion", "example.com", "uptime -p"]
        )
    }

    func testDoesNotPassConfigOverride() {
        let arguments = SSHCommand.arguments(for: SSHSettings(host: "host"))
        XCTAssertFalse(arguments.contains("-F"))
    }
}
