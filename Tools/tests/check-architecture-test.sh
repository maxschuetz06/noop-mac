#!/bin/sh
# Self-test for Tools/check-architecture.sh: runs it against throwaway fixture trees.
set -eu

check="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)/check-architecture.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
failures=0

fail() { echo "FAIL: $1" >&2; failures=$((failures + 1)); }

# expect <name> <expected-exit> <expected-output-or-empty>
expect() {
    name=$1 want_status=$2 want_output=$3
    status=0
    output=$("$check" "$work/$name") || status=$?
    [ "$status" -eq "$want_status" ] || fail "$name: exit $status, expected $want_status"
    [ "$output" = "$want_output" ] || fail "$name: output was [$output], expected [$want_output]"
}

fixture() {
    mkdir -p "$work/$1/$(dirname -- "$2")"
    cat > "$work/$1/$2"
}

fixture clean Strand/Screens/Today/TodayView.swift <<'SWIFT'
// Repository.storeHandle() and StrainScorer stay out of views; SleepStagerV2 is mentioned only here.
/* A block comment may name storeHandle() and
   StrainScorer.strain(...) across lines. */
let rr = await repo.rrIntervals(from: 0, to: 1, limit: 10)
let label = "storeHandle() StrainScorer SleepStager"
let fraction = Repository.effortFraction(strain) // not StrainScorer.maxStrain
let renamed = myStoreHandle(x) + StrainScorerish
SWIFT
expect clean 0 ''

fixture violations Strand/Screens/Today/TodayView+Loading.swift <<'SWIFT'
let a = 1
guard let store = await repo.storeHandle() else { return }
let max = StrainScorer.maxStrain
let s = SleepStagerV2.stage(epochs) /* trailing */
let b = repo.storeHandle ()
let open = repo.storeHandle
let text = "count \(await repo.storeHandle()?.count ?? 0) rows"
let ok = "\(title) storeHandle StrainScorer (\(n))"
SWIFT
expect violations 1 'Strand/Screens/Today/TodayView+Loading.swift:2: storeHandle: guard let store = await repo.storeHandle() else { return }
Strand/Screens/Today/TodayView+Loading.swift:3: StrainScorer: let max = StrainScorer.maxStrain
Strand/Screens/Today/TodayView+Loading.swift:4: SleepStager: let s = SleepStagerV2.stage(epochs) /* trailing */
Strand/Screens/Today/TodayView+Loading.swift:5: storeHandle: let b = repo.storeHandle ()
Strand/Screens/Today/TodayView+Loading.swift:6: storeHandle: let open = repo.storeHandle
Strand/Screens/Today/TodayView+Loading.swift:7: storeHandle: let text = "count \(await repo.storeHandle()?.count ?? 0) rows"'

fixture outside Strand/Data/Repository+Effort.swift <<'SWIFT'
let store = await storeHandle()
let s = StrainScorer.strain(samples)
SWIFT
expect outside 0 ''

status=0
"$check" "$work/missing" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "missing root: exit $status, expected 2"

if [ "$failures" -gt 0 ]; then
    echo "$failures check-architecture self-test(s) failed" >&2
    exit 1
fi
echo "check-architecture self-test passed"
