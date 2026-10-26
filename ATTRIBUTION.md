# Attribution

NOOP is an independent, unofficial, local-first app for macOS. It is not affiliated
with, endorsed by, or connected to WHOOP, Inc. "WHOOP" is used nominatively only to
identify the hardware the app interoperates with.

NOOP builds on prior community reverse-engineering and interoperability work:

## WHOOP 4.0 protocol + Swift packages
- **`johnmiddleton12/my-whoop`** — the `WhoopProtocol` and `WhoopStore` Swift packages
  (vendored under `Packages/`), the WHOOP 4.0 BLE framing/command/decode work, and the
  iOS collection logic that NOOP's `WhoopBLE`/`Collect` layers are adapted from.
  See `DISCLAIMER.md` (carried over from that project).

## WHOOP 5.0 / MG protocol
- **`b-nnett/goose`** — the WHOOP 5.0 BLE reverse-engineering (service UUID family
  `fd4b0001-…`, CRC16-Modbus header, CLIENT_HELLO, and the "puffin" packet types)
  that NOOP's `DeviceFamily` Whoop-5 path and `whoop5_protocol.json` are ported from.

## Xiaomi Smart Band (Mi Band) import
- **`artyomxx/xiaomi-band-ios-export`** — documented the Mi Fitness iOS app's on-device
  SQLite layout (`DataBase/<user_id>/de/<user_id>.db`, JSON `value` columns, the `*_day`
  rollups and the `sleep` table's `items[]` hypnogram with state codes). NOOP's
  `XiaomiBandImporter` is **re-derived** from those findings and verified against a real
  Mi Band 10 export; **no code is copied** (the reference tool is AGPL, NOOP is not).
- **Gadgetbridge** (`Freeyourgadget/Gadgetbridge`) — referenced only for *protocol facts*
  about the live Mi-protobuf BLE stack in the roadmap's research notes. GPLv3; NOOP copies
  **none** of its code and has not built the live lane.

## Other
- **GRDB.swift** (`groue/GRDB.swift`) — SQLite persistence (via Swift Package Manager).

NOOP contains no WHOOP proprietary code, binaries, firmware, logos, or assets, and
performs no DRM circumvention. It operates only with the user's own device and data.
NOOP is **not a medical device**; all metrics (HR, HRV, recovery, strain, sleep,
SpO₂, temperature) are approximations and not clinically validated.
