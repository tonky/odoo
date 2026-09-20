#!/usr/bin/env bash
set -e
PG_DATA="${PGDATA:-/tmp/odoo_enve_postgres}"
if [ ! -d "$PG_DATA/base" ]; then
  mkdir -p "$PG_DATA"
  if command -v enve >/dev/null 2>&1 && [ ! -d "/nix/store/h9aczmrkpcmm9z47648m5n9sg67vi5gw-postgresql-18.6" ]; then
    enve run -- initdb --no-locale -E UTF8 -D "$PG_DATA" -U odoo --auth=trust
  else
    initdb --no-locale -E UTF8 -D "$PG_DATA" -U odoo --auth=trust
  fi
fi
