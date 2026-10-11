# Running the PeerDB suite inside a firecode VM

An attempt to run **the whole suite** in one firecode microVM, and what came of it.
Written 2026-10-11 by the session that did it, against `b5d9e813` on branch
`firecode-pg2pg`. Raw logs for every step are in `suite-logs/`.

Guest: Ubuntu 24.04 arm64, kernel `7.0.0-38-generic`, 4 vCPU, 16 GB RAM, root overlay
16 GB, project drive 12 GB. Booted with `firecode up --project /Users/dead/Projects/peerdb --mem 16384`.

## Result

| tier | what | result |
|---|---|---|
| 1 | Go unit tests: `flow`, `flow/pkg`, `e2e_cleanup` (build + vet), `TZ=UTC` | **pass** — `flow` 30 packages `ok`, `pkg` all `ok`, cleanup clean |
| 2 | `golangci-lint v2.14.0` over the three modules, under a `go work` | **pass** — `0 issues.` for each |
| 3 | `cargo test -- --test-threads=1` in `nexus` (CI's invocation) | **pass** — 29 × `test result: ok`, doctests included; the credentialed tests skip themselves |
| 4 | Tilt: core compose + images, then an e2e package | **not achievable in this guest** — see below |

## The commands, since they are the reproducible part

    # layer, once per project path (packages and caches in $HOME persist; the project drive does not)
    bash pg2pg/00-setup-postgres.sh                     # PG 18 cluster, catalog + source + dest
    apt-get install -y curl gcc libgeos-dev pkg-config build-essential libssl-dev protobuf-compiler
    # Go 1.27.1 from go.dev; buf from its release; rustup stable; then:
    cd flow && go build -o /tmp/peerflow . && sudo install -m0755 /tmp/peerflow /usr/local/bin/peerflow
    export CARGO_TARGET_DIR=$HOME/cargo-target          # Rust will not fit on the 12 GB project drive
    cd nexus && cargo fetch                             # registry cache, persists
    go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.14.0

    # tier 1
    export TZ=UTC
    cd flow     && go test ./... -timeout 600s
    cd flow/pkg && go test ./... -timeout 300s
    cd e2e_cleanup && go build ./... && go vet ./...

    # tier 2  (CI uses a go work over these three modules)
    go work init ./flow ./flow/pkg ./e2e_cleanup
    (cd flow && golangci-lint run --timeout 15m) ; (cd flow/pkg && golangci-lint run) ; (cd e2e_cleanup && golangci-lint run)

    # tier 3  (catalog must be migrated first: /usr/local/bin/peerflow migrate)
    export PEERDB_CATALOG_HOST=127.0.0.1 PEERDB_CATALOG_PORT=5432 PEERDB_CATALOG_USER=postgres \
           PEERDB_CATALOG_PASSWORD=postgres PEERDB_CATALOG_DATABASE=peerdb_catalog PEERDB_LOG_DIR=/tmp
    cd nexus && cargo test --no-run && cargo test -- --test-threads=1

Two failures along the way were environment, not code, and both are worth knowing:

**A flake that only shows under load.** `TestRunPipeline_FilterStripsLines`
(`flow/connectors/postgres`) failed once under full `./...` parallelism with
`src failed: signal: killed`, then passed on the immediate re-run and **10/10 in isolation**. It
spawns real children (`printf`, `cat`) via `exec.CommandContext(t.Context())` and treats any
non-nil error as fatal, so a SIGKILL during a loaded run reads as a failure — the neighbouring
test in the same file explicitly tolerates `"killed"`/`"signal"`. That looks like a test bug
that CI's `-p 32` on a bigger box hides.

**The disk ceiling, which lies in both directions.** `cargo test` returned 1 with 16 test
binaries `ok`: the doctest step could not create `/tmp/rustdoctest…`
(`kind: StorageFull ... No space left on device`) because the root overlay was at 100%
(`cargo-target` 6.3 GB + Go build cache 3.7 GB + module cache 2.9 GB against 16 GB). Reading the
exit code alone says "Rust tests failing"; reading the tail alone says "all ok". Only the disk
number told the truth. Fixed by `go clean -cache`, pointing `TMPDIR` at the project drive, and
re-running: 29 × `ok`.

## Tier 4: why the Tilt stack does not run here

The stack is `docker-compose-dev.yml` (14 services) plus five images built from this repo, driven
by `tilt up`. Docker installs fine (`docker.io` + `docker-compose-v2`), and the guest has systemd,
so this is not about the daemon's packaging. It fails on the kernel:

    failed to mount overlay: invalid argument                      # nested overlayfs
    iptables: Failed to initialize nft: Protocol not supported     # no nf_tables
    modprobe: Module nf_conntrack not found in directory /lib/modules/7.0.0-38-generic
    Failed to create bridge docker0 via netlink: operation not supported

The guest ships **no kernel module tree at all** and cannot create a bridge. `fuse-overlayfs`
fixes the storage half (`[graphdriver] trying configured driver: fuse-overlayfs`), and
`--iptables=false` gets past the NAT chain, but then it dies creating `docker0`. With no bridge
there is no default network, so compose's service-name networking (which the .env and the e2e
suites rely on) has nothing to resolve against. `--bridge=none` plus host networking would start
containers, but that is a different stack from the one CI runs, and a suite passing on it would
not be evidence about CI.

So tier 4 needs either a guest kernel with bridge/nf_tables support, or a machine with a real
container runtime. Not a tuning problem.

## Two corrections to what this session said earlier

1. **The pack does include gitignored files.** I claimed the opposite, and used it to explain a
   missing `flow/generated` — both wrong. Measured in the guest: `flow/generated/protos/flow.pb.go`
   with the host's **mtime of Oct 8 17:57**, `nexus/target` at **4.0 GB**, `ui/node_modules` at
   **679 MB**, all present. What I had actually read was *letibot's* exclude list
   (`target`, `node_modules`, `.claude/worktrees` in `FirecodeSpec`): the backend filters the copy
   it makes before calling `up`, which is why a backend-made copy looks clean and a direct `up` on
   a working tree does not. The usage text's "gitignored files … are left out by default" does not
   match what this build did.
2. **Therefore `./generate-protos.sh` was not needed.** The generated protos arrived with the
   pack; re-running it was harmless but unnecessary, and my stated reason for it was false.

Two consequences worth acting on: a direct `up` on a working tree copies however many GB of build
output the host has — use `--exclude target --exclude node_modules --exclude .next`; and because
the *project* drive is re-packed from the host every run while `$HOME` and the root overlay
persist, the caches that actually pay are the ones under `$HOME` (Go build cache, cargo registry,
`CARGO_TARGET_DIR`), not anything inside the checkout.

## The flake: two defects reproduced — and the original occurrence still unexplained

This section replaces an earlier version of itself that overclaimed: it said the flake *is* a
two-line hole and that the patch is the whole fix. That is wrong, and the distinction matters.

| | reliable red? | fixed by `flake-fix/patch.diff`? |
|---|---|---|
| **A** — the pipeline kills a live `src` by design (the destination is already gone) and then reports that kill as `src failed: signal: killed` | **yes, deterministic** — a destination that exits first (`true`) leaves `src` alive when the branch fires; 3/3 with the invariant test, 4/4 with both sides exiting 0 | **yes** — two added conditions |
| **B** — a cancelled context is reported as `<side> failed: signal: killed` instead of as cancellation | **yes, deterministic** — cancel 50 ms into a pipeline whose `src` sleeps 5 s; 5/5, naming `dst` | **no** — nothing was killed by this function, so the guard passes and the message is unchanged |
| **the observation** — `cat` as destination, whole module, 4 vCPU guest, one occurrence | **no** | n/a |

**Why A cannot be the observation.** With `cat`, the destination exits only after `src`'s stdout
reaches EOF — i.e. after `src` has exited. A kill from the dst branch would land on a zombie, be
discarded, and leave the real status in place. So A cannot produce that message in that
configuration. It is a genuine defect, just not this one.

**Why B is likely but unproven.** The message needs a SIGKILL delivered to a *live* child, and
with this code the only in-process route to that is `exec.CommandContext`'s Cancel. But
`TestRunPipeline_FilterStripsLines` cancels nothing, so either something cancels `t.Context()` in
that environment (which I have not identified), or the kill came from **outside** the process —
an OOM killer is the obvious candidate for a 4 vCPU guest running the whole module at `-p 4`, and
it would explain both the single occurrence and the complete failure to reproduce it on a quieter
18-core host.

**Correction to the earlier version of this section.** The reported side does *not* identify the
path: the `src` branch sets `dstKilled` when it kills a destination that has not been reaped, so a
cancellation can surface as either side depending on which `Wait()` lands first — the synthetic
cancellation test above names `dst` while the guest named `src`.

**The experiment that would settle it.** An instrumented overlay that logs `srcKilled`,
`dstKilled` and `ctx.Err()` whenever the fallback is reached, run over the whole module in a
4 vCPU guest with `dmesg` captured afterwards — the OOM hypothesis is one command to confirm or
kill. Until that runs, the honest statement is: two adjacent defects reproduced, one of them
fixed; the original occurrence still unexplained.

**What is in `flake-fix/`.** `patch.diff` (applies cleanly; fixes A only),
`zz_killed_src_test.go` (the invariant test for A — deterministic, fails before and passes after),
`zz_cancel_test.go` (the red for B, **not** fixed by the patch), `zz_exited_test.go` (both sides
exiting 0 still reports the message — what refuted the zombie reasoning), the fixed and mutated
sources, `reproduce.sh` for the A phases, and the overlay JSONs for the rest. Nothing is applied
to the tree.

Whoever lands `patch.diff` should decide B separately: reporting `ctx.Err()` when the context is
done would name the real cause, which also improves the production paths that cancel a running
dump. `TestRunPipeline_FilterStripsLines` itself may need nothing at all — if the guest's kill came
from the OOM killer, the test is innocent and its one failure was a symptom of the environment.
