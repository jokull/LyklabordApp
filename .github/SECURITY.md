# Security Policy

Lyklaborð's core privacy claim — the keyboard extension contains zero
networking code, and personal data never leaves the device except encrypted
into the user's own iCloud — is verifiable in this repository. If you find a
way to break that claim, or any other vulnerability, we want to hear about it
privately first.

## Reporting a vulnerability

Please use **GitHub's private vulnerability reporting**:

1. Go to the repository's **Security** tab.
2. Choose **Report a vulnerability** (or open
   <https://github.com/jokull/LyklabordApp/security/advisories/new> directly).
3. Describe the issue, affected component (app, keyboard extension, sync,
   site), and reproduction steps.

Reports are acknowledged as quickly as possible and fixed with priority.
Please do not open public issues for security problems, and do not include
anyone's personal typing data in a report.

## Scope notes

- The keyboard extension (`KeyboardExt/` + `Packages/`) is designed to have
  no network capability at all — any bypass of that is in scope and serious.
- iCloud sync uses CloudKit with client-side AES-256-GCM encryption, keyed
  from the user's iCloud Keychain — weaknesses in that construction are in
  scope.
- The static marketing site (`site/`) is in scope for content injection or
  deployment issues, though it stores no user data.
