# NxtSound for iOS

🇩🇪 [Deutsch](README.de.md)

Native iOS app for the [NxtSound server](../nxtsound-server): it asks for the address of your server once, checks that it really is a
NxtSound server, and then shows the server's web UI with a native player (background audio, lock screen, remote control).

- **Linking:** the address field checks the connection while you type (green = connected, red = reason). The app only links to servers
  that identify as NxtSound; the web view stays on that server, other links open in Safari.
- **Languages:** English and German (follows the device language).
- **Requirements:** Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), iOS 18+.

```sh
cd ios
xcodegen generate
open NxtSound.xcodeproj          # run on a simulator or a device
```

Background audio and lock-screen control can only be tested on a real iPhone. For local servers without HTTPS, use the server's LAN
address (e.g. `192.168.1.5:8000`); the app then uses plain HTTP, which iOS allows on local networks.

Project notes: `CLAUDE.md`, roadmap: `PLAN.md`.

## License

[MIT](LICENSE)
