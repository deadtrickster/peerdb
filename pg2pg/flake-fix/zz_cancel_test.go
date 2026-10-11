package connpostgres

import (
	"bytes"
	"context"
	"errors"
	"os/exec"
	"testing"
	"time"
)

// A cancelled context, mid-pipeline. The children are bound to it, so exec.CommandContext
// SIGKILLs both - that part is correct. What the caller is told is not: runPipeline reports
// it as "<side> failed: signal: killed", i.e. as a failure of the peer, when the cause was
// the caller's own cancellation. Deterministic: src sleeps well past the cancel.
func TestCancelledContextIsReportedAsCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()

	src := exec.CommandContext(ctx, "sh", "-c", "sleep 5; printf 'SELECT 1;\\n'")
	dst := exec.CommandContext(ctx, "cat")
	var out bytes.Buffer
	dst.Stdout = &out

	go func() { time.Sleep(50 * time.Millisecond); cancel() }()

	err := runPipeline(ctx, src, dst, "src", "dst", filterIncompatibleLines)
	if err == nil {
		t.Fatal("expected an error from the cancelled pipeline")
	}
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("a cancelled context must be reported as cancellation, got: %v", err)
	}
}
