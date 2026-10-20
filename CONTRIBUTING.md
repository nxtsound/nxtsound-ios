# Contributing

1. Open an issue first for bigger changes.
2. You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `cd ios && xcodegen generate`, then open `NxtSound.xcodeproj`.
   Put your team ID into `ios/Local.xcconfig` (copy `Local.xcconfig.example`; it is not committed).
3. Keep the rules in [CLAUDE.md](CLAUDE.md): English code, comments and commit messages; app texts in `en.lproj` and `de.lproj`;
   **no service-specific code** (the app only knows the NxtSound server).
4. Open a pull request; CI builds the app for the simulator.
