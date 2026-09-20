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

# 3. Pre-populate template database with base schema if empty
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$REPO_ROOT/odoo-bin" ]; then
  TABLE_COUNT=$(query_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" "test_odoo_template")
  if [ -z "$TABLE_COUNT" ] || [ "$TABLE_COUNT" -eq 0 ] 2>/dev/null; then
    echo "⚡ Initializing test_odoo_template with base module..."
    if command -v uv >/dev/null 2>&1; then
      uv run python "$REPO_ROOT/odoo-bin" -d test_odoo_template --db_host="$PGHOST" --db_port="$PGPORT" --db_user="$PGUSER" -i base --stop-after-init --no-http
    elif command -v enve >/dev/null 2>&1; then
      enve run -- uv run python "$REPO_ROOT/odoo-bin" -d test_odoo_template --db_host="$PGHOST" --db_port="$PGPORT" --db_user="$PGUSER" -i base --stop-after-init --no-http
    fi
  fi
fi
