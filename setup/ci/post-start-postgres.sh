#!/usr/bin/env bash
if command -v enve >/dev/null 2>&1 && [ ! -d "/nix/store/h9aczmrkpcmm9z47648m5n9sg67vi5gw-postgresql-18.6" ]; then
  enve run -- psql -h 127.0.0.1 -p 5432 -U odoo -d postgres -c "CREATE DATABASE test_odoo;" 2>/dev/null || true
  enve run -- psql -h 127.0.0.1 -p 5432 -U odoo -d postgres -c "CREATE DATABASE test_odoo_template;" 2>/dev/null || true
else
  psql -h 127.0.0.1 -p 5432 -U odoo -d postgres -c "CREATE DATABASE test_odoo;" 2>/dev/null || true
  psql -h 127.0.0.1 -p 5432 -U odoo -d postgres -c "CREATE DATABASE test_odoo_template;" 2>/dev/null || true
fi
