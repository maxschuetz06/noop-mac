# NOOP for Mac

A macOS app for WHOOP straps (4.0, 5.0 and MG) that reads the strap directly over Bluetooth and keeps
everything on your Mac. No account, no cloud, no subscription.

> **Unofficial fork.** This repository is a modified, macOS-only fork of
> [NOOP](https://github.com/NoopApp/noop) by NoopApp. It is not maintained, endorsed or supported by
> NoopApp, and it is **not affiliated with WHOOP, Inc.** Please report problems with this fork here,
> not upstream.

## What it does

- Pairs with your WHOOP strap over Bluetooth Low Energy and records live heart rate, R-R intervals,
  skin temperature, motion and the strap's stored history.
- Imports WHOOP CSV exports and Apple Health exports, so you can start from your existing history.
- Computes recovery, strain, HRV, sleep stages and trends on-device from published methods.
- Stores everything in a local SQLite database inside the app's sandbox container.
- Shows a desktop widget and a menu-bar heart-rate readout.

## Local-only by design

NOOP has no server, no telemetry and no account. Your strap data, imports and computed metrics never
leave your Mac. Only two features make network requests: the optional, off-by-default AI Coach (to a
provider you configure with your own API key) and "Check for updates" (one read of the latest GitHub
release, only when you tap it).

An optional external data folder (database mirror for local scripts, import inbox, raw PPG capture)
is off by default and must be enabled at build time. See
[`docs/EXTERNAL_DATA_FOLDER.md`](docs/EXTERNAL_DATA_FOLDER.md).

## Build from source

There are no prebuilt downloads. You need macOS 13 or newer, a current Xcode and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone <this-repository-url> noop-mac
cd noop-mac
xcodegen generate

# unsigned build and tests, no Apple account needed
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- build
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- test
```

The app is `build/Build/Products/Debug/NOOP.app`. For a build signed with your own team (needed for
the desktop widget), copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`, set your team
and bundle id, and run `Tools/install-local.sh`. Full instructions: [`docs/BUILD.md`](docs/BUILD.md).

## Repository layout

| Path | Contents |
|---|---|
| `Strand/` | macOS SwiftUI app (scheme `Strand`, product `NOOP.app`) |
| `MacWidgets/`, `Shared/` | desktop widget extension and code shared with the app |
| `Packages/WhoopProtocol` | BLE framing, CRC, command/event/packet decode |
| `Packages/WhoopStore` | GRDB/SQLite persistence |
| `Packages/StrandAnalytics` | recovery / strain / HRV / sleep math |
| `Packages/StrandImport` | WHOOP CSV, Apple Health and other importers |
| `Packages/StrandDesign` | SwiftUI design system |
| `Packages/NoopLocalAccess` | read-only local database access for scripts |
| `Config/` | build identity (xcconfig) and the opt-in entitlements variant |

## Documentation

- [`docs/BUILD.md`](docs/BUILD.md): building, signing, tests
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md): module map
- [`docs/PROTOCOL.md`](docs/PROTOCOL.md) and [`docs/BLE_REVERSE_ENGINEERING.md`](docs/BLE_REVERSE_ENGINEERING.md): strap protocol notes
- [`docs/ANALYTICS.md`](docs/ANALYTICS.md): how the scores are computed
- [`docs/PRIVACY_SECURITY.md`](docs/PRIVACY_SECURITY.md): privacy and threat model
- [`CONTRIBUTING.md`](CONTRIBUTING.md), [`SUPPORT.md`](SUPPORT.md), [`SECURITY.md`](SECURITY.md)

## Not a medical device

Heart rate, HRV, recovery, strain, sleep stages, SpO₂, respiratory rate and skin temperature are
approximations. They are not clinically validated and are not medical advice. Provided as-is, without
warranty. See [`DISCLAIMER.md`](DISCLAIMER.md).

## License and attribution

Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE): free for personal and other
non-commercial use; commercial use is not granted. The upstream Required Notice
(`Copyright 2026 NoopApp`) and the modification notice for this fork are in [`NOTICE`](NOTICE).
Third-party components keep their own licenses (see [`NOTICE`](NOTICE)); protocol research credits
are in [`ATTRIBUTION.md`](ATTRIBUTION.md). By opening a pull request you agree that your contribution
is licensed under the same terms.

"WHOOP" is used only to identify the hardware this software interoperates with. NOOP contains no
WHOOP code, firmware, logos or assets.
