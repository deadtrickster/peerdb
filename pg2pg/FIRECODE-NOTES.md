# firecode + leticode placement: what cost time, and what to change

Written 2026-10-08 from one session that used firecode two ways: by driving the CLI directly
(`up` → `in` → `down`) and, after your `layer inherit` commit landed, through the letibot
placement (`task(where: "firecode")`). Everything below is something I hit and can quote; where
I state a cause I say whether it is measured or inferred.

Evidence for the run itself is alongside this file: `RESULTS.md` (the recipe, its traps, and the
measured numbers), `run.log` (a full second-run console log), `results/` (the raw per-process
logs and API responses), `logs/` (captured stage output from the first run).

## Fix these five first

They share a root cause — **`up` + `in` was built for remote exec, but copy-out was built for
`launch`-driven agent runs, and one set of verbs hides the difference** — and between them they
cost roughly a dozen turns.

### 1. `down` does not sync the work out, and the copy-out is asynchronous

**Symptom.** `firecode down --project P` prints `stopping the VM` / `stopped` and returns. No
copy appears. Reading `cmd_down` explains it: it reboots the guest and waits for the socket to
go quiet; the unmount-and-copy belongs to the `launch` wrapper, which a direct `up` never runs.
Where the copy *does* happen (placement runs), it lags: a child answered, checked for its result
directory, wrote "neither a result directory … nor firecode's record appeared within 10 s" — and
the directory appeared about two minutes later. I had a complete run's artifacts in hand and was
one step from declaring them lost.

**Fix.** Make the verb honest and the fact observable: either `down` always syncs and prints the
destination, or add `sync-out <project>` and make `up` say which lifecycle it is in
(`ephemeral: no copy-out` vs `syncing`). Record `copy_out: pending|done <path>` on the run, and
have anything reporting a finished run wait for that field rather than sampling once.

### 2. `cp` reports success while not overwriting

**Symptom.** `firecode cp host/file vm:/path/file` prints `10K from … into …` and exits 0, while
the guest keeps the old contents. With an existing destination it creates a *directory* of that
name and writes the file inside it — I only noticed because an `md5sum` disagreed, and saw
`03-mirror.sh` listed as a `drwxr-xr-x` directory containing `03-mirror.sh`. Three runs executed
a stale script because of this; the recipe now writes over the exec channel instead and verifies
every push by md5.

**Fix.** `stat` the destination: replace an existing regular file atomically (temp + `rename`),
refuse loudly on a type mismatch, and never `mkdir` at a path that exists as a file. The
letibot backend's own write path already does temp + `mv -f`; firecode's `put` should match it.

### 3. A shared log decides a per-run verdict

**Symptom.** `up` reported `the VM failed to start:` with
`grep: /Users/dead/Projects/firecode/firecode/runs/up.log: binary file matches`, then
`error: no VM running for … (running: …/ws)` — while another run was booting. That VM had in fact
started: a fresh entry (`peerdb-3`) was listed immediately afterwards. Two bugs in one: a global,
append-by-everyone file is read to decide a fact about *my* run, and a `grep` whose exit status
conflates "binary input" with "no match" is treated as the verdict.

**Fix.** Per-run log. Decide readiness by probing that run's own console/vsock, not by grepping a
shared file. If a shared file must be read, `grep -a`.

### 4. Preconditions are checked at spawn, not at start-up

**Symptom.** Two refusals, one per spawn attempt:

    placing this session in a firecode VM: io: running firecode: No such file or directory (os error 2)
    io: firecode layer inherit refused (exit status: 1):
      [firecode] error: usage: firecode layer [add <image>|ls|rm <image>] [--project DIR]

The first because `firecode_bin()` resolves `$FIRECODE_BIN` else `firecode` on `PATH`
(`crates/tools/src/firecode.rs:67-71`) and the daemon's `PATH` had neither. The second because
`FirecodeBackend::up` calls `layer inherit` (`firecode.rs:248-263`) — a *convenience*
(toolchain layers) whose absence made the placement unusable.

**Fix.** Resolve the binary and probe capabilities at daemon start, and publish them in the
banner the way the scratch directory already is. Then degrade where only a convenience is
missing ("no layer inheritance; the guest builds on base-image toolchains") and refuse only what
is genuinely required. Declare a minimum firecode version and check it at start-up.

### 5. `list` and `ps` disagree with reality

**Symptom.** `firecode list` kept listing a VM I had already stopped; `firecode ps` reported a
*live* VM as `(not answering - busy, or shutting down)` while `firecode in` on it worked. So I
aimed `down` at the wrong run — it printed `stopped`, and copied nothing while the live run still
held 7.5 GB of drives. `cmd_cp`'s own comment knows the rule ("The file outlives the VM. Only
something listening counts"); `list` does not apply it.

**Fix.** Apply the reachability test in `list`, and distinguish `gone` / `unresponsive` / `busy`
rather than `thinking, or stuck`. That phrase was doing a lot of interpretive work for me.

## Then, in the same spirit

- **`--project` is ambiguous when two runs share a path.** `cp` refuses by name
  (`2 VMs are running - stop all but one`); `down` silently picks one. Make all three (`in`,
  `cp`, `down`) require a run id, or name the run they chose in their output.
- **A failed spawn leaks its copy.** The very first attempt left 286 MB in
  `~/.cache/letibot/firecode/`; the error path `remove_dir_all`s on a *refused* status but not on
  a spawn error. There are four such directories there now, with no GC.
- **A child that exits with work still running in the guest loses it silently.** One child
  backgrounded a ten-minute run, answered "it is running", and the VM took the run down with it.
  The harness knows about jobs per session; the teardown could ask the guest for its process tree
  and put "N processes were still running when the VM stopped" in the child's answer.
- **The seam line for a firecode spawn is wrong.** It says *"the VM received a COPY of the tree;
  the work comes back as the branch, not as the directory."* There is no branch on this path — the
  work comes back as a sibling directory (or, per item 1, not at all unless you drive it right).
  A confidently wrong line in a tool's own output is worse than no line.
- **`up --help` boots a VM.** It ran past a 60-second deadline with no usage printed (the
  `spawn-server` branch in the same script handles `--help` properly, so this is an
  inconsistency, not a policy).

## What is right and should not change

- **The boundary, and its honesty about itself.** No virtio-fs, so the host is *unreachable*
  rather than merely not copied; the refuse lists (private keys, GPG keyrings, cloud and
  container credentials, the GitHub CLI's config dir, password stores, netrc, package-manager
  and gcloud/azure credentials, browser profiles) are applied at any depth, so a parent directory
  cannot smuggle them in; and the README states plainly that it does not protect your API credits
  or your network, with `--auth-relay` as the way out. Measured inside the guest:
  `firecode-claude on /Users/dead/.claude type overlay` — the agent's own credentials are the
  honest remainder, and they are named as such.
- **Fail closed on placement.** Two spawns failed *by name* rather than running on the host and
  calling it a VM. That is the right instinct, and it is why I found the real defects instead of
  quietly getting a host-side run. Item 4 is about *when* the refusal happens, not whether.
- **The `sudo -n true` guidance** in the guest context ("you are uid 1000, but sudo never
  prompts; anything deciding between 'ask for privileges' and 'already have them' should ask
  `sudo -n true`"). It is non-obvious, it is correct, and it saved me real time.
- **`layer inherit`** is the right shape of feature — a copy booting with its source's layers.
  It only needed the capability probe so its *absence* degrades instead of blocking.

## The guest image: nothing to fix

Scored here and withdrawn. An image that does not presume a database should ship no cluster, and
one that is minimal should not carry `bc`; the coping belongs in the recipe, and the guest
instruction ("do not work around a missing tool when you can just install it") is the right one.
The single residue is repo metadata: `apt-get install postgresql` resolves to `postgresql-16`,
whose dependency cannot be met from the configured repos
(`postgresql-16 : Depends: libllvm19 but it is not installable`), so a generic reach for
"postgres" returns an "impossible situation" that reads as a broken box rather than a version pin.
Worth a line in the image build; not a firecode defect.

## How this was gathered

Direct CLI: `firecode up --project <copy>`, `firecode in --project <copy> --cwd <copy> '<cmd>'`,
`firecode cp`, `firecode down`, plus `list`/`ps` — 60-odd commands against one 4 GB and one 8 GB
VM. Placement: three `task(where: "firecode")` spawns — the two refusals in item 4, one
interrupted by the operator, one that completed and whose artifacts were harvested from the
copy-out under `~/.cache/letibot/firecode/`. Every quoted message above is copied from that
session's output, not reconstructed.
