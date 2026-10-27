# External data folder (opt-in)

NOOP is a sandboxed app: by default everything it stores, including your health database, stays in
its sandbox container (`~/Library/Containers/<bundle id>/`), and nothing is written anywhere else.

A build can opt into one extra folder in your home directory, for example `~/NOOP-Data`. NOOP then
uses it for three things:

| What | Where | Purpose |
|---|---|---|
| Database mirror | `<folder>/whoop-latest.sqlite` | Read-only copy of the NOOP database for local tools and AI agents (for example `noop-local-access`) |
| Import inbox | `<folder>/Import/` | Drop a WHOOP export here and NOOP imports it automatically |
| Raw PPG capture | `<folder>/raw-ppg/` | Experimental, off by default: raw optical history frames for SpO₂ research |

The option is chosen when the app is built, not in the app. A build without it has none of these
features: no mirror, no inbox, and the raw PPG setting is hidden.

## Privacy implications

Read this before you enable it.

- **A full copy of your health data leaves the sandbox.** `whoop-latest.sqlite` contains everything
  NOOP has stored (heart rate, HRV, sleep, workouts, imported WHOOP history). Files in your home
  directory are not protected by macOS app data protection: any process running as your user can
  read them, including scripts, AI agents, sync clients and backup tools. Do not place the folder in a
  cloud-synced location (iCloud Drive, Dropbox, …) unless you want the data uploaded there.
- **Permissions.** NOOP creates the folder and its subfolders with mode `0700` and its files with mode
  `0600`, so other local user accounts cannot read them. When NOOP writes into an existing folder it
  tightens that folder to `0700` as well. Exports you drop into the inbox keep the permissions you gave
  them.
- **Sandbox exception.** Reaching the folder needs the entitlement
  `com.apple.security.temporary-exception.files.home-relative-path.read-write` for exactly that folder.
  It is not part of the default entitlements; it lives in a separate file you select explicitly.
- **Raw PPG capture** writes roughly 100 MB per night while it is switched on. Files are kept for
  30 days and at most 2 GB in total (oldest days deleted first; a day written within the last 24 hours
  is never deleted).

## How to opt in

Builds read their per-machine settings from `Config/Local.xcconfig` (untracked; start from
`Config/Local.xcconfig.example`, see [`BUILD.md`](BUILD.md)). Add both lines:

```
NOOP_EXTERNAL_DATA_FOLDER = NOOP-Data
NOOP_APP_ENTITLEMENTS = Config/Strand-ExternalDataFolder.entitlements
```

`NOOP_EXTERNAL_DATA_FOLDER` becomes the Info.plist key `NOOPExternalDataFolder`.
`NOOP_APP_ENTITLEMENTS` is the app's `CODE_SIGN_ENTITLEMENTS`; the tracked variant
`Config/Strand-ExternalDataFolder.entitlements` grants access to `/NOOP-Data/`.

Use a new, dedicated folder. NOOP sets the data folder itself to mode `0700`, also when it already
existed, so well-known home folders are refused: `Applications`, `Desktop`, `Documents`, `Downloads`,
`Library`, `Movies`, `Music`, `Pictures`, `Public` and `Sites`, in any capitalisation. With one of these
names the feature stays off (as if no folder were set). Other folders that already exist keep their
permissions; only folders NOOP creates itself (`Import/`, `Done/`, `raw-ppg/`, …) get `0700`.

The two lines belong together. The folder name must be a single folder directly in your home
directory: letters, digits, `-`, `_` and `.` only, no spaces, no `/`, no `~`, not `.` or `..`. The build
fails if the name is invalid or does not match the entitlements file.

### Using a different folder name

To use a folder other than `~/NOOP-Data`, for example `~/MyFolder`:

1. Copy `Config/Strand-ExternalDataFolder.entitlements` to
   `Config/Strand-ExternalDataFolder.local.entitlements`. Files named `Config/*.local.entitlements` are
   ignored by git.
2. In the copy, change the `home-relative-path` entry from `/NOOP-Data/` to `/MyFolder/` (leading and
   trailing slash included).
3. In `Config/Local.xcconfig`:

   ```
   NOOP_EXTERNAL_DATA_FOLDER = MyFolder
   NOOP_APP_ENTITLEMENTS = Config/Strand-ExternalDataFolder.local.entitlements
   ```

Rebuild and relaunch the app afterwards. To opt out again, remove both lines and rebuild; the folder
and its files stay where they are until you delete them yourself.

## Folder layout

```
~/NOOP-Data/
├── whoop-latest.sqlite      database mirror (replaced atomically on every refresh)
├── README.txt
├── Import/
│   ├── README.txt           how the inbox works
│   ├── import-log.txt       one line per import
│   ├── Done/                imported exports
│   └── Failed/              failed exports, each with a <name>.error.txt
└── raw-ppg/                 only when raw PPG capture is switched on
    ├── 2026-10-25.bin.gz    finished days, gzip
    └── 2026-10-26.bin       the day being written
```

NOOP never deletes files it did not create; the only files of yours it moves are the exports you drop
into `Import/`. Folders and files from earlier builds
with German names (`Erledigt`, `Fehler`, `LIESMICH.txt`) stay untouched and are never scanned for
imports.

## Database mirror

The mirror is refreshed after every completed strap sync, during long history downloads, after each
daily backup and shortly after launch, at most once every 10 minutes. Each refresh uses SQLite's
online backup into a `.partial` file (created with mode `0600`), verifies it with
`PRAGMA quick_check` and then renames it over `whoop-latest.sqlite`, so readers never see a
half-written file. Changes made to the copy are lost on the next refresh and never reach NOOP.

## Import inbox

Drop a WHOOP export into `Import/`: the ZIP file from WHOOP's data export or the unpacked folder with
the CSV files (`physiological_cycles.csv`, `sleeps.csv`, `workouts.csv`, `journal_entries.csv`, or their
German, Spanish and French names). While NOOP is running it scans the folder after launch, every two
minutes and whenever the folder changes. An item is imported once it looked identical on two scans and
has not been modified for 10 seconds, so a file that is still being copied is left alone. Imports run
one at a time and never while you are importing manually in the app.

Successful items move to `Import/Done/`, failed ones to `Import/Failed/` with a note naming the reason;
both get a timestamp prefix. Every attempt is logged in `import-log.txt`. Unknown and hidden files stay
where they are.

## How `noop-local-access` finds the mirror

The CLI/MCP server in `Packages/NoopLocalAccess` resolves the database in this order:

1. `--db-path` / `NOOP_DB_PATH` if set. This path must exist; there is no fallback.
2. The mirror in the external data folder: `~/$NOOP_DATA_FOLDER/whoop-latest.sqlite` when
   `NOOP_DATA_FOLDER` is set, otherwise `~/NOOP-Data/whoop-latest.sqlite`. The legacy
   `~/NOOP-Daten/whoop-latest.sqlite` (the folder name of earlier builds) is only used while
   `~/NOOP-Data` does not exist, because a leftover legacy mirror stops being updated once the app
   writes to `~/NOOP-Data`. Whenever it is used, a one-line warning with its modification date goes to
   stderr, which MCP clients show as the server log.
3. The app's sandbox container (`~/Library/Containers/<bundle id>/…/whoop.sqlite`), which macOS
   usually blocks for other processes.

If you use a folder name other than `NOOP-Data`, set `NOOP_DATA_FOLDER` to the same value as
`NOOP_EXTERNAL_DATA_FOLDER`, or point `NOOP_DB_PATH` at the mirror file directly.
