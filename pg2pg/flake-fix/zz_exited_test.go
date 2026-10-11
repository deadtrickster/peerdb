package connpostgres

import (
	"bytes"
	"os/exec"
	"testing"
)

// Both children exit immediately and successfully. If the pipeline kills a src that has
// ALREADY exited (a zombie), kill(2) is a no-op and Wait returns the real status (0), so
// this must pass. If it FAILS with "src failed: signal: killed", then a self-kill of an
// already-exited source is enough to produce the flake's message - which would mean the
// observed failure could be the dst-success path rather than a cancelled context.
func TestBothExitedIsNotAFailure(t *testing.T) {
	ctx := t.Context()
	src := exec.CommandContext(ctx, "true")
	dst := exec.CommandContext(ctx, "true")
	var out bytes.Buffer
	dst.Stdout = &out
	if err := runPipeline(ctx, src, dst, "src", "dst", filterIncompatibleLines); err != nil {
		t.Fatalf("both sides exited 0; got: %v", err)
	}
}
