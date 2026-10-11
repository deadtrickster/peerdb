#!/bin/bash
# 03 - peers, a seeded source table, the CDC mirror, and the initial snapshot.
#
# Two things learned the hard way, both of which look like something else:
#
#   * publicationName / replicationSlotName MEAN "use this one, it already exists".
#     Setting them to names that do not exist fails validation with
#     "provided source tables invalidated: publication does not exist: <name>".
#     Left empty, SetupReplication creates both (flow/connectors/postgres/client.go:563).
#   * the catalog row for a mirror is written BEFORE its workflow starts, so any attempt
#     that died at workflow start (here: the namespace had no MirrorName search attribute)
#     leaves "flow already exists" behind on the next attempt. attachToExisting skips that
#     check and then attaches-or-starts (flow/cmd/handler.go:181-207).
set -euxo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)   # see 01-toolchain.sh: derived, not hardcoded
RES="$REPO/pg2pg/results"; mkdir -p "$RES"
API=http://127.0.0.1:8113

peer() { # name, database
  curl -sS -X POST "$API/v1/peers/create" -H 'Content-Type: application/json' -d @- <<JSON | tee "$RES/peer-$1.json"; echo
{"peer":{"name":"$1","type":"POSTGRES","postgresConfig":{"host":"127.0.0.1","port":5432,"user":"postgres","password":"postgres","database":"$2"}},"allowUpdate":true}
JSON
}
peer pgsrc pgsrc
peer pgdst pgdst

# Source table + seed, so the INITIAL SNAPSHOT has real work to do.
sudo -u postgres psql -d pgsrc -c "drop table if exists public.t"
sudo -u postgres psql -d pgsrc -c "create table public.t (id int primary key, v text)"
sudo -u postgres psql -d pgsrc -c "insert into public.t (id,v) select g, md5(g::text) from generate_series(1,20000) g"
sudo -u postgres psql -d pgsrc -tAc "select count(*) from public.t"

# Field names from ui/grpc_generated/flow.ts; system "PG" is TypeSystem.PG = 1.
cat > "$RES/connection-configs.json" <<'JSON'
{
  "flowJobName":"pg2pg",
  "sourceName":"pgsrc",
  "destinationName":"pgdst",
  "tableMappings":[{"sourceTableIdentifier":"public.t","destinationTableIdentifier":"public.t"}],
  "system":"PG",
  "doInitialSnapshot":true,
  "snapshotNumRowsPerPartition":5000,
  "snapshotMaxParallelWorkers":4,
  "snapshotNumTablesInParallel":1,
  "maxBatchSize":10000,
  "idleTimeoutSeconds":15,
  "cdcStagingPath":"",
  "snapshotStagingPath":"",
  "softDeleteColName":"",
  "syncedAtColName":"",
  "initialSnapshotOnly":false,
  "resync":false,
  "env":{},
  "version":0,
  "flags":[]
}
JSON

post_create() { # attachToExisting
  jq -n --argjson cc "$(cat "$RES/connection-configs.json")" --argjson attach "$1" \
    '{connectionConfigs:$cc, attachToExisting:$attach}' \
  | curl -sS -X POST "$API/v1/flows/cdc/create" -H 'Content-Type: application/json' -d @- \
  | tee "$RES/mirror-create.json"
  echo
}

echo "--- creating mirror (initial snapshot ON) ---"
post_create false
if grep -q 'flow already exists' "$RES/mirror-create.json"; then
  echo "--- flow already exists in the catalog; re-posting with attachToExisting=true ---"
  post_create true
fi
if grep -q '"code"' "$RES/mirror-create.json"; then
  echo "MIRROR CREATE FAILED - response above"
  exit 1
fi

echo "--- mirror status ---"
curl -sS "$API/v1/mirrors/status" | tee "$RES/status.json" | jq -c '.cdcStatuses[]? | {flowJobName,status,message}' 2>/dev/null || true

echo "--- waiting for the initial snapshot: destination must reach 20000 rows ---"
ok=no
for i in $(seq 1 120); do
  n=$(sudo -u postgres psql -d pgdst -tAc "select count(*) from public.t" 2>/dev/null || echo none)
  [ $((i % 10)) -eq 0 ] && echo "t+${i}s destination rows=$n source rows=20000"
  if [ "$n" = "20000" ]; then ok=yes; echo "INITIAL SNAPSHOT LANDED after ${i}s"; break; fi
  sleep 1
done
if [ "$ok" != yes ]; then
  echo "INITIAL SNAPSHOT DID NOT LAND IN 120s"
  echo "--- snapshot-worker tail ---"; tail -25 "$RES/snapshot-worker.log" || true
  echo "--- worker tail ---"; tail -25 "$RES/worker.log" || true
fi

echo "--- replication slot as Postgres sees it ---"
sudo -u postgres psql -d pgsrc -c "select slot_name, plugin, slot_type, active, restart_lsn from pg_replication_slots"
echo "--- raw staging table on the destination, if the COPY path was used ---"
sudo -u postgres psql -d pgdst -tAc "select table_schema||'.'||table_name from information_schema.tables where table_name like '_peerdb%' order by 1"
echo "03-mirror.sh done (snapshot=$ok)"
[ "$ok" = yes ] || exit 1
