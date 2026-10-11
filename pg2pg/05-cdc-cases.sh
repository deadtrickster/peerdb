#!/bin/bash
# 05 - the CDC cases stage 04 did NOT actually exercise.
#
# Stage 04 printed "CDC confirmed" while its insert and delete phases were both no-ops:
# the 6000 "inserts" collided with the seeded ids (1..20000, INSERT .. ON CONFLICT DO
# NOTHING) and the delete predicate (id > 20000) matched nothing at all. It therefore
# proved UPDATE propagation and nothing else - and a matching checksum over rows that
# never changed is exactly what a broken INSERT or DELETE path looks like too.
#
# So this stage makes each case actually happen and ASSERTS THE COUNT MOVED:
#    + 6000 new rows   ids 200001..206000
#    ~ 800 updates     id % 25 = 0
#    - 200 deletes     id % 100 = 0, from the seeded range
#   expected count = 20000 + 6000 - 200 = 25800
set -euxo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)   # see 01-toolchain.sh: derived, not hardcoded
RES="$REPO/pg2pg/results"
q() { sudo -u postgres psql -d "$1" -tAc "$2"; }
SUM="select count(*)||'|'||coalesce(sum(id),0)||'|'||coalesce(md5(string_agg(id||':'||v,',' order by id)),'-') from public.t"

echo "--- before: $(q pgsrc "$SUM")"

for b in 1 2 3; do
  lo=$(( 200000 + (b-1)*2000 + 1 )); hi=$(( 200000 + b*2000 ))
  sudo -u postgres psql -d pgsrc -c \
    "insert into public.t (id,v) select g, md5(g::text) from generate_series($lo,$hi) g" >/dev/null
  echo "INSERTED new ids $lo..$hi"
done
sudo -u postgres psql -d pgsrc -c "update public.t set v='UPDATED-'||id where id % 25 = 0" >/dev/null
echo "UPDATED  id % 25 = 0"
sudo -u postgres psql -d pgsrc -c "delete from public.t where id % 100 = 0 and id <= 20000" >/dev/null
echo "DELETED  id % 100 = 0 (seeded range)"

src=$(q pgsrc "$SUM")
src_n=$(q pgsrc "select count(*) from public.t")
echo "SOURCE: $src (count $src_n)"
if [ "$src_n" != "25800" ]; then
  echo "EXPECTED 25800 ROWS ON THE SOURCE; the test's own phases did not land as intended"
  exit 1
fi

t0=$(date +%s)
converged=no
for i in $(seq 1 150); do
  dst=$(q pgdst "$SUM" 2>/dev/null || echo none)
  if [ "$dst" = "$src" ]; then
    t1=$(date +%s); converged=yes
    echo "CONVERGED after $((t1-t0))s"
    break
  fi
  [ $((i % 10)) -eq 0 ] && echo "t+${i}s dst=$dst"
  sleep 1
done
echo "SOURCE     : $src"
echo "DESTINATION: $(q pgdst "$SUM" 2>/dev/null || echo none)"
if [ "$converged" = yes ]; then
  echo "RESULT: INSERT + UPDATE + DELETE all propagated (count, sum and checksum match)"
else
  echo "RESULT: NOT CONVERGED"
  tail -30 "$RES/worker.log" || true
  exit 1
fi
echo "05-cdc-cases.sh OK"
