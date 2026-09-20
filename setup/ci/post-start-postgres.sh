#!/usr/bin/env bash
set -e

PG_USER="${PGUSER:-odoo}"
PG_HOST="${PGHOST:-127.0.0.1}"
PG_PORT="${PGPORT:-5432}"

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

# 2. Create databases
exec_sql "CREATE DATABASE test_odoo;"
exec_sql "CREATE DATABASE test_odoo_template;"

# 3. Pre-populate template database with base schema if empty
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ -f "$REPO_ROOT/odoo-bin" ]; then
  TABLE_COUNT=$(query_sql "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" "test_odoo_template")
  if [ -z "$TABLE_COUNT" ] || [ "$TABLE_COUNT" -eq 0 ] 2>/dev/null; then
    echo "⚡ Initializing test_odoo_template with base module..."
    if command -v uv >/dev/null 2>&1; then
      uv run python "$REPO_ROOT/odoo-bin" -d test_odoo_template -i base --stop-after-init --no-http 2>/dev/null || true
    elif command -v enve >/dev/null 2>&1; then
      enve run -- uv run python "$REPO_ROOT/odoo-bin" -d test_odoo_template -i base --stop-after-init --no-http 2>/dev/null || true
    fi
  fi
fi
