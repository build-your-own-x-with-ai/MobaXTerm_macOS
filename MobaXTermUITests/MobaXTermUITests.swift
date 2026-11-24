import XCTest

final class MobaXTermUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testSessionsSerialErrorAndLocalShell() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessions = directory.appendingPathComponent("sessions.json")

        let app = XCUIApplication()
        app.launchEnvironment["MOBAXTERM_SESSIONS_PATH"] = sessions.path
        app.launch()

        let welcome = app.staticTexts["打开会话、串口或本地终端"]
        XCTAssertTrue(welcome.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["当前串口"].waitForExistence(timeout: 5))

        app.buttons["新建会话"].firstMatch.click()
        let host = app.textFields["session.host"]
        XCTAssertTrue(host.waitForExistence(timeout: 5), app.debugDescription)
        let name = app.textFields["session.name"]
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("测试SSH")
        host.click()
        host.typeText("example.invalid")
        app.buttons["session.save"].click()
        let sshRow = app.staticTexts["测试SSH"]
        XCTAssertTrue(sshRow.waitForExistence(timeout: 5))

        app.buttons["新建会话"].firstMatch.click()
        let kind = app.popUpButtons["session.kind"]
        XCTAssertTrue(kind.waitForExistence(timeout: 5), app.debugDescription)
        kind.click()
        app.menuItems["串口"].click()
        let serialName = app.textFields["session.name"]
        serialName.click()
        serialName.typeKey("a", modifierFlags: .command)
        serialName.typeText("坏串口")
        let path = app.textFields["session.path"]
        XCTAssertTrue(path.waitForExistence(timeout: 5), app.debugDescription)
        path.click()
        path.typeText("/dev/cu.does-not-exist")
        app.buttons["session.save"].click()
        let serialRow = app.staticTexts["坏串口"]
        XCTAssertTrue(serialRow.waitForExistence(timeout: 5))
        serialRow.doubleClick()

        let openError = app.staticTexts["session.ended"]
        XCTAssertTrue(openError.waitForExistence(timeout: 5), app.debugDescription)
        let endedText = "\(openError.label) \(openError.value ?? "")"
        XCTAssertTrue(endedText.contains("无法打开"), endedText)

        app.buttons["open.local"].click()
        let selectedTab = app.staticTexts["tab.selected"]
        let becameLocal = NSPredicate(format: "label == %@ OR value == %@", "本地终端", "本地终端")
        let tabReady = XCTNSPredicateExpectation(predicate: becameLocal, object: selectedTab)
        XCTAssertEqual(
            XCTWaiter().wait(for: [tabReady], timeout: 5),
            .completed,
            selectedTab.debugDescription
        )
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        let status = app.staticTexts["session.status"]
        let showsShell = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", shellName, shellName)
        let statusReady = XCTNSPredicateExpectation(predicate: showsShell, object: status)
        XCTAssertEqual(
            XCTWaiter().wait(for: [statusReady], timeout: 5),
            .completed,
            status.debugDescription
        )

        let proof = directory.appendingPathComponent("proof.txt")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.45)).click()
        app.typeText("printf MOBATEST > \(proof.path)\n")
        let wroteProof = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: proof, encoding: .utf8))?.contains("MOBATEST") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [wroteProof], timeout: 8), .completed, proof.path)
    }
}
