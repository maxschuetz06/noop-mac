#!/usr/bin/env bash
#
# install-local.sh — build NOOP signed with your own team and install it.
#
# The app ships a WidgetKit extension (NOOPMacWidgets.appex) and a team-prefixed App Group,
# so it must be signed with a real team identity ("Apple Development"), not ad-hoc.
# Team and bundle id are read from Config/Base.xcconfig and Config/Local.xcconfig.
#
# Usage: Tools/install-local.sh [--dest <dir>] [--no-launch] [--dry-run] [-h|--help]

set -euo pipefail

APPEX_NAME="NOOPMacWidgets.appex"
DERIVED_DATA="${NOOP_DERIVED_DATA:-$HOME/Library/Caches/noop-mac-build}"
LOG_FILE="$HOME/Library/Logs/noop-local-build.log"
QUIT_TIMEOUT=20

DEST="/Applications"
LAUNCH=1
DRY_RUN=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Builds NOOP.app (Release) signed with the team from Config/Local.xcconfig and installs it.

Options:
  --dest <dir>  Install directory (default: /Applications)
  --no-launch   Do not launch NOOP after installing
  --dry-run     Print the commands, run nothing
  -h, --help    Show this help

Build output: $DERIVED_DATA
Build log:    $LOG_FILE
EOF
}

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || { echo "error: --dest needs a value" >&2; exit 2; }
      DEST="$2"; shift 2 ;;
    --dest=*) DEST="${1#--dest=}"; shift ;;
    --no-launch) LAUNCH=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ "$DEST" == "/" ]] || DEST="${DEST%/}"

# Always operate from the repo root, regardless of the caller's CWD.
cd "$(dirname "$0")/.."

# Last literal assignment of a setting across the xcconfig chain (Local overrides Base).
xcconfig_value() {
  local key="$1" file line value=""
  for file in Config/Base.xcconfig Config/Local.xcconfig; do
    [[ -f "$file" ]] || continue
    while IFS= read -r line; do
      value="${line#*=}"
    done < <(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file")
  done
  value="$(printf '%s' "$value" | sed -E 's|//.*$||; s/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ "$value" != *"\$("* ]] || { echo "error: $key must be a literal value, got: $value" >&2; exit 2; }
  printf '%s' "$value"
}

TEAM="$(xcconfig_value DEVELOPMENT_TEAM)"
BUNDLE_ID="$(xcconfig_value NOOP_BUNDLE_ID)"
[[ -n "$TEAM" ]] || {
  echo "error: DEVELOPMENT_TEAM is empty. Copy Config/Local.xcconfig.example to Config/Local.xcconfig and set your team." >&2
  exit 2
}
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || { echo "error: invalid DEVELOPMENT_TEAM in Config/Local.xcconfig: $TEAM" >&2; exit 2; }
[[ -n "$BUNDLE_ID" ]] || { echo "error: NOOP_BUNDLE_ID is empty" >&2; exit 2; }

PRODUCTS="$DERIVED_DATA/Build/Products/Release"
BUILT_APP="$PRODUCTS/NOOP.app"
APP="$DEST/NOOP.app"
TMP_APP="$DEST/.NOOP.installing.app"
PREV_APP="$DEST/NOOP.previous.app"

# Print a command in dry-run mode, otherwise execute it.
run() {
  if (( DRY_RUN )); then
    printf '[dry-run] '; printf '%q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

# ── Preflight ────────────────────────────────────────────────────────────────
preflight() {
  command -v xcodegen >/dev/null 2>&1 || die "xcodegen not found (brew install xcodegen)"
  command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild not found (install Xcode and run xcode-select)"

  local identities names name pem subject matches=0 first_pem="" enddate end_epoch now days
  identities="$(security find-identity -v -p codesigning 2>/dev/null | grep 'Apple Development' || true)"
  [[ -n "$identities" ]] || die "no valid 'Apple Development' codesigning identity in the keychain (Xcode > Settings > Accounts > Manage Certificates)"

  names="$(printf '%s\n' "$identities" | sed -n 's/.*"\(.*\)".*/\1/p')"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    pem="$(security find-certificate -c "$name" -p 2>/dev/null || true)"
    [[ -n "$pem" ]] || continue
    subject="$(printf '%s\n' "$pem" | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null || true)"
    if [[ "$subject" == *"OU=$TEAM"* ]]; then
      matches=$((matches + 1))
      [[ -n "$first_pem" ]] || first_pem="$pem"
      log "Signing identity: $name"
    fi
  done <<< "$names"

  if (( matches == 0 )); then
    die "no valid 'Apple Development' identity for team $TEAM. Found:
$identities"
  fi
  if (( matches > 1 )); then
    warn "$matches 'Apple Development' identities match team $TEAM; xcodebuild picks one automatically"
  fi

  enddate="$(printf '%s\n' "$first_pem" | openssl x509 -noout -enddate | sed 's/^notAfter=//')"
  log "Certificate expires: $enddate"
  if ! printf '%s\n' "$first_pem" | openssl x509 -noout -checkend $((30 * 86400)) >/dev/null; then
    if printf '%s\n' "$first_pem" | openssl x509 -noout -checkend 0 >/dev/null; then
      end_epoch="$(date -j -u -f '%b %d %T %Y %Z' "$(printf '%s' "$enddate" | tr -s ' ')" +%s 2>/dev/null || echo 0)"
      now="$(date +%s)"
      days=$(( (end_epoch - now) / 86400 ))
      warn "signing certificate expires within 30 days (${days} days left) — renew it in Xcode soon"
    else
      die "signing certificate has expired"
    fi
  fi

  [[ -d "$DEST" ]] || die "destination directory does not exist: $DEST"
  [[ -w "$DEST" ]] || die "destination directory is not writable: $DEST"
}

# ── Build ────────────────────────────────────────────────────────────────────
build() {
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
  local start=$SECONDS

  log "Generating Xcode project (xcodegen)"
  xcodegen generate >> "$LOG_FILE" 2>&1 || {
    tail -n 20 "$LOG_FILE" >&2
    die "xcodegen failed — log: $LOG_FILE"
  }

  log "Building NOOP (Release, team $TEAM) — this takes a while"
  if ! xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Release \
      -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" \
      CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" \
      DEVELOPMENT_TEAM="$TEAM" PROVISIONING_PROFILE_SPECIFIER="" \
      build >> "$LOG_FILE" 2>&1; then
    printf 'Build FAILED. Errors:\n' >&2
    { grep 'error:' "$LOG_FILE" | sort -u | head -n 20; } >&2 || true
    die "xcodebuild failed — full log: $LOG_FILE"
  fi
  [[ -d "$BUILT_APP" ]] || die "build reported success but $BUILT_APP is missing — log: $LOG_FILE"
  log "Build succeeded in $((SECONDS - start))s (log: $LOG_FILE)"
}

# ── Verification ─────────────────────────────────────────────────────────────
# Application-group entitlement value(s) of a signed bundle, as JSON.
app_groups() {
  codesign -d --entitlements :- "$1" 2>/dev/null \
    | plutil -extract 'com\.apple\.security\.application-groups' json -o - - 2>/dev/null || true
}

verify_bundle() {
  local app="$1" appex="$1/Contents/PlugIns/$APPEX_NAME" app_groups_val appex_groups_val team_id

  codesign --verify --deep --strict "$app" 2>&1 || die "codesign verification failed: $app"
  [[ -d "$appex" ]] || die "widget extension missing: $appex"

  team_id="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$team_id" == "$TEAM" ]] || die "app is signed with team '${team_id:-none}', expected $TEAM (ad-hoc build?)"

  app_groups_val="$(app_groups "$app")"
  appex_groups_val="$(app_groups "$appex")"
  [[ -n "$app_groups_val" ]] || die "app has no com.apple.security.application-groups entitlement"
  [[ -n "$appex_groups_val" ]] || die "widget extension has no com.apple.security.application-groups entitlement"
  [[ "$app_groups_val" == "$appex_groups_val" ]] \
    || die "application-groups differ: app=$app_groups_val widget=$appex_groups_val"
  log "Verified $app (team $team_id, app group $app_groups_val)"
}

# ── Install ──────────────────────────────────────────────────────────────────
is_running() {
  [[ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null || true)" == "true" ]]
}

quit_app() {
  is_running || return 0
  log "NOOP is running — asking it to quit"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  local i
  for ((i = 0; i < QUIT_TIMEOUT * 2; i++)); do
    is_running || return 0
    sleep 0.5
  done
  die "NOOP did not quit within ${QUIT_TIMEOUT}s — quit it manually and re-run (it is never force-killed)"
}

install_app() {
  quit_app

  rm -rf "$TMP_APP"
  log "Copying to $TMP_APP"
  ditto "$BUILT_APP" "$TMP_APP"
  verify_bundle "$TMP_APP"

  rm -rf "$PREV_APP"
  if [[ -e "$APP" ]]; then
    mv "$APP" "$PREV_APP"
  fi
  mv "$TMP_APP" "$APP" || {
    [[ -e "$PREV_APP" ]] && mv "$PREV_APP" "$APP"
    die "install failed, previous app restored"
  }

  # verify_bundle calls die (exit); run it in a subshell so the rollback below stays reachable.
  if ! (verify_bundle "$APP"); then
    warn "installed bundle failed verification — rolling back"
    rm -rf "$APP"
    [[ ! -e "$PREV_APP" ]] || mv "$PREV_APP" "$APP"
    die "install rolled back"
  fi
  rm -rf "$PREV_APP"
  log "Installed $APP"
}

# ── Main ─────────────────────────────────────────────────────────────────────
if (( DRY_RUN )); then
  log "Dry run — team $TEAM, bundle id $BUNDLE_ID, destination $DEST (nothing will be executed)"
  echo "[dry-run] preflight: xcodegen/xcodebuild present, 'Apple Development' identity for team $TEAM, certificate expiry, $DEST writable"
  echo "[dry-run] cd $(pwd)"
  run xcodegen generate
  run xcodebuild -project Strand.xcodeproj -scheme Strand -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" \
    DEVELOPMENT_TEAM="$TEAM" PROVISIONING_PROFILE_SPECIFIER="" build
  echo "[dry-run] (build output is logged to $LOG_FILE; only a summary is printed)"
  run codesign --verify --deep --strict "$BUILT_APP"
  echo "[dry-run] check $BUILT_APP/Contents/PlugIns/$APPEX_NAME exists and app + appex carry the same com.apple.security.application-groups entitlement"
  run osascript -e "tell application id \"$BUNDLE_ID\" to quit"
  echo "[dry-run] wait up to ${QUIT_TIMEOUT}s for NOOP to quit (never kill -9)"
  run ditto "$BUILT_APP" "$TMP_APP"
  echo "[dry-run] verify $TMP_APP"
  if [[ -e "$APP" ]]; then run mv "$APP" "$PREV_APP"; fi
  run mv "$TMP_APP" "$APP"
  echo "[dry-run] verify $APP, then remove $PREV_APP (rollback on failure)"
  run rm -rf "$PREV_APP"
  run pluginkit -a "$APP/Contents/PlugIns/$APPEX_NAME"
  if (( LAUNCH )); then run open "$APP"; fi
  exit 0
fi

preflight
build
verify_bundle "$BUILT_APP"
install_app

log "Registering widget extension"
pluginkit -a "$APP/Contents/PlugIns/$APPEX_NAME" || warn "pluginkit registration failed (widget may need a relaunch)"

if (( LAUNCH )); then
  log "Launching NOOP"
  open "$APP"
fi

VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
BUILD_NUM="$(defaults read "$APP/Contents/Info" CFBundleVersion 2>/dev/null || echo '?')"
echo
echo "NOOP $VERSION (build $BUILD_NUM) installed at $APP"
echo "Build log: $LOG_FILE"
