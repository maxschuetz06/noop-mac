# Building NOOP for Mac

This fork builds from source only. There are no prebuilt downloads.

> **Not affiliated with WHOOP, and not a medical device.** "WHOOP" is used only to identify the
> hardware this software interoperates with. All outputs (HR, HRV, recovery, strain, sleep, SpO₂,
> temperature) are approximations and are **not** clinically validated. See
> [`DISCLAIMER.md`](../DISCLAIMER.md) and [`ATTRIBUTION.md`](../ATTRIBUTION.md).

## Repository layout

```
project.yml                 # XcodeGen definition; Strand.xcodeproj is generated from it
Config/
├── Base.xcconfig           # build identity defaults, includes Local.xcconfig
├── Local.xcconfig.example  # copy to Local.xcconfig (untracked) for your own team / bundle id
└── Strand-ExternalDataFolder.entitlements  # opt-in entitlements variant
Strand/                     # macOS SwiftUI app target (scheme Strand, product NOOP.app)
StrandTests/                # app unit tests (hosted in NOOP.app)
MacWidgets/                 # desktop widget extension (NOOPMacWidgets.appex)
Shared/                     # code shared by the app and the widget (WidgetSnapshot)
Packages/
├── WhoopProtocol/          # BLE frame parsing, CRC, command/event/packet decode
├── WhoopStore/             # GRDB/SQLite persistence (migrations, streams, caches)
├── StrandAnalytics/        # HRV / recovery / strain / sleep math
├── StrandImport/           # WHOOP CSV, Apple Health and other importers
├── StrandDesign/           # SwiftUI design system
└── NoopLocalAccess/        # read-only local database access for scripts and agents
Tools/
├── Backfill/               # `swift run backfill`: re-run importers against a database
├── install-local.sh        # signed Release build + install, using your Local.xcconfig
└── …                       # icon and String Catalog helpers
```

All third-party dependencies are resolved through Swift Package Manager and pinned to exact
versions; the app's lockfile is the tracked
`Strand.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Prerequisites

| Tool     | Version                | Notes |
|----------|------------------------|-------|
| macOS    | 13 (Ventura) or newer  | App deployment target 13.0; the widget needs macOS 14 |
| Xcode    | 26 or newer            | Provides `xcodebuild`, the macOS SDK and Swift. CI uses the default Xcode of the `macos-26` runner; development uses Xcode 27. Xcode 16 is untested |
| XcodeGen | 2.45+                  | `brew install xcodegen` |

The packages only need a Swift toolchain; they build and test with `swift build` / `swift test`.

## 1. Generate the Xcode project

```bash
xcodegen generate
```

Re-run it after changing `project.yml` or adding/removing source files. Do not edit
`Strand.xcodeproj` by hand.

## 2. Build identity

Signing settings never live in `project.yml`. `Config/Base.xcconfig` defines:

| Setting                     | Default                                   | Meaning |
|-----------------------------|-------------------------------------------|---------|
| `DEVELOPMENT_TEAM`          | empty                                     | Apple Developer team used for signing |
| `NOOP_BUNDLE_ID`            | `com.noopapp.noop`                        | App bundle id; widget `.widgets`, tests `.tests` |
| `MAC_APP_GROUP_ID`          | `$(DEVELOPMENT_TEAM).$(NOOP_BUNDLE_ID)`   | App Group shared by app and widget |
| `NOOP_EXTERNAL_DATA_FOLDER` | empty                                     | Opt-in external data folder (off) |
| `NOOP_APP_ENTITLEMENTS`     | `Strand/Resources/Strand.entitlements`    | Entitlements file for the app |

It ends with `#include? "Local.xcconfig"`, so a missing local file is fine. To build with your own
identity:

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
# then set DEVELOPMENT_TEAM and NOOP_BUNDLE_ID in Config/Local.xcconfig
```

`Config/Local.xcconfig` is ignored by git. Keep your bundle id stable: the sandbox container (and
with it the database) is keyed by the bundle id, so a new id starts with an empty store.

## 3. Unsigned build and tests (no Apple account needed)

A clean clone without `Config/Local.xcconfig` builds and tests with an ad-hoc signature:

```bash
xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- build

xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGN_IDENTITY=- test
```

The product is `build/Build/Products/Debug/NOOP.app`. Without a team the App Group id has no team
prefix, so the desktop widget cannot share data with the app; everything else works.

The app is sandboxed. Its default entitlements (`Strand/Resources/Strand.entitlements`) are the App
Sandbox, Bluetooth, user-selected file access, the App Group, and outbound network client access
(used only by the opt-in, bring-your-own-key AI Coach and the user-tapped "Check for updates"). They
contain no sandbox exceptions. The file
is maintained by hand; XcodeGen does not regenerate it.

## 4. Signed build and install

The widget extension and the team-prefixed App Group need a real signing identity ("Apple
Development"). With `DEVELOPMENT_TEAM` and `NOOP_BUNDLE_ID` set in `Config/Local.xcconfig`:

```bash
Tools/install-local.sh               # build, verify and install to /Applications, then launch
Tools/install-local.sh --dry-run     # print the commands only
Tools/install-local.sh --dest ~/Applications --no-launch
```

The script reads team and bundle id from the xcconfig files, checks for a valid "Apple Development"
certificate, builds Release into `~/Library/Caches/noop-mac-build` (log:
`~/Library/Logs/noop-local-build.log`), verifies the signature, the widget and matching App Group
entitlements, quits a running NOOP gracefully, swaps the bundle (keeping the previous one until the
new one verifies), registers the widget and launches the app. It never touches the app's data
container.

## 5. Optional external data folder

Off by default. When enabled at build time, NOOP mirrors its database for local tools, watches an
import inbox and can store raw PPG captures in a folder under your home directory. It requires both
lines in `Config/Local.xcconfig`, because the sandbox exception must name the same folder:

```
NOOP_EXTERNAL_DATA_FOLDER = NOOP-Data
NOOP_APP_ENTITLEMENTS = Config/Strand-ExternalDataFolder.entitlements
```

For a different folder name, copy the variant to `Config/Strand-ExternalDataFolder.local.entitlements`
(ignored by git), change its `home-relative-path` entry and point `NOOP_APP_ENTITLEMENTS` at it. A
build phase (`Tools/check-external-data-folder.sh`) fails the build if the folder setting and the
entitlements disagree, and keeps the default build free of sandbox exceptions. Details:
[`EXTERNAL_DATA_FOLDER.md`](EXTERNAL_DATA_FOLDER.md).

## 6. Tests

```bash
# per package (no Xcode project needed)
for p in WhoopProtocol WhoopStore StrandAnalytics StrandImport StrandDesign NoopLocalAccess; do
  (cd "Packages/$p" && swift test)
done

# app tests
xcodegen generate
xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' CODE_SIGN_IDENTITY=-

# German UI literal lint (also runs in CI)
Tools/lint-german-literals.sh
```

CI (`.github/workflows/`) runs the same steps on every push and pull request.

## 7. Re-importing data into a database

The app database lives in the sandbox container:

```
~/Library/Containers/<NOOP_BUNDLE_ID>/Data/Library/Application Support/OpenWhoop/whoop.sqlite
```

`Tools/Backfill` re-runs the WHOOP CSV / Apple Health import mapping against a database, which is
useful after changing importer logic. Quit NOOP and back up the database first.

```bash
cd Tools/Backfill
NOOP_DB_PATH=/path/to/whoop.sqlite \
WHOOP_EXPORT_PATH=/path/to/whoop-export \
APPLE_HEALTH_EXPORT_PATH=/path/to/export.zip \
swift run backfill
```

Without `NOOP_DB_PATH` it targets the container of the default bundle id `com.noopapp.noop`.

## Pairing and BLE

NOOP connects over CoreBluetooth (`Strand/BLE/BLEManager.swift`). WHOOP 4.0 uses the `61080001-…`
service family with a CRC8 header; WHOOP 5.0 / MG use the `fd4b0001-…` family with a CRC16-Modbus
header. Keep the strap out of range of the official app during the first bond, and wear and charge it
so it reports a non-zero heart rate. On first launch macOS asks for Bluetooth permission.
