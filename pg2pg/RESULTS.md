# Postgres -> Postgres with PeerDB, in one firecode VM

What this is: the smallest working PG->PG CDC mirror, built from *this* checkout inside a
throwaway microVM, with the evidence for each step and the traps that cost time. It was run
to answer a narrow question — whether PeerDB's "parallel initial load / 10x faster CDC / 10k+
tps" claims can be checked from the source at all — so the second half of this file is about
what the numbers below do and do not support.

Everything here was run inside the VM, on the sources in the tree. No host state was touched.

## Environment (measured, not assumed)

| | |
|---|---|
| Guest | Ubuntu 24.04 (noble) arm64, kernel 7.0.0-38-generic, 4 vCPU, 7916 MB RAM, 16 GB disk |
| PostgreSQL | 18.6 (`18.6-1.pgdg24.04+2`), ONE instance, three databases: `peerdb_catalog`, `pgsrc`, `pgdst` |
| Temporal | CLI 1.9.1 (Server 1.32.0), **in-memory persistence**, namespace `default` |
| Go | go1.27.1 linux/arm64 (tarball from go.dev; the image has no usable Go) |
| geos | libgeos-dev 3.14.1 (cgo dep of `go-geos`, needed to link `flow`) |
| Binary | `peerflow` built from this checkout's `flow/` — protos were already generated in-tree, so no `buf` |

Four processes: `migrate` (once), `api` (gRPC 8112 + HTTP gateway 8113), `worker`
(`peer-flow-task-queue`), `snapshot-worker` (`snapshot-flow-task-queue`).

## The recipe

    firecode up --project <copy of the tree> --mem 8192
    firecode in --project <copy> --cwd <copy> 'bash pg2pg/run.sh'

Stages, each runnable alone: `00-setup-postgres.sh`, `01-toolchain.sh`, `02-run-peerdb.sh`,
`03-mirror.sh`, `04-verify.sh`, `05-cdc-cases.sh`, `06-throughput.sh`.

**About the raw files.** The stages write their own logs and API responses to
`pg2pg/results/` *inside the guest*. In the first run that directory did not come back out:
driving the CLI directly (`firecode up` + `firecode in`) had **no copy-out step** — the
copy-back it appeared to offer belongs to `firecode down`, which only reboots the guest, and
the unmount-and-copy is done by the `launch` wrapper, which a direct `up` never runs. So the
first run's raw evidence is its captured stage output, kept beside this file in `logs/`.
**That limitation is gone.** The harness copies the VM's tree out when the session ends, so
`pg2pg/results/` now comes back with the run: the second run below is reported from those
files directly (`worker.log`, `migrate.log`, `snapshot-worker.log`, `connection-configs.json`,
`mirror-create.json`, `peer-*.json`, `temporal-version.txt`). `results/` is still recreated by
the stages on any re-run, inside whatever copy the VM was booted on.

## What was proved

**Initial snapshot, 20,000 rows: landed in 2 s.** The load is parallel and partitioned by
CTID — from `results/worker.log`:

    [pg_query_executor] executing copy
    query: COPY (SELECT * FROM "public"."t" WHERE "ctid" BETWEEN '(0,0)' AND '(40,65535)') TO STDOUT
    ... three more, over '(41,0)'-'(82,65535)', '(83,0)'-'(124,65535)', '(125,0)'-'(166,65535)'

That is the PG->PG path: `COPY ... TO STDOUT` streamed through a pipe into
`COPY ... FROM STDIN` on the destination (`flow/connectors/postgres/sink_pg.go:95-140`,
`flow/activities/flowable.go:805-812`), four partitions in parallel, rather than row-by-row.

**CDC, all three cases: converged in 15 s.** 6,000 inserted rows, 800 updates, 200 deletes
from the seeded range:

    SOURCE     : 25800|1416003000|da14b721dc4b42f18c926d822e586117
    DESTINATION: 25800|1416003000|da14b721dc4b42f18c926d822e586117

The source count *moved* (20,000 -> 25,800), which is what makes this a test of INSERT and
DELETE rather than of nothing.

**Throughput, one 200,000-row burst: 2.1 s from commit, ~92,000 rows/s end-to-end.**

    statement wall time: 311 ms
    CONVERGED: 200000 rows applied in 2.1s after commit
    MEASURED THROUGHPUT: 92123 rows/sec end-to-end

**Slot and staging**, from the source and destination at the end:

    slot_name           | plugin   | slot_type | active | restart_lsn | confirmed_flush_lsn
    peerflow_slot_pg2pg | pgoutput | logical   | t      | 0/B19A690   | 0/11ADBFB0

    _peerdb_internal._peerdb_raw_pg2pg
    _peerdb_internal._peerdb_query_replication_metadata

## What these numbers do NOT support

- **They do not verify "10x faster CDC".** That is a comparison and no baseline was run —
  not against an older PeerDB, not against a naive SELECT/INSERT loop. Nothing in this tree
  supplies one; the only benchmark in the repo (`qrep_bench_test.go`) is `//go:build tilt` and
  exercises the *row-based* path, not this COPY path.
- **They do not verify "10k+ tps at scale".** This is one 200,000-row burst into a 2-column
  table, with source, catalog and destination in a single PostgreSQL instance on one 4-vCPU
  VM, and no concurrent write load. Everything being local makes this a favourable case for
  this machine; it is neither a sustained rate nor a scale claim.
- **The 2 s snapshot is 20,000 rows.** It says the parallel CTID path works and is fast per
  partition; it says nothing about hundreds of GB.
- **Nothing here is about the deprecated connectors** (Snowflake, BigQuery, Kafka, S3, ...) or
  about ClickHouse — PG->PG only, deliberately.

## Traps, each with the message it produced

1. **The guest image carries PostgreSQL 18 packages and no cluster** (`pg_lsclusters` empty,
   `/var/lib/postgresql` empty) — the right default for an image that should not presume a
   database. So `00` creates the cluster with `pg_createcluster 18 main --start` and asserts
   nothing else about the image. Worth knowing, because it reads as a broken box rather than a
   version pin: `apt-get install postgresql` is *not* a way around that here, since it resolves to
   `postgresql-16`, whose dependency cannot be met from the repos the image has configured —
   `postgresql-16 : Depends: libllvm19 but it is not installable`. That is repo metadata in the
   image, not a PeerDB or firecode problem, and the recipe needs to install nothing.
2. **`pg_hba.conf` is first-match-wins, so an appended trust rule is dead.** The stock cluster
   ships `host all all 127.0.0.1/32 scram-sha-256`, and `migrate` then failed with
   `failed SASL auth: FATAL: password authentication failed for user "postgres" (SQLSTATE 28P01)`.
   `00` *prepends* the trust block, and asserts the real TCP connection afterwards.
3. **The Go build does not fit in a 4 GB guest.** With the default `-p`, the compiler peaked at
   2.5 GB RSS and the guest kernel killed it: `Out of memory: Killed process 11439 (compile)`.
   `go build` then exits 1 **with no compiler error and an empty log** — the only trace is
   `dmesg`. Boot with `--mem 8192`, or set `GOFLAGS=-p=1 GOMAXPROCS=2 GOGC=30` (`01` does the
   latter, so it works either way).
4. **`/usr/local/bin` is root-owned**; building straight to it fails *after* a successful
   compile with `open /usr/local/bin/peerflow: permission denied`. `01` builds to `/tmp` and
   `sudo install`s.
5. **`temporal server start-dev --db-filename X` leaves a lock.** A later server dies with
   `failed starting server: failed creating namespaces: unable to create SQLite admin DB:
   database is locked (5) (SQLITE_BUSY)` — and it binds the port *before* dying, so a
   port-only readiness check passes and you get daemons retrying a server that is gone.
   `02` uses an **ephemeral** store and checks the process, not just the port.
6. **The API's ports are not the compose ones.** Defaults are `--port 8110` and
   `--gateway-port 8111` (`flow/main.go:148-156`, no env var); the published images sit on
   8112/8113. Everything looked healthy and my probe waited on 8113. `02` pins both.
7. **A mirror cannot start without the `MirrorName` search attribute:**
   `unable to start PeerFlow workflow: Namespace default has no mapping defined for search
   attribute MirrorName`. The compose stack gets this from `temporal-admin-tools` running
   `scripts/mirror-name-search.sh`; a bare dev server needs the same call:
   `temporal operator search-attribute create --name MirrorName --type Text --namespace default`.
   (The SQLite dev server accepts it — verified, `MirrorName Text` appears in the listing — so
   docker and `auto-setup` are not required for this path.)
8. **`publicationName`/`replicationSlotName` mean "use this one, it already exists".** Setting
   them to names that do not exist fails validation:
   `provided source tables invalidated: publication does not exist: pub_pg2pg`. Leave them empty
   and `SetupReplication` creates both.
9. **The catalog row is written before the workflow starts**, so an attempt that died at
   workflow start leaves `flow already exists: pg2pg` behind. `03` re-posts with
   `attachToExisting: true` (`flow/cmd/handler.go:181-207`).
10. **`bc` is not in the guest image** — the first timing attempt died with `bc: command not
    found` *after* its 200,000 rows had already committed.
11. **A checksum that matches can be a checksum over rows that never changed.** The first CDC
    stage printed `RESULT: CDC confirmed` while its insert phase collided with existing ids and
    its delete predicate matched nothing — it proved UPDATE propagation only. `05-cdc-cases.sh`
    asserts the row count moves; that is what makes it a test of INSERT and DELETE.

## The harness path that did not work (not a PeerDB issue)

`task(where: "firecode")` cannot start a child on this host, twice, by name:

- `placing this session in a firecode VM: io: running firecode: No such file or directory
  (os error 2)` — the backend resolves `$FIRECODE_BIN`, else `firecode` on `PATH`
  (`letibot/crates/tools/src/firecode.rs:67-71`), and it was not on the PATH the daemon had.
- after symlinking the launcher into `/opt/homebrew/bin`:
  `io: firecode layer inherit refused (exit status: 1): [firecode] error: usage: firecode layer
  [add <image>|ls|rm <image>] [--project DIR]` — the backend calls `firecode layer inherit`
  (`firecode.rs:248-263`), which this firecode build does not implement.

So this run drove the CLI directly instead: `firecode up --project <copy>`, `firecode in ...`
for each stage, and `firecode down` to bring the work back. Same isolation, none of the backend.

Two smaller sharp edges found on the way: `firecode cp` reports success while **not**
overwriting an existing file (the file is written *into* a directory of that name instead —
every push here is verified by md5, and most were written through the exec channel instead),
and `firecode up --help` boots a VM rather than printing usage.

## Second run — 2026-10-08, the 4 GB case

Same recipe, unmodified: `bash pg2pg/run.sh` from the tree root, on a guest with **3898 MB RAM
and 4 vCPU** (`free -m`, `nproc`) — half the memory of the first run, which was booted with
`--mem 8192`. The whole run finished and printed its terminal line:

    run.sh: PG->PG mirror created and CDC verified

| | first run (8 GB) | second run (4 GB) | verdict |
|---|---|---|---|
| initial snapshot, 20,000 rows | `INITIAL SNAPSHOT LANDED after 2s` | `INITIAL SNAPSHOT LANDED after 2s` | matched |
| CDC insert+update+delete convergence | `CONVERGED after 15s` | `CONVERGED after 15s` | matched |
| 200,000-row burst | `CONVERGED: 200000 rows applied in 2.1s after commit` | `CONVERGED: 200000 rows applied in 2.1s after commit` | matched |
| burst throughput | `92123 rows/sec` | `92506 rows/sec` | beat by 383 rows/s (~0.4%) |

Quoted from `run.log`:

    INITIAL SNAPSHOT LANDED after 2s
    CONVERGED after 15s
    CONVERGED: 200000 rows applied in 2.1s after commit
    MEASURED THROUGHPUT: 92506 rows/sec end-to-end

Supporting numbers, all measured in this run:

- **The 4 GB guest did not OOM.** `01-toolchain.sh` built with its serialized compiler
  (`GOFLAGS=-p=1 GOMAXPROCS=2 GOGC=30`): `real 5m9.310s`, and `sudo dmesg | grep -ci 'killed
  process'` was **0** — the same zero it read before the run started. Peak compiler RSS observed
  during the build was ~0.8 GB, so trap 3 stayed a trap and never fired.
- **The snapshot was still the parallel CTID path**, four partitions as
  `connection-configs.json` configures (`snapshotNumRowsPerPartition: 5000`,
  `snapshotMaxParallelWorkers: 4`); `results/worker.log` carries four `Executing and processing
  query stream` QRep activities.
- **The count moved**, which is what makes the CDC row above a test of INSERT and DELETE:
  `20000 -> 25800` (`SOURCE: 25800|1416003000|da14b721dc4b42f18c926d822e586117`, matching the
  destination), and the burst took the pair to `225800|221416103000|b9c08b64438045f7859002ce6a986c41`.
- Burst `statement wall time: 247 ms` (first run: 311 ms).
- Replication slot at the end: `peerflow_slot_pg2pg | pgoutput | logical | t`.

Not measured in this run, and so not claimed: the CDC-convergence time of stage `04` is a
*separate* number from the `05` row above and read `CONVERGED after 21s (CDC stream, not the
initial snapshot)`. No baseline was run, so the standing caveats under **What these numbers do
NOT support** apply to this run unchanged.

One printed line does not describe this guest: `06-throughput.sh` ends by echoing a hardcoded
scope of `one firecode VM (4 vCPU, 7.9GB)`. This VM had **4 vCPU but 3898 MB**, and the stage
was not edited (per the run's instructions), so that line is inherited text from the first run
rather than a measurement of this one.

The raw files for this run are in `results/`, and — see **About the raw files** above — they
came back out of the guest with it.
