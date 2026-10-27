#!/usr/bin/env bash
#
# Build-phase guard: the external data folder setting and the app entitlements must agree.
# - NOOP_EXTERNAL_DATA_FOLDER empty: the entitlements must not grant a home-relative sandbox exception.
# - NOOP_EXTERNAL_DATA_FOLDER set: it must be a plain folder name that is not a well-known home folder
#   (same list as ExternalDataFolder.wellKnownHomeFolders, any case; NOOP tightens the data folder to
#   0700) and the entitlements must grant read-write access to exactly "/<folder>/".
# Inputs come from the Xcode build environment; writes a stamp file to SCRIPT_OUTPUT_FILE_0.

set -euo pipefail

folder="${NOOP_EXTERNAL_DATA_FOLDER:-}"
entitlements="$SRCROOT/$NOOP_APP_ENTITLEMENTS"
key='com\.apple\.security\.temporary-exception\.files\.home-relative-path\.read-write'

fail() { echo "error: $*" >&2; exit 1; }

[[ -f "$entitlements" ]] || fail "entitlements file not found: $entitlements"
entry() { plutil -extract "$key.$1" raw -o - "$entitlements" 2>/dev/null || true; }
first="$(entry 0)"
second="$(entry 1)"

if [[ -z "$folder" ]]; then
  [[ -z "$first" ]] || fail "$NOOP_APP_ENTITLEMENTS grants a home-relative exception but NOOP_EXTERNAL_DATA_FOLDER is empty"
else
  [[ "$folder" =~ ^[A-Za-z0-9._-]+$ && "$folder" != "." && "$folder" != ".." ]] \
    || fail "NOOP_EXTERNAL_DATA_FOLDER must be a single folder name, got: $folder"
  case "$(printf '%s' "$folder" | tr '[:upper:]' '[:lower:]')" in
    applications|desktop|documents|downloads|library|movies|music|pictures|public|sites)
      fail "NOOP_EXTERNAL_DATA_FOLDER must be a new, dedicated folder, not the well-known home folder \"$folder\"; see docs/EXTERNAL_DATA_FOLDER.md" ;;
  esac
  [[ "$first" == "/$folder/" && -z "$second" ]] \
    || fail "$NOOP_APP_ENTITLEMENTS must grant exactly \"/$folder/\" (found: ${first:-none}); see docs/EXTERNAL_DATA_FOLDER.md"
fi

touch "$SCRIPT_OUTPUT_FILE_0"
