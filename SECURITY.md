# Security

Please report vulnerabilities privately, and never put their details in a public issue:

- If the repository's **Security** tab offers **Report a vulnerability**, use it.
- Otherwise, open a minimal issue that only asks for a private contact channel. Include no details of the vulnerability; they follow once a private channel is agreed.

Useful in a report: the TalkMargin version and build (from the app's Info.plist, `CFBundleShortVersionString`, `CFBundleVersion` and `MPGitCommit`), the macOS version, and the steps to reproduce.

In scope, for example:

- a TalkMargin window or its contents showing up in a screen share or capture beyond the limits in [docs/privacy.md](docs/privacy.md);
- keystrokes leaking from or into the event tap;
- the Claude chat running tools other than Read, Grep and Glob, or changing the linked session;
- `scripts/update.sh` or `scripts/build-app.sh` replacing or deleting something outside the documented targets.

The known capture limits (legacy `CGDisplayStream`, the menu-bar menu, the open dialog's menus) are documented and need no report.
