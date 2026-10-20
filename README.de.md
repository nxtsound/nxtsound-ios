# NxtSound für iOS

🇬🇧 [English](README.md)

Native iOS-App für den [NxtSound-Server](https://github.com/nxtsound/nxtsound-server): Sie fragt einmal nach der Adresse deines Servers, prüft, dass es wirklich ein
NxtSound-Server ist, und zeigt dann die Web-Oberfläche des Servers mit einem nativen Player (Hintergrund-Audio, Sperrbildschirm, Fernbedienung).

- **Verknüpfen:** Das Adressfeld prüft die Verbindung beim Tippen (grün = verbunden, rot = Grund). Die App verbindet sich nur mit Servern, die sich als
  NxtSound ausweisen; die WebView bleibt auf diesem Server, andere Links öffnen in Safari.
- **Sprachen:** Englisch und Deutsch (folgt der Gerätesprache).
- **Voraussetzungen:** Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), iOS 18+.

```sh
cd ios
xcodegen generate
open NxtSound.xcodeproj          # im Simulator oder auf einem Gerät starten
```

Hintergrund-Audio und Sperrbildschirm lassen sich nur auf einem echten iPhone testen. Für lokale Server ohne HTTPS die LAN-Adresse des Servers
verwenden (z. B. `192.168.1.5:8000`); die App nutzt dann HTTP, was iOS in lokalen Netzen erlaubt.

Projektnotizen: [CLAUDE.md](CLAUDE.md). Zum Selbstbauen brauchst du ein Apple-Entwicklerteam: `ios/Local.xcconfig.example` nach `ios/Local.xcconfig` kopieren und die Team-ID eintragen. Mitarbeit: [CONTRIBUTING.md](CONTRIBUTING.md).

## Lizenz

[MIT](LICENSE)
