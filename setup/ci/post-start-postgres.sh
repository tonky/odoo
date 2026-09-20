#!/usr/bin/env bash
set -e

export PGUSER="${PGUSER:-odoo}"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5432}"

PG_USER="$PGUSER"
PG_HOST="$PGHOST"
PG_PORT="$PGPORT"

# 1. Wait for PostgreSQL server readiness
for i in $(seq 1 30); do
  if psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    break
  elif command -v enve >/dev/null 2>&1 && enve run -- psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "SELECT 1;" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

exec_sql() {
  local sql="$1"
  if command -v psql >/dev/null 2>&1; then
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "$sql" 2>/dev/null || true
  elif command -v enve >/dev/null 2>&1; then
    enve run -- psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d postgres -c "$sql" 2>/dev/null || true
  fi
}

query_sql() {
  local sql="$1"
  local db="${2:-postgres}"
  if command -v psql >/dev/null 2>&1; then
    psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" -t -A -c "$sql" 2>/dev/null || echo ""
  elif command -v enve >/dev/null 2>&1; then
    enve run -- psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d "$db" -t -A -c "$sql" 2>/dev/null || echo ""
  fi
}

# 2. Create roles and databases
exec_sql "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'postgres') THEN CREATE ROLE postgres SUPERUSER LOGIN; END IF; END \$\$;"

if [ -z "$(query_sql "SELECT 1 FROM pg_database WHERE datname = 'test_odoo';" postgres)" ]; then
  exec_sql "CREATE DATABASE test_odoo;"
fi

if [ -z "$(query_sql "SELECT 1 FROM pg_database WHERE datname = 'test_odoo_template';" postgres)" ]; then
  exec_sql "CREATE DATABASE test_odoo_template;"
fi

# 3. Fast restore base template if not yet populated
HAS_TABLES=$(query_sql "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' LIMIT 1;" test_odoo_template)
if [ "$HAS_TABLES" != "1" ]; then
  TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  SNAPSHOT_DIR="${ENACT_TEMPLATE_SNAPSHOT_DIR:-${HOME}/.cache/enact/snapshots}"
  SNAPSHOT="${SNAPSHOT_DIR}/odoo_base_template.dump"
  REPO_SNAPSHOT="${TOPLEVEL}/setup/ci/odoo_base_template.dump"

  RESTORE_SRC=""
  if [ -s "${REPO_SNAPSHOT}.zst" ]; then
    echo "⚡ Decompressing bundled template snapshot: ${REPO_SNAPSHOT}.zst"
    zstd -dc "${REPO_SNAPSHOT}.zst" > /tmp/odoo_base_template.dump 2>/dev/null || true
    RESTORE_SRC="/tmp/odoo_base_template.dump"
  elif [ -s "$REPO_SNAPSHOT" ]; then
    RESTORE_SRC="$REPO_SNAPSHOT"
  elif [ -s "$SNAPSHOT" ]; then
    RESTORE_SRC="$SNAPSHOT"
  elif [ -s "${SNAPSHOT}.zst" ]; then
    zstd -dc "${SNAPSHOT}.zst" > /tmp/odoo_base_template.dump 2>/dev/null || true
    RESTORE_SRC="/tmp/odoo_base_template.dump"
  fi

  if [ -s "$RESTORE_SRC" ]; then
    echo "⚡ Restoring test_odoo_template from snapshot ($RESTORE_SRC)..."
    if command -v pg_restore >/dev/null 2>&1; then
      pg_restore -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d test_odoo_template --no-owner --no-acl "$RESTORE_SRC" 2>/dev/null || true
    elif command -v enve >/dev/null 2>&1; then
      enve run -- pg_restore -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d test_odoo_template --no-owner --no-acl "$RESTORE_SRC" 2>/dev/null || true
    fi
  fi

  HAS_TABLES=$(query_sql "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' LIMIT 1;" test_odoo_template)
  if [ "$HAS_TABLES" = "1" ]; then
    echo "✓ Restored test_odoo_template in <1s from snapshot"
  else
    echo "⚡ Snapshot absent or incomplete; bootstrapping test_odoo_template with base module..."
    if command -v enve >/dev/null 2>&1; then
      enve run -- uv run --no-sync python "${TOPLEVEL}/odoo-bin" -d test_odoo_template -i base --stop-after-init --log-level=warn --db_host="$PG_HOST" --db_port="$PG_PORT" --db_user="$PG_USER" 2>/dev/null || true
    else
      uv run --no-sync python "${TOPLEVEL}/odoo-bin" -d test_odoo_template -i base --stop-after-init --log-level=warn --db_host="$PG_HOST" --db_port="$PG_PORT" --db_user="$PG_USER" 2>/dev/null || true
    fi

    HAS_TABLES=$(query_sql "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' LIMIT 1;" test_odoo_template)
    if [ "$HAS_TABLES" = "1" ]; then
      mkdir -p "$SNAPSHOT_DIR"
      echo "💾 Caching test_odoo_template snapshot to $SNAPSHOT..."
      if command -v pg_dump >/dev/null 2>&1; then
        pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Fc -d test_odoo_template -f "${SNAPSHOT}.tmp" 2>/dev/null && mv "${SNAPSHOT}.tmp" "$SNAPSHOT" 2>/dev/null || true
      elif command -v enve >/dev/null 2>&1; then
        enve run -- pg_dump -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -Fc -d test_odoo_template -f "${SNAPSHOT}.tmp" 2>/dev/null && mv "${SNAPSHOT}.tmp" "$SNAPSHOT" 2>/dev/null || true
      fi
    fi
  fi
fi


