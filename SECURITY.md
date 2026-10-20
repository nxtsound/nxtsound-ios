# Security

Please **do not open a public issue** for a security problem. Use GitHub's private reporting (Security tab → "Report a vulnerability").

What the app does to limit the damage a malicious or compromised server could do: it only links to servers that identify as NxtSound,
the web view stays on that server (other links open in Safari), and what the page asks of the native side (play an address, show a
picture) is checked against the linked server's address. Songs kept for offline use are stored in a folder excluded from backups and are
deleted on logout. Only the latest release receives security fixes.
