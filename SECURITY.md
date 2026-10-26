# Security Policy

## Scope

NOOP is a fully offline, on-device app. It has no servers, no accounts, and no
cloud sync, so the usual web attack surface does not apply. What remains is local:

- **Bluetooth Low Energy** — the link to your WHOOP strap.
- **Local SQLite database** — every reading is stored on your own device.
- **File imports** — WHOOP CSV exports and Apple Health ZIP files you choose to open.
- **Check for updates (only when you tap it)** — the only feature that makes a network
  request: one read of the latest GitHub release version, with nothing about you attached.

A useful security report is one that lets data leave the device when it shouldn't,
lets a malicious strap or crafted import file corrupt the database or run code, or
otherwise breaks the offline, local-only guarantee the app makes.

## Reporting a vulnerability

Please report vulnerabilities **privately** through GitHub's private vulnerability
reporting: open the repository's **Security** tab and choose **Report a
vulnerability**. Do not open a public issue for an unfixed vulnerability.

Please include, as far as you can without putting anyone at risk:

- A description of the issue and the guarantee it breaks
- Steps to reproduce
- The potential impact
- A suggested fix, if you have one

Response times depend on maintainer availability; there is no guaranteed SLA.

## Supported versions

Only the `main` branch receives fixes. NOOP ships from source; rebuild from the
latest `main` to pick up security fixes.

## Out of scope

- Vulnerabilities that require physical access to an already-unlocked device
- Issues in third-party dependencies — please report those upstream (see
  [`NOTICE`](NOTICE) for the bundled libraries and their licences)
- The WHOOP strap firmware itself, which NOOP does not ship or modify
