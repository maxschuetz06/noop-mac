# Contributing to NOOP

Thanks for your interest in contributing. NOOP for Mac is a standalone, fully **offline**
macOS app for WHOOP 4.0 and 5.0 / MG straps — it pairs over Bluetooth, stores
everything on-device in SQLite, and computes recovery / strain / HRV / sleep
locally. No servers, no accounts, no data leaving the device.

This file is a quick orientation. The **full contributing guide** —
repository layout, the design-system rules, the BLE safety contract, how to add a
metric / screen / command / migration, and the commit conventions — lives in
[`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md). Read that before opening a
non-trivial PR.

> NOOP is not affiliated with, endorsed by, or connected to WHOOP, Inc., and is
> not a medical device. See [`DISCLAIMER.md`](DISCLAIMER.md).

---

## Quick start

The codebase is reusable Swift packages (`Packages/`) plus the macOS app
(`Strand/`). The fastest feedback loop is the
packages — they build and test on their own, no Xcode project and no strap needed.

### Swift packages

```bash
# Test just the package you touched (substitute the name):
cd Packages/WhoopProtocol && swift build && swift test
```

The packages are `WhoopProtocol` (BLE framing / decode), `WhoopStore`
(SQLite persistence), `StrandAnalytics` (recovery / strain / HRV / sleep math),
`StrandImport` (WHOOP CSV + Apple Health importers), `StrandDesign` (the
SwiftUI design system) and `NoopLocalAccess` (read-only local database access).

### macOS app

The Xcode project is generated from `project.yml` and is **not** committed (only its
`Package.resolved` lockfile is tracked).

```bash
brew install xcodegen
xcodegen generate         # regenerate after any project.yml or file add/remove
open Strand.xcodeproj     # build and run from Xcode
```

Run the app tests unsigned with
`xcodebuild test -project Strand.xcodeproj -scheme Strand -destination platform=macOS CODE_SIGN_IDENTITY=-`.
Signing with your own team goes through `Config/Local.xcconfig`; see
[`docs/BUILD.md`](docs/BUILD.md).

---

## What CI checks

Two GitHub Actions workflows run on every PR and push to `main`. They build and
run tests only — no code signing, no secrets, no release.

| Workflow | What it does |
|---|---|
| **macOS app** (`.github/workflows/macos-app.yml`) | `xcodegen generate`, German UI literal lint, build and test the `Strand` scheme unsigned |
| **Swift packages** (`.github/workflows/swift-packages.yml`) | `swift build` + `swift test` for each package |

If CI fails on your PR, fix the cause rather than working around it. Never commit
generated output (`Strand.xcodeproj/`), `Config/Local.xcconfig`, personal health
data, or secrets.

---

## Submitting a PR

1. One concern per PR where practical (keep protocol, schema and UI changes
   separate).
2. Fill in the [PR template](.github/PULL_REQUEST_TEMPLATE.md).
3. For anything on the BLE path, state what you tested **on real hardware** and on
   which strap. A green build is not proof a command behaves correctly.
4. For analytics changes, add a test and cite the method.
5. For UI changes, use `StrandDesign` tokens only — no hardcoded colors, fonts,
   or spacing.

By opening a pull request you agree your contribution is licensed under the same
terms as the project — see [`LICENSE`](LICENSE).

---

## Reporting issues

- **Bugs and feature requests:** open an issue using the templates in
  [`.github/ISSUE_TEMPLATE`](.github/ISSUE_TEMPLATE). NOOP is on-device, so please
  leave out anything that identifies you.
- **Security issues:** see [`SECURITY.md`](SECURITY.md).

## Code of conduct

This project follows a [Code of Conduct](CODE_OF_CONDUCT.md). Be respectful and
keep discussion focused on the technical work.
