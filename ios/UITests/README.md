# Store screenshots

`ScreenshotTests` drives the app in the simulator against a demo server and saves the screenshots (iPhone 17 Pro Max, 1320 × 2868, the 6.9-inch size the App Store asks for).

```sh
xcrun simctl boot "iPhone 17 Pro Max"
xcrun simctl status_bar "iPhone 17 Pro Max" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3
TEST_RUNNER_SCREENSHOT_DIR=/tmp/shots TEST_RUNNER_DEMO_SERVER=https://demo.example.com \
TEST_RUNNER_DEMO_USER=reviewer TEST_RUNNER_DEMO_PASSWORD=... \
xcodebuild test -project NxtSound.xcodeproj -scheme NxtSound \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -only-testing:NxtSoundUITests
```

The test taps by position, so it needs the demo server's home page (see `tools/demo` in the server repository) and may need small changes after a larger redesign.
