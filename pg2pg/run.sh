#!/bin/bash
# PeerDB PG -> PG, minimum footprint, one shot.
#
# Takes a bare firecode guest (Ubuntu 24.04 arm64) to a running CDC mirror and
# then proves it. Stages are separate so a failure names itself:
#
#   00-setup-postgres.sh  one PG 18 cluster serving catalog + source + dest
#   01-toolchain.sh       Go 1.27.1 + libgeos, builds the flow binary from this checkout
#   02-run-peerdb.sh      Temporal (CLI dev server) + migrate + api + worker + snapshot-worker
#   03-mirror.sh          peers, a 20k-row seeded table, the CDC mirror, the initial snapshot
#   04-verify.sh          insert/update/delete on the source, then count+checksum convergence
#   05-cdc-cases.sh       the cases 04 does NOT actually exercise - asserts the count MOVES,
#                         because 04's inserts and deletes were no-ops and it still "passed"
#   06-throughput.sh      one 200k-row burst, end-to-end, scoped as narrowly as it is
#
# Two things this host taught us, both of which fail confusingly if ignored:
#
#   * THE GUEST IMAGE SHIPS THE POSTGRESQL 18 PACKAGES WITH NO CLUSTER, and
#     `apt-get install postgresql` is unusable: it pulls postgresql-16, which
#     depends on libllvm19, which no configured repo has. So 00 creates the
#     cluster with pg_createcluster instead of installing anything.
#   * THE GO BUILD NEEDS MORE THAN 4 GB OF GUEST. With the default -p(=NumCPU)
#     the compiler peaked at 2.5 GB RSS and the guest kernel OOM-killed it, and
#     `go build` then exits 1 having printed NO compiler error at all - the only
#     trace is in dmesg. Either boot with more memory:
#
#         firecode up --project <copy> --mem 8192
#
#     or serialize the compiler, which is what 01 does by default:
#         GOFLAGS=-p=1 GOMAXPROCS=2 GOGC=30
#
# RESULTS.md in this directory has the measured evidence, the exact error message for each
# trap, and - importantly - what the numbers do and do not support.
#
set -euxo pipefail
D=$(cd "$(dirname "$0")" && pwd)

bash "$D/00-setup-postgres.sh"
bash "$D/01-toolchain.sh"
bash "$D/02-run-peerdb.sh"
bash "$D/03-mirror.sh"
bash "$D/04-verify.sh"
bash "$D/05-cdc-cases.sh"
bash "$D/06-throughput.sh"

echo "run.sh: PG->PG mirror created and CDC verified"
