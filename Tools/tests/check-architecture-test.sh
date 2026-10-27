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

fixture strap-allowed Strand/BLE/BLEManager+StrapCommands.swift <<'SWIFT'
p.writeValue(Data(command.frame(seq: seq, payload: body)), for: ch, type: writeType)
p.writeValue(Data(puffinCommandFrame(cmd: opcode, seq: seq, payload: body)), for: ch, type: writeType)
SWIFT
fixture strap-allowed Strand/BLE/BLEManager+PeripheralDelegate.swift <<'SWIFT'
peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
SWIFT
fixture strap-allowed Strand/BLE/BLEManager+Connection.swift <<'SWIFT'
// Never call peripheral.writeValue(...) here; send() owns strap writes.
log("writeValue(skipped)")
let x = rewriteValue(a) + writeValues(b)
SWIFT
expect strap-allowed 0 ''

fixture strap-violations Strand/BLE/BLEManager+Connection.swift <<'SWIFT'
peripheral.writeValue(Data(frame), for: c, type: .withResponse)
SWIFT
fixture strap-violations Strand/Screens/DevicesView.swift <<'SWIFT'
let hint = "\(p.writeValue (d, for: c, type: .withoutResponse))"
SWIFT
fixture strap-violations Packages/WhoopProtocol/Sources/WhoopProtocol/Probe.swift <<'SWIFT'
func probe(_ p: CBPeripheral) { p.writeValue(d, for: descriptor) }
SWIFT
fixture strap-violations Strand/BLE/BLEManager+StrapCommands.swift <<'SWIFT'
p.writeValue(Data(command.frame(seq: seq, payload: body)), for: ch, type: writeType)
p.writeValue(Data(puffinCommandFrame(cmd: opcode, seq: seq, payload: body)), for: ch, type: writeType)
p.writeValue(Data(raw), for: ch, type: .withoutResponse)
SWIFT
expect strap-violations 1 'Packages/WhoopProtocol/Sources/WhoopProtocol/Probe.swift:1: strapWrite: func probe(_ p: CBPeripheral) { p.writeValue(d, for: descriptor) }
Strand/BLE/BLEManager+Connection.swift:1: strapWrite: peripheral.writeValue(Data(frame), for: c, type: .withResponse)
Strand/BLE/BLEManager+StrapCommands.swift:3: strapWrite: p.writeValue(Data(raw), for: ch, type: .withoutResponse)
Strand/Screens/DevicesView.swift:1: strapWrite: let hint = "\(p.writeValue (d, for: c, type: .withoutResponse))"'

fixture strap-same-line Strand/BLE/BLEManager+StrapCommands.swift <<'SWIFT'
p.writeValue(Data(a), for: ch, type: writeType); p.writeValue(Data(b), for: ch, type: writeType)
SWIFT
fixture strap-same-line Strand/BLE/BLEManager+PeripheralDelegate.swift <<'SWIFT'
peripheral.writeValue(Data(bondFrame), for: c, type: .withResponse)
peripheral.writeValue(Data(hello), for: c, type: .withResponse); peripheral.writeValue(Data(raw), for: c, type: .withResponse)
SWIFT
expect strap-same-line 1 'Strand/BLE/BLEManager+PeripheralDelegate.swift:2: strapWrite: peripheral.writeValue(Data(hello), for: c, type: .withResponse); peripheral.writeValue(Data(raw), for: c, type: .withResponse)'

status=0
"$check" "$work/missing" >/dev/null 2>&1 || status=$?
[ "$status" -eq 2 ] || fail "missing root: exit $status, expected 2"

if [ "$failures" -gt 0 ]; then
    echo "$failures check-architecture self-test(s) failed" >&2
    exit 1
fi
echo "check-architecture self-test passed"
