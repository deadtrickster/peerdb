#!/bin/bash
# Reproducer for the "src failed: signal: killed" flake in runPipeline.
#
#   bash reproduce.sh [path-to-peerdb-checkout]     (default: the current directory)
#
# Three phases, all with `go test -overlay`, so the checkout is never modified:
#
#   RED       unmodified code          -> the invariant test FAILS (deterministically)
#   GREEN     guarded fallback         -> it passes, and the original test still passes
#   MUTATION  filter stops filtering   -> the ORIGINAL test still fails on its assertion
#
# The third phase is the point: a flake "fixed" by weakening its test is not fixed.
set -u
REPO=${1:-$PWD}
HERE=$(cd "$(dirname "$0")" && pwd)
PKG=flow/connectors/postgres

command -v go >/dev/null 2>&1 || { echo "need go on PATH"; exit 2; }
[ -d "$REPO/$PKG" ] || { echo "not a peerdb checkout: $REPO"; exit 2; }

mk_overlay() { # $1 = source for pgdump_schema.go ("" = leave the original), $2 = output json
  python3 - "$REPO" "$HERE" "$1" "$2" <<'PY'
import json, sys
repo, here, src, out = sys.argv[1:5]
repl = {f"{repo}/flow/connectors/postgres/zz_killed_src_test.go": f"{here}/zz_killed_src_test.go"}
if src:
    repl[f"{repo}/flow/connectors/postgres/pgdump_schema.go"] = f"{here}/{src}"
json.dump({"Replace": repl}, open(out, "w"), indent=2)
PY
}

export TZ=UTC
cd "$REPO/flow" || exit 2

echo "== RED: unmodified code; the invariant test must FAIL"
mk_overlay "" /tmp/overlay-red.json
out=$(go test ./connectors/postgres -overlay=/tmp/overlay-red.json \
        -run TestKilledSrcIsNotReportedAsFailure -count=3 2>&1)
echo "$out" | grep -E "^(--- FAIL|ok|FAIL)" | tail -3
echo "occurrences of the message: $(echo "$out" | grep -c 'src failed: signal: killed')  (expect 3)"

echo
echo "== GREEN: guarded fallback; invariant test and the original must both PASS"
mk_overlay "pgdump_schema.fixed.go" /tmp/overlay-green.json
go test ./connectors/postgres -overlay=/tmp/overlay-green.json \
  -run 'TestKilledSrcIsNotReportedAsFailure|TestRunPipeline_FilterStripsLines' -count=5 2>&1 | tail -2

echo
echo "== MUTATION: with a filter that no longer filters, the ORIGINAL test must still fail"
mk_overlay "pgdump_schema.nofilter.go" /tmp/overlay-mutation.json
go test ./connectors/postgres -overlay=/tmp/overlay-mutation.json \
  -run TestRunPipeline_FilterStripsLines -count=1 2>&1 | grep -E "filtered output|--- FAIL|^ok|^FAIL" | head -3
