#!/bin/bash
# 02 - Temporal (CLI dev server) + migrate + api + worker + snapshot-worker.
#
# Two failure modes this stage has to survive, both measured on a 4GB/8GB guest:
#
#   * `temporal server start-dev --db-filename X` leaves X locked if a previous
#     server is still alive or died holding it. The next server then exits with
#     "unable to create SQLite admin DB: database is locked (5) (SQLITE_BUSY)" -
#     and because it binds the port BEFORE that failure, a naive "is the port open"
#     wait passes and the script carries on to daemons that retry forever against
#     a server that is already gone. So: no --db-filename (ephemeral store, nothing
#     to lock) and the liveness checks below are on the PROCESS, not just the port.
#   * a readiness loop that only breaks on success and never fails turns "the API
#     never came up" into a printed "OK". The loop at the bottom exits 1 instead.
set -euxo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)   # see 01-toolchain.sh: derived, not hardcoded
RES="$REPO/pg2pg/results"
mkdir -p "$RES"

# --- Temporal -----------------------------------------------------------------
if [ ! -x "$HOME/.temporalio/bin/temporal" ]; then
  curl -sSf https://temporal.download/cli.sh | bash
fi
export PATH="$HOME/.temporalio/bin:$PATH"
temporal --version | tee "$RES/temporal-version.txt"

# Clear anything left by an earlier attempt.
pkill -f "temporal server start-dev" || true
sleep 2
pkill -9 -f "temporal server start-dev" || true
pkill -f "peerflow api" || true
pkill -f "peerflow worker" || true
pkill -f "peerflow snapshot-worker" || true
rm -f "$HOME"/temporal-dev.db*
sleep 1

setsid nohup temporal server start-dev --headless --ip 127.0.0.1 --port 7233 \
  >"$RES/temporal.log" 2>&1 &
for i in $(seq 1 90); do
  (exec 3<>/dev/tcp/127.0.0.1/7233) 2>/dev/null && { echo "port 7233 open after ${i}s"; break; }
  sleep 1
done
# Confirm it is still there a moment later - the port opening is not the same fact
# as the server surviving its own namespace bootstrap.
sleep 4
if ! pgrep -af "temporal server start-dev"; then
  echo "TEMPORAL IS NOT RUNNING. Its log says:"
  tail -20 "$RES/temporal.log"
  exit 1
fi
(exec 3<>/dev/tcp/127.0.0.1/7233) 2>/dev/null || {
  echo "TEMPORAL PROCESS ALIVE BUT NOT LISTENING. Log:"; tail -20 "$RES/temporal.log"; exit 1
}
echo "--- temporal up; its log so far ---"; tail -5 "$RES/temporal.log"

# The flow stamps every mirror workflow with a MirrorName search attribute, and Temporal
# refuses to START a workflow naming an attribute the namespace has no mapping for:
#   {"code":13,"message":"unable to start PeerFlow workflow: Namespace default has no
#    mapping defined for search attribute MirrorName"}
# The compose stack gets this from temporal-admin-tools running scripts/mirror-name-search.sh,
# which is exactly this call - so a bare dev server must do it too or every mirror create fails
# with a message that sounds like a flow bug.
temporal operator search-attribute list || true
if ! temporal operator search-attribute list 2>/dev/null | grep -w MirrorName >/dev/null 2>&1; then
  temporal operator search-attribute create --name MirrorName --type Text --namespace default
fi
temporal operator search-attribute list

# --- env shared by all four processes ----------------------------------------
export PEERDB_CATALOG_HOST=127.0.0.1
export PEERDB_CATALOG_PORT=5432
export PEERDB_CATALOG_USER=postgres
export PEERDB_CATALOG_PASSWORD=postgres
export PEERDB_CATALOG_DATABASE=peerdb_catalog
export TEMPORAL_HOST_PORT=127.0.0.1:7233
export PEERDB_TEMPORAL_NAMESPACE=default

# --- migrations (exits) -------------------------------------------------------
peerflow migrate 2>&1 | tee "$RES/migrate.log" | tail -10

# --- the three daemons --------------------------------------------------------
for proc in api worker snapshot-worker; do
  pkill -f "peerflow $proc" || true
done
sleep 1
setsid nohup peerflow worker >"$RES/worker.log" 2>&1 &
setsid nohup peerflow snapshot-worker >"$RES/snapshot-worker.log" 2>&1 &

# PORTS ARE PINNED, not discovered. The binary's own defaults are --port 8110 and
# --gateway-port 8111 (flow/main.go:148-156) and there is no env var for either; the
# published compose images are reached on 8112/8113 instead. Getting this wrong cost a
# whole run in which the API was up and healthy on 8110/8111 while the readiness probe
# knocked on 8113 - which reads as "the API never came up" rather than as a wrong guess.
setsid nohup peerflow api --port 8112 --gateway-port 8113 \
  --temporal-host-port "$TEMPORAL_HOST_PORT" \
  --temporal-namespace "$PEERDB_TEMPORAL_NAMESPACE" >"$RES/api.log" 2>&1 &
sleep 5

# --- readiness, and this time it fails ---------------------------------------
api_ok=no
for i in $(seq 1 60); do
  if curl -sf --max-time 5 http://127.0.0.1:8113/v1/peers/list >"$RES/peers-list.json"; then
    api_ok=yes; echo "flow-api answered after ${i}s"; cat "$RES/peers-list.json"; break
  fi
  sleep 1
done
if [ "$api_ok" != yes ]; then
  echo "FLOW-API NEVER ANSWERED. api.log says:"
  tail -20 "$RES/api.log"
  exit 1
fi

echo "--- one line from each log, plus any error ---"
for f in api worker snapshot-worker; do
  echo "== $f.log"; tail -3 "$RES/$f.log"
  grep -iE "error|fatal|panic" "$RES/$f.log" | tail -2 || true
done
echo "--- processes ---"; ps aux | grep -E "[p]eerflow|[t]emporal server" | awk '{print $2, $11, $12}'
echo "02-run-peerdb.sh OK"
