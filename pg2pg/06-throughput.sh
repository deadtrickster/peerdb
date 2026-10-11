#!/bin/bash
# 06 - an end-to-end throughput number, scoped as narrowly as it actually is.
#
# What this measures: wall-clock from COMMIT of a single 200,000-row INSERT on the source
# to the destination matching on count+sum+checksum. That is WAL -> pgoutput decode ->
# batch -> destination apply -> normalize, on ONE VM, with both databases in the SAME
# Postgres instance and no other load.
#
# What it does NOT measure: the project's "10x faster CDC" (no baseline is run here), its
# "10k+ tps" claim at scale (one small table, one VM, 4 vCPU), or steady-state throughput
# under a live write load. Any number below is a floor for this machine and nothing else.
#
# `bc` is not in the guest image, so all arithmetic here is bash integer math on
# `date +%s%N` nanoseconds. (The first version of this used bc and died with
# "bc: command not found" AFTER the 200000 rows had already committed.)
set -euxo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)   # see 01-toolchain.sh: derived, not hardcoded
RES="$REPO/pg2pg/results"
q() { sudo -u postgres psql -d "$1" -tAc "$2"; }
SUM="select count(*)||'|'||coalesce(sum(id),0)||'|'||coalesce(md5(string_agg(id||':'||v,',' order by id)),'-') from public.t"
LO=1000001
HI=1200000

# Re-runnable: clear the measurement range first, and let the CDC stream drain that
# deletion before timing anything, so the number below is about the insert alone.
sudo -u postgres psql -d pgsrc -c "delete from public.t where id between $LO and $HI" >/dev/null
echo "cleared any previous measurement range; waiting for the destination to drain it"
for i in $(seq 1 60); do
  a=$(q pgsrc "select count(*) from public.t"); b=$(q pgdst "select count(*) from public.t" 2>/dev/null || echo none)
  [ "$a" = "$b" ] && { echo "drained after ${i}s (both at $a rows)"; break; }
  sleep 1
done

before=$(q pgsrc "select count(*) from public.t")
echo "SOURCE ROWS BEFORE: $before   (adding 200000 ids $LO..$HI)"

t0=$(date +%s%N)
sudo -u postgres psql -d pgsrc -c \
  "insert into public.t (id,v) select g, md5(g::text) from generate_series($LO,$HI) g" >/dev/null
t_commit=$(date +%s%N)
echo "statement wall time: $(( (t_commit - t0) / 1000000 )) ms"

src=$(q pgsrc "$SUM")
src_n=$(q pgsrc "select count(*) from public.t")
expected=$(( before + 200000 ))
[ "$src_n" = "$expected" ] || { echo "source count $src_n != expected $expected"; exit 1; }

converged=no
for i in $(seq 1 300); do
  dst=$(q pgdst "$SUM" 2>/dev/null || echo none)
  if [ "$dst" = "$src" ]; then
    t_done=$(date +%s%N); converged=yes
    break
  fi
  [ $((i % 20)) -eq 0 ] && echo "t+${i}s dst_count=$(echo "$dst" | cut -d'|' -f1)"
  sleep 1
done

if [ "$converged" = yes ]; then
  ms=$(( (t_done - t_commit) / 1000000 ))
  echo "CONVERGED: 200000 rows applied in $(( ms / 1000 )).$(( (ms % 1000) / 100 ))s after commit"
  echo "MEASURED THROUGHPUT: $(( 200000 * 1000 / ms )) rows/sec end-to-end"
  # Measured, not asserted. This line used to hardcode "(4 vCPU, 7.9GB)" from the first run,
  # and printed that on a 4 GB guest in the second - a claim in the output that was simply
  # wrong about the machine it was describing.
  mem_mb=$(( $(grep MemTotal /proc/meminfo | tr -dc 0-9) / 1024 ))
  echo "    scope: one firecode VM ($(nproc) vCPU, ${mem_mb} MB RAM), catalog+source+destination in ONE"
  echo "    PostgreSQL 18 instance, no concurrent write load, NO BASELINE RUN. This is one"
  echo "    machine's number for this workload; it is not the project's 10x or 10k tps claim."
  echo "SOURCE     : $src"
  echo "DESTINATION: $(q pgdst "$SUM")"
else
  echo "DID NOT CONVERGE WITHIN 300s - no throughput number is reported for this run"
  tail -20 "$RES/worker.log" || true
  exit 1
fi

echo "--- replication slot at the end ---"
sudo -u postgres psql -d pgsrc -c "select slot_name, plugin, slot_type, active, restart_lsn, confirmed_flush_lsn from pg_replication_slots"
echo "--- mirror status ---"
curl -sS http://127.0.0.1:8113/v1/mirrors/status | jq -c '.cdcStatuses[]? | {flowJobName,status}' 2>/dev/null || true
echo "06-throughput.sh OK"
