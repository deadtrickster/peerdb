#!/bin/bash
# 00 - one Postgres serving catalog + source + destination.
# The guest image ships the PostgreSQL 18 packages but NO cluster, so this creates one.
# Settings PeerDB's preflight enforces: flow/connectors/postgres/validate.go:130-229
set -euxo pipefail

# Packages are already here; only fetch them if the binaries are absent.
if ! ls /usr/lib/postgresql >/dev/null 2>&1; then
  sudo apt-get install -y postgresql-18
fi
sudo apt-get install -y curl jq ca-certificates

PGVER=$(ls /usr/lib/postgresql | sort -V | tail -1)
echo "PGVER=$PGVER"

# No cluster on a fresh image: make one. (postgresql-common's own tool, so the
# config lands in /etc/postgresql/<ver>/main and pg_ctlcluster owns it.)
if ! sudo pg_lsclusters -h | grep -q .; then
  sudo pg_createcluster "$PGVER" main --start
fi
sudo pg_lsclusters

CONF="/etc/postgresql/${PGVER}/main"

# wal_level / senders / slots.
if ! sudo grep -q '^wal_level = logical' "$CONF/postgresql.conf"; then
  sudo tee -a "$CONF/postgresql.conf" >/dev/null <<'EOF'

# --- peerdb pg2pg run ---
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
listen_addresses = '*'
EOF
fi

# Local trust plus replication, so the four processes need no password dance.
#
# PREPENDED, not appended. pg_hba.conf is first-match-wins, and the stock cluster
# ships `host all all 127.0.0.1/32 scram-sha-256` - so an appended trust line is
# never reached and the flow's TCP connection fails with
# `failed SASL auth: password authentication failed for user "postgres"`.
if ! sudo grep -q '^# --- peerdb trust block ---' "$CONF/pg_hba.conf"; then
  sudo cp -n "$CONF/pg_hba.conf" "$CONF/pg_hba.conf.orig"
  { sudo tee "$CONF/pg_hba.conf" >/dev/null <<'EOF'
# --- peerdb trust block ---
local   all             all                                     trust
host    all             all             127.0.0.1/32            trust
host    replication     all             127.0.0.1/32            trust
host    all             all             0.0.0.0/0               trust
host    replication     all             0.0.0.0/0               trust
# --- end peerdb trust block ---
EOF
  } && sudo cat "$CONF/pg_hba.conf.orig" | sudo tee -a "$CONF/pg_hba.conf" >/dev/null
fi

# And the password the peers are configured with, in case a scram rule is reached first.
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'postgres'" >/dev/null

sudo pg_ctlcluster "$PGVER" main restart
sleep 3

echo "--- what the server says about itself ---"
sudo -u postgres psql -tAc "select version()"
sudo -u postgres psql -tAc "select name||' = '||setting from pg_settings where name in ('wal_level','max_wal_senders','max_replication_slots')"

# Three databases in one instance: catalog, source, destination.
for db in peerdb_catalog pgsrc pgdst; do
  sudo -u postgres psql -tAc "select 1 from pg_database where datname='$db'" | grep -q 1 \
    || sudo -u postgres createdb "$db"
done
sudo -u postgres psql -tAc "select datname from pg_database where datname in ('peerdb_catalog','pgsrc','pgdst') order by 1"

# The connection the flow processes actually make: TCP, as postgres, to the catalog.
PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -d peerdb_catalog -tAc "select 'tcp auth ok'"

# And the one the replication slot needs.
PGPASSWORD=postgres psql -h 127.0.0.1 -U postgres -d peerdb_catalog -tAc "select rolreplication from pg_roles where rolname='postgres'"

echo "00-setup-postgres.sh OK"
