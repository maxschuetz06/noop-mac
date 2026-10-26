#!/bin/sh
# Flags Swift string literals in Strand/ and MacWidgets/ that look German.
#
# The UI source language is English; German belongs in Strand/Resources/Localizable.xcstrings.
# A literal is flagged when it contains a German-only character (äöüÄÖÜß) or one of a few
# unmistakably German words. Comments are ignored. Legitimate data literals (for example WHOOP's
# German CSV header names) are listed in Tools/german-literals-allowlist.txt as `path|literal`.
#
# Usage: Tools/lint-german-literals.sh [repo-root]
# Exit status: 0 = clean, 1 = German literals found (printed as file:line: literal), 2 = usage error.

set -eu

root=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
allowlist=${GERMAN_LITERALS_ALLOWLIST:-$root/Tools/german-literals-allowlist.txt}

if [ ! -d "$root" ]; then
    echo "lint-german-literals: no such directory: $root" >&2
    exit 2
fi
[ -f "$allowlist" ] || allowlist=/dev/null

cd "$root"
files=$(for dir in Strand MacWidgets; do
    [ -d "$dir" ] && find "$dir" -type f -name '*.swift'
done | LC_ALL=C sort)

[ -n "$files" ] || exit 0

# shellcheck disable=SC2086 # word splitting of the file list is intended (paths contain no spaces)
LC_ALL=C awk -v allowlist="$allowlist" '
BEGIN {
    # Lower-case German words that do not occur in English UI text (checked against every literal in
    # the app). Compounds are covered by their most common parts.
    split("nicht noch kein keine keinen keiner und oder ist sind wird werden wurde heute gestern " \
          "dein deine deinem deinen deiner deines dich hallo uhr tage stunden minuten woche nacht " \
          "letzte letzten erholung belastung ruhepuls schlaf puls atmung sauerstoff herzfrequenz " \
          "schritte ziel vom erfasst wert werte schnitt verbunden einstellungen mehr werkzeuge suchen " \
          "treffer akku bereich bereiche daten datei fehler konnte beendet fehlgeschlagen verschieben " \
          "erledigt tagesverlauf abweichung schwach mittel niedrig hoch wach leicht tief bett " \
          "eingeschlafen aufgewacht schlafphasen gesamtschlaf schlafeffizienz tiefschlaf hauttemp " \
          "erkenntnisse einblicke gesundheit atmen entdecken vergleichen datenquellen mitteilungen " \
          "automationen laborbuch rhythmus tagesdetails intervalle laufen radfahren gehen wandern " \
          "schwimmen krafttraining nickerchen seit mitternacht ganzer berechnet verlauf ungelesen " \
          "echtzeit aktuell vorheriger abgeschlossen der dem auf bei von zu", words, " ")
    for (w in words) german[words[w]] = 1
    while ((getline entry < allowlist) > 0) {
        sub(/\r$/, "", entry)
        if (entry ~ /^#/ || entry !~ /\|/) continue
        allowed[entry] = 1
    }
    found = 0
}

FNR == 1 { sp = 0; kind[0] = "code" }

function push(k, h) { sp++; kind[sp] = k; hashes[sp] = h; buf[sp] = ""; start[sp] = FNR; parens[sp] = 0 }

function looksGerman(s,    t, n, parts, i) {
    if (s ~ /(ä|ö|ü|Ä|Ö|Ü|ß)/) return 1
    t = s
    gsub(/[^A-Za-z]/, " ", t)
    n = split(t, parts, " ")
    for (i = 1; i <= n; i++) if (tolower(parts[i]) in german) return 1
    return 0
}

function emit(    s) {
    s = buf[sp]
    if (looksGerman(s) && !((FILENAME "|" s) in allowed)) {
        printf "%s:%d: \"%s\"\n", FILENAME, start[sp], s
        found = 1
    }
    sp--
}

function hashRun(line, i,    n) {
    n = 0
    while (substr(line, i + n, 1) == "#") n++
    return n
}

function repeat(c, n,    s) { s = ""; while (n-- > 0) s = s c; return s }

# Each scanner consumes input at index i of the current line and returns the next index
# (0 = the rest of the line is a comment).
function scanComment(line, i) {
    if (substr(line, i, 2) == "/*") { push("comment", 0); return i + 2 }
    if (substr(line, i, 2) == "*/") { sp--; return i + 2 }
    return i + 1
}

function scanCode(line, i,    h, q) {
    if (substr(line, i, 2) == "//") return 0
    if (substr(line, i, 2) == "/*") { push("comment", 0); return i + 2 }
    h = hashRun(line, i)
    q = substr(line, i + h, 3)
    if (q == "\"\"\"") { push("multi", h); return i + h + 3 }
    if (substr(q, 1, 1) == "\"") { push("string", h); return i + h + 1 }
    if (kind[sp] == "interp") return scanInterpolation(line, i)
    return i + 1
}

# Inside \( ... ): track nested parentheses; the closing one returns to the enclosing literal.
function scanInterpolation(line, i,    c) {
    c = substr(line, i, 1)
    if (c == "(") parens[sp]++
    if (c != ")") return i + 1
    if (parens[sp] > 0) { parens[sp]--; return i + 1 }
    sp--
    buf[sp] = buf[sp] "\\(...)"
    return i + 1
}

function scanString(line, i,    h, closer, escape) {
    h = hashes[sp]
    closer = (kind[sp] == "multi" ? "\"\"\"" : "\"") repeat("#", h)
    if (substr(line, i, length(closer)) == closer) { emit(); return i + length(closer) }
    escape = "\\" repeat("#", h)
    if (substr(line, i, length(escape)) != escape) { buf[sp] = buf[sp] substr(line, i, 1); return i + 1 }
    i += length(escape)
    if (substr(line, i, 1) == "(") { push("interp", 0); return i + 1 }
    buf[sp] = buf[sp] "\\" substr(line, i, 1)
    return i + 1
}

{
    i = 1
    while (i > 0 && i <= length($0)) {
        if (kind[sp] == "comment") i = scanComment($0, i)
        else if (kind[sp] == "code" || kind[sp] == "interp") i = scanCode($0, i)
        else i = scanString($0, i)
    }
    # A literal still open here is multi-line; a single-line one cannot span lines (e.g. a quote
    # inside a regex literal), so drop it and resynchronise on the next line.
    if (kind[sp] == "multi") buf[sp] = buf[sp] "\\n"
    else if (kind[sp] == "string") sp--
}

END { exit found }
' $files
