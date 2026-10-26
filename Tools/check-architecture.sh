#!/bin/sh
# Layering guard for the macOS app: views read and write data only through named Repository methods
# and never run the analytics scorers themselves.
#
# Flags, in Swift code under Strand/Screens/ (comments and string literals are ignored; the code inside
# string interpolations is checked):
#   storeHandle    the raw WhoopStore handle (Repository.storeHandle), called or referenced — use a
#                  named Repository method instead
#   StrainScorer   strain scoring belongs to Repository / StrandAnalytics callers in Strand/Data
#   SleepStager    sleep staging likewise (also matches SleepStagerV2)
#
# Usage: Tools/check-architecture.sh [repo-root]
# Exit status: 0 = clean, 1 = violations found (printed as file:line: rule: code), 2 = usage error.

set -eu

root=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
if [ ! -d "$root" ]; then
    echo "check-architecture: no such directory: $root" >&2
    exit 2
fi

cd "$root"
[ -d Strand/Screens ] || exit 0
files=$(find Strand/Screens -type f -name '*.swift' | LC_ALL=C sort)
[ -n "$files" ] || exit 0

# shellcheck disable=SC2086 # word splitting of the file list is intended (paths contain no spaces)
LC_ALL=C awk '
FNR == 1 { inBlock = 0 }

# Returns the line with comments and string-literal text removed (block comments may span lines). The
# code of a `\(...)` interpolation is kept: inside it, `depth` counts open parentheses until the string
# resumes.
function codeOnly(line,    out, i, c, n, inString, depth) {
    out = ""; inString = 0; depth = 0; n = length(line)
    for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (inBlock) {
            if (c == "*" && substr(line, i + 1, 1) == "/") { inBlock = 0; i++ }
            continue
        }
        if (inString) {
            if (c == "\\" && substr(line, i + 1, 1) == "(") { inString = 0; depth = 1; out = out " ("; i++; continue }
            if (c == "\\") { i++; continue }
            if (c == "\"") { inString = 0; out = out c }
            continue
        }
        if (depth > 0 && c == "(") depth++
        if (depth > 0 && c == ")" && --depth == 0) { inString = 1; out = out ") "; continue }
        if (c == "/" && substr(line, i + 1, 1) == "/") break
        if (c == "/" && substr(line, i + 1, 1) == "*") { inBlock = 1; i++; continue }
        if (c == "\"") inString = 1
        out = out c
    }
    return out
}

function report(rule, raw) {
    sub(/^[ \t]+/, "", raw)
    printf "%s:%d: %s: %s\n", FILENAME, FNR, rule, raw
    found = 1
}

{
    code = codeOnly($0)
    if (code ~ /(^|[^A-Za-z0-9_])storeHandle([^A-Za-z0-9_]|$)/) report("storeHandle", $0)
    if (code ~ /(^|[^A-Za-z0-9_])StrainScorer([^A-Za-z0-9_]|$)/) report("StrainScorer", $0)
    if (code ~ /(^|[^A-Za-z0-9_])SleepStager[A-Za-z0-9_]*/) report("SleepStager", $0)
}

END { exit found ? 1 : 0 }
' $files
