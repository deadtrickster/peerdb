#!/bin/bash
# 04 - CHANGE DATA CAPTURE proof: insert/update/delete on the source, then wait for the
# destination to match on count AND content (a checksum that would catch a missed update
# or a survived delete). Also captures which write path was taken.
set -euxo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)   # see 01-toolchain.sh: derived, not hardcoded
RES="$REPO/pg2pg/results"

q() { sudo -u postgres psql -d "$1" -tAc "$2"; }
SUMQ="select count(*)||'|'||coalesce(sum(id),0)||'|'||coalesce(md5(string_agg(id||':'||v,',' order by id)),'-') from public.t"

echo "--- source before CDC phase: $(q pgsrc "$SUMQ")"

t0=$(date +%s)
for b in 1 2 3; do
  lo=$(( (b-1)*2000+1 )); hi=$(( b*2000 ))
  sudo -u postgres psql -d pgsrc -c \
    "insert into public.t (id,v) select g, md5(g::text) from generate_series($lo,$hi) g on conflict (id) do nothing" >/dev/null
  echo "inserted $lo..$hi"
  sleep 2
done
sudo -u postgres psql -d pgsrc -c "update public.t set v='UPDATED-'||id where id % 25 = 0" >/dev/null
sudo -u postgres psql -d pgsrc -c "delete from public.t where id % 100 = 0 and id > 20000" >/dev/null
echo "--- updates and deletes applied ---"

src=$(q pgsrc "$SUMQ")
echo "SOURCE: $src"
converged=no
for i in $(seq 1 150); do
  dst=$(q pgdst "$SUMQ" 2>/dev/null || echo none)
  if [ "$dst" = "$src" ]; then
    t1=$(date +%s); converged=yes
    echo "CONVERGED after $((t1-t0))s (CDC stream, not the initial snapshot)"
    break
  fi
  [ $((i % 10)) -eq 0 ] && echo "t+${i}s not yet: dst=$dst"
  sleep 1
done
dst=$(q pgdst "$SUMQ" 2>/dev/null || echo none)
echo "DESTINATION: $dst"
echo "SOURCE     : $src"
if [ "$converged" = yes ] && [ "$dst" = "$src" ]; then
  echo "RESULT: CDC confirmed - count, sum and content checksum match"
else
  echo "RESULT: NOT CONVERGED - destination does not match source"
  echo "--- last 40 lines of worker.log ---"; tail -40 "$RES/worker.log" || true
  exit 1
fi

echo "--- which write path: any evidence of COPY into the destination? ---"
grep -inE "via COPY|COPY|_peerdb_raw" "$RES/worker.log" | tail -10 || echo "(no COPY lines in worker.log)"
echo "--- batch accounting as the destination recorded it ---"
sudo -u postgres psql -d pgdst -tAc "select table_schema||'.'||table_name from information_schema.tables where table_name like '_peerdb%' order by 1"
echo "--- mirror lag / slot ---"
curl -sS "http://127.0.0.1:8113/v1/mirrors/status" | jq -c '.cdcStatuses[]? | {flowJobName,status}' 2>/dev/null || true
sudo -u postgres psql -d pgsrc -tAc "select slot_name,active,restart_lsn,confirmed_flush_lsn from pg_replication_slots"
echo "04-verify.sh OK"
