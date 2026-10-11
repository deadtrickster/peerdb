package connpostgres

import (
	"bytes"
	"os/exec"
	"testing"
)

// The invariant this pins, stated as behaviour rather than as an implementation detail:
// a src process that runPipeline kills *on purpose* — because the destination is already
// gone, per the "kill src so it doesn't block on a pipe with no reader" comment — must
// not be reported to the caller as a failure.
//
// `true` as the destination makes that path deterministic: it exits without reading
// anything, so dstDone fires while src is still unreaped, the code kills src, and the
// fallback at the end of runPipeline reports srcErr ("signal: killed") even though
// nothing went wrong. No scheduling luck needed, unlike the flaky form of the same bug
// (cat as destination, where it depends on the src Wait goroutine losing a race).
//
// Before the fix this fails; after the fix it passes. Both directions matter: a test
// that only ever passes is exactly the artifact that makes a flake look fixed.
func TestKilledSrcIsNotReportedAsFailure(t *testing.T) {
	ctx := t.Context()

	src := exec.CommandContext(ctx, "sh", "-c", "printf 'SELECT 1;\\n'")
	dst := exec.CommandContext(ctx, "true") // exits immediately, reads nothing
	var out bytes.Buffer
	dst.Stdout = &out

	err := runPipeline(ctx, src, dst, "src", "dst", filterIncompatibleLines)
	if err != nil {
		t.Fatalf("a src the pipeline killed itself must not be reported as a failure, got: %v", err)
	}
}
