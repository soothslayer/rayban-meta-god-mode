import XCTest

@MainActor
final class CJUITests: XCTestCase {
    func testWelcomeAndPairingValidation() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        XCTAssertTrue(app.buttons["connect-mac"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["talk-button"].isEnabled)
        app.buttons["talk-button"].tap()
        XCTAssertTrue(app.textFields["mac-address"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["pair-mac"].isEnabled)
        app.textFields["mac-address"].tap(); app.textFields["mac-address"].typeText("file:///tmp/test")
        app.secureTextFields["pairing-token"].tap(); app.secureTextFields["pairing-token"].typeText("invalid")
        app.buttons["pair-mac"].tap()
        XCTAssertTrue(app.alerts["CJ needs your attention"].waitForExistence(timeout: 3))
    }

    func testRealMacBrainPairingAndChat() async throws {
        let url = URL(string: "http://127.0.0.1:18765/health")!
        let response = try? await URLSession.shared.data(from: url)
        guard let response, let health = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any],
              health["name"] as? String == "CJ", (health["providers"] as? [String: Bool])?["mock"] == true else {
            throw XCTSkip("Run scripts/test-ios.sh to start the isolated brain fixture for this test.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        app.buttons["connect-mac"].tap()
        app.textFields["mac-address"].tap(); app.textFields["mac-address"].typeText("http://127.0.0.1:18765")
        app.secureTextFields["pairing-token"].tap(); app.secureTextFields["pairing-token"].typeText("ios-integration-only")
        app.buttons["pair-mac"].tap()
        XCTAssertTrue(app.staticTexts["pair-result"].waitForExistence(timeout: 15))
        app.swipeUp()
        let readReplies = app.switches["Read text replies aloud"]
        if readReplies.exists && readReplies.value as? String == "1" { readReplies.tap() }
        app.tabBars.buttons["Conversation"].tap()
        XCTAssertTrue(app.buttons["talk-button"].isEnabled)
        app.textFields["message-input"].tap(); app.textFields["message-input"].typeText("hello from iOS")
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.staticTexts["Mock reply: hello from iOS"].waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "CJ talking to the real Mac brain"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
