#!/usr/bin/env bash
set -e
PG_DATA="${PGDATA:-/tmp/odoo_enve_postgres}"
if [ ! -d "$PG_DATA/base" ]; then
  mkdir -p "$PG_DATA"
  if [ "$(id -u)" = "0" ]; then
    UNPRIV_USER="${ENVE_SERVICE_USER:-ubuntu}"
    if ! id "$UNPRIV_USER" >/dev/null 2>&1; then
      UNPRIV_USER=$(id -nu "${ENVE_SERVICE_UID:-1000}" 2>/dev/null || echo "nobody")
    fi
    chown -R "$UNPRIV_USER" "$PG_DATA" 2>/dev/null || true
    INIT_BIN="$(command -v initdb 2>/dev/null || true)"
    if [ -z "$INIT_BIN" ]; then
      for cand in /nix/store/*postgresql*/bin/initdb ~/.local/share/enve/store/*postgresql*/bin/initdb; do
        if [ -x "$cand" ]; then
          INIT_BIN="$cand"
          break
        fi
      done
    fi
    if [ -n "$INIT_BIN" ]; then
      su "$UNPRIV_USER" -c "$INIT_BIN --no-locale -E UTF8 -D '$PG_DATA' -U odoo --auth=trust"
    else
      su "$UNPRIV_USER" -c "PATH=\"$PATH\" enve run -- initdb --no-locale -E UTF8 -D '$PG_DATA' -U odoo --auth=trust"
    fi
  else
    if command -v enve >/dev/null 2>&1 && [ ! -d "/nix/store/h9aczmrkpcmm9z47648m5n9sg67vi5gw-postgresql-18.6" ]; then
      enve run -- initdb --no-locale -E UTF8 -D "$PG_DATA" -U odoo --auth=trust
    else
      initdb --no-locale -E UTF8 -D "$PG_DATA" -U odoo --auth=trust
    fi
  fi
fi
