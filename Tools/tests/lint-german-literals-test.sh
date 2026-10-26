#!/bin/sh
# Self-test for Tools/lint-german-literals.sh: runs it against throwaway fixture trees.
set -eu

lint="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/lint-german-literals.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
failures=0

fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

# expect <name> <expected-exit> <expected-output-or-empty> [allowlist-content]
expect() {
    name=$1 want_status=$2 want_output=$3
    root="$work/$name"
    printf '%s\n' "${4:-}" > "$root/allowlist.txt"
    status=0
    output=$(GERMAN_LITERALS_ALLOWLIST="$root/allowlist.txt" "$lint" "$root") || status=$?
    [ "$status" -eq "$want_status" ] || fail "$name: exit $status, expected $want_status"
    [ "$output" = "$want_output" ] || fail "$name: output was [$output], expected [$want_output]"
}

fixture() {
    mkdir -p "$work/$1/Strand" "$work/$1/MacWidgets"
    cat > "$work/$1/$2"
}

fixture clean Strand/Clean.swift <<'SWIFT'
// Übersicht: comments may stay German.
/* Kein Problem
   /* auch nicht verschachtelt */ */
let title = "Overview"
let detail = "Sleep \(hours) hours · \(label ? "Schlaf" : "Sleep")"
SWIFT
expect clean 1 'Strand/Clean.swift:5: "Schlaf"'

fixture comments Strand/Comments.swift <<'SWIFT'
// "Schlaf" inside a comment
let url = "https://example.com" // Noch kein Wert
/// Einstellungen öffnen
let raw = #"{"label":"sleep"}"#
SWIFT
expect comments 0 ''

fixture umlaut MacWidgets/Widget.swift <<'SWIFT'
let a = "Geräte"
let b = """
    multi-line
    Erholung
    """
SWIFT
expect umlaut 1 'MacWidgets/Widget.swift:1: "Geräte"
MacWidgets/Widget.swift:2: "\n    multi-line\n    Erholung\n    "'

fixture words Strand/Words.swift <<'SWIFT'
let a = "Noch kein Sync"
let b = "Your HRV is \(n) % above your average"
SWIFT
expect words 1 'Strand/Words.swift:1: "Noch kein Sync"'

fixture allowed Strand/Data.swift <<'SWIFT'
let header = "Schlafqualität %"
let other = "Schlafqualität"
SWIFT
expect allowed 1 'Strand/Data.swift:2: "Schlafqualität"' 'Strand/Data.swift|Schlafqualität %'

# A quote inside a regex literal must not swallow the following lines.
fixture regex Strand/Regex.swift <<'SWIFT'
let quote = /"/
let a = "Overview"
let b = "Schlaf"
SWIFT
expect regex 1 'Strand/Regex.swift:3: "Schlaf"'

fixture escapes Strand/Escapes.swift <<'SWIFT'
let a = "say \"Schlaf\" twice"
let b = #"Noch \#(n) Tage"#
let c = "path \\ \(x) ok"
let d = "\(f(g(x))) Stunden"
SWIFT
expect escapes 1 'Strand/Escapes.swift:1: "say \"Schlaf\" twice"
Strand/Escapes.swift:2: "Noch \(...) Tage"
Strand/Escapes.swift:4: "\(...) Stunden"'

# Allowlist files with Windows line endings still match.
fixture crlf Strand/Data.swift <<'SWIFT'
let header = "Schlafqualität %"
SWIFT
expect crlf 0 '' "$(printf 'Strand/Data.swift|Schlafqualität %%\r')"

status=0
"$lint" "$work/does-not-exist" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "missing root: exit $status, expected 2"

if [ "$failures" -ne 0 ]; then
    echo "lint-german-literals self-test: $failures failure(s)" >&2
    exit 1
fi
echo "lint-german-literals self-test: ok"
