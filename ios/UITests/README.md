# Store screenshots

`ScreenshotTests` drives the app in the simulator against a demo server and saves the screenshots (iPhone 17 Pro Max, 1320 × 2868, the 6.9-inch size the App Store asks for).

```sh
xcrun simctl boot "iPhone 17 Pro Max"
xcrun simctl status_bar "iPhone 17 Pro Max" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3
TEST_RUNNER_SCREENSHOT_DIR=/tmp/shots TEST_RUNNER_DEMO_SERVER=https://demo.example.com \
TEST_RUNNER_DEMO_USER=reviewer TEST_RUNNER_DEMO_LANG=en TEST_RUNNER_DEMO_PASSWORD=... \
xcodebuild test -project NxtSound.xcodeproj -scheme NxtSound \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:NxtSoundUITests
```

The test taps by position, so it needs the demo server's home page (see `tools/demo` in the server repository) and may need small changes after a larger redesign.

## Offline mode

`testOfflineMode` takes the offline mode (the saved songs) and must run after `testScreenshots` with the same `DEMO_SERVER` switched off, for example when the demo server is reached through a local port forward that is stopped in between. Run it with `-only-testing:NxtSoundUITests/ScreenshotTests/testOfflineMode`; the app lists the saved songs on its own once the server cannot be reached. `DEMO_LANG=de` switches the app and the labels to German.

## iPad

The layout differs from the phone, so `testIPad` takes its steps from `IPAD_STEPS` (space-separated): `t:x,y` taps at a normalized
position, `p:n` waits, `s:name` takes a screenshot, `k:text` types, `d:x1,y1,x2,y2` drags. It signs in first, like the phone test.
Use an iPad Pro 13-inch simulator (2064×2752) for the 13-inch App Store slot.
