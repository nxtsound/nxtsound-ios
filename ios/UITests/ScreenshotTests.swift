import XCTest

/// Takes the App Store screenshots from a running demo server (see ios/UITests/README.md).
/// Environment: SCREENSHOT_DIR (where the PNGs go), DEMO_SERVER (address), DEMO_USER, DEMO_PASSWORD.
final class ScreenshotTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    private func shot(_ name: String) throws {
        let dir = try XCTUnwrap(env["SCREENSHOT_DIR"], "SCREENSHOT_DIR is not set")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
    }

    private func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

    func testScreenshots() throws {
        let server = try XCTUnwrap(env["DEMO_SERVER"], "DEMO_SERVER is not set")
        let user = try XCTUnwrap(env["DEMO_USER"]), password = try XCTUnwrap(env["DEMO_PASSWORD"])
        app.launchArguments = ["-serverURL", server, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        pause(6)  // splash and first load

        // Sign in (the page shows its own form), unless an earlier run left the session on the simulator
        let name = app.webViews.textFields.firstMatch
        if name.waitForExistence(timeout: 12) {
            name.tap(); name.typeText(user)
            let pw = app.webViews.secureTextFields.firstMatch
            pw.tap(); pw.typeText(password + "\n")
        }
        pause(5)
        let skip = app.webViews.buttons["Skip"].firstMatch
        if skip.waitForExistence(timeout: 8) { skip.tap(); pause(2) }  // the first sign-in shows a short tour
        pause(3)
        try shot("01-home")

        // Play the first song of "Recently played" and open the big player
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.265)).tap()
        pause(4)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.935)).tap()
        pause(3)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.42, dy: 0.733)).tap()  // a position in the middle of the song
        pause(2)
        try shot("02-player")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.073, dy: 0.094)).tap()  // close the player
        pause(2)

        // Playlists, then one playlist
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.255, dy: 0.142)).tap()
        pause(3)
        try shot("03-playlists")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).tap()  // "Road trip"
        pause(3)
        try shot("04-playlist")

        // App settings with the offline section (from the profile menu)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.096)).tap()
        pause(2)
        let settings = app.descendants(matching: .any)["App settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        settings.tap()
        pause(3)
        let toggle = app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()  // keep songs for offline listening
        pause(12)     // the first download round
        app.swipeUp(velocity: .slow)
        pause(1)
        try shot("06-offline-settings")
        app.buttons["Done"].firstMatch.tap()
        pause(2)

        // Search
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.095)).tap()
        pause(2)
        app.typeText("neon\n")
        pause(4)
        try shot("05-search")
    }
}
