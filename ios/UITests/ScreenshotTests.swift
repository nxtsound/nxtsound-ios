import XCTest

/// Takes the App Store screenshots from a running demo server (see ios/UITests/README.md).
/// Environment: SCREENSHOT_DIR (where the PNGs go), DEMO_SERVER (address), DEMO_USER, DEMO_PASSWORD,
/// DEMO_LANG (en or de, default en).
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
        let de = env["DEMO_LANG"] == "de"
        app.launchArguments = ["-serverURL", server, "-AppleLanguages", de ? "(de)" : "(en)", "-AppleLocale", de ? "de_DE" : "en_US"]
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
        let skip = app.webViews.buttons[de ? "Überspringen" : "Skip"].firstMatch
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
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.4)).tap()  // first playlist
        pause(3)
        try shot("04-playlist")

        // App settings with the offline section (from the profile menu)
        let settings = app.descendants(matching: .any)[de ? "App-Einstellungen" : "App settings"].firstMatch
        for _ in 0..<3 where !settings.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.096)).tap()
            pause(3)
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        settings.tap()
        pause(3)
        let toggle = app.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()  // keep songs for offline listening
        pause(25)     // the first download round, so that the offline mode has songs to show
        app.swipeUp(velocity: .slow)
        pause(1)
        try shot("06-offline-settings")
        app.buttons[de ? "Fertig" : "Done"].firstMatch.tap()
        pause(2)

        // Search
        pause(2)
        for _ in 0..<3 where !app.keyboards.firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.095)).tap()
            pause(2)
        }
        app.typeText("neon\n")
        pause(4)
        try shot("05-search")
    }

    /// iPad: the layout differs from the phone, so the steps come from IPAD_STEPS, separated by spaces:
    /// `t:x,y` taps at a normalized position, `p:n` waits n seconds, `s:name` takes a screenshot, `k:text` types text,
    /// `d:x1,y1,x2,y2` drags between two positions. Signs in first, like `testScreenshots`.
    func testIPad() throws {
        let server = try XCTUnwrap(env["DEMO_SERVER"], "DEMO_SERVER is not set")
        let user = try XCTUnwrap(env["DEMO_USER"]), password = try XCTUnwrap(env["DEMO_PASSWORD"])
        let de = env["DEMO_LANG"] == "de"
        app.launchArguments = ["-serverURL", server, "-AppleLanguages", de ? "(de)" : "(en)", "-AppleLocale", de ? "de_DE" : "en_US"]
        app.launch()
        pause(6)
        let name = app.webViews.textFields.firstMatch
        if name.waitForExistence(timeout: 12) {
            name.tap(); name.typeText(user)
            let pw = app.webViews.secureTextFields.firstMatch
            pw.tap(); pw.typeText(password + "\n")
        }
        pause(5)
        let skip = app.webViews.buttons[de ? "Überspringen" : "Skip"].firstMatch
        if skip.waitForExistence(timeout: 8) { skip.tap(); pause(2) }
        pause(3)
        func point(_ s: Substring) -> CGVector {
            let v = s.split(separator: ",").map { Double($0) ?? 0 }
            return CGVector(dx: v[0], dy: v[1])
        }
        for step in (env["IPAD_STEPS"] ?? "s:01-home").split(separator: " ") {
            let arg = step.dropFirst(2)
            switch step.prefix(1) {
            case "t": app.coordinate(withNormalizedOffset: point(arg)).tap()
            case "p": pause(Double(arg) ?? 1)
            case "s": try shot(String(arg))
            case "k": app.typeText(String(arg))
            case "d":
                let v = arg.split(separator: ",").map { Double($0) ?? 0 }
                app.coordinate(withNormalizedOffset: CGVector(dx: v[0], dy: v[1]))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: v[2], dy: v[3])))
            default: break
            }
        }
    }

    /// Run after `testScreenshots` with the same DEMO_SERVER switched off: the saved songs are listed in the offline mode.
    func testOfflineMode() throws {
        let server = try XCTUnwrap(env["DEMO_SERVER"], "DEMO_SERVER is not set")
        let de = env["DEMO_LANG"] == "de"
        app.launchArguments = ["-serverURL", server, "-AppleLanguages", de ? "(de)" : "(en)", "-AppleLocale", de ? "de_DE" : "en_US"]
        app.launch()
        pause(20)  // the page cannot load; the app lists the saved songs by itself or offers them in a button
        let offlineButton = app.buttons[de ? "Offline-Titel" : "Offline songs"].firstMatch
        if offlineButton.exists { offlineButton.tap() }
        pause(3)
        try shot("07-offline-mode")
    }
}
