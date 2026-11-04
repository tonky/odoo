#!/usr/bin/env bash
# Per-shard HTTP lease and external state corresponding to the runner's PG template clone.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
source "${here}/odoo-env.sh"

release() {
    local status=0
    if [[ -n "${ODOO_SHARD_HTTP_PORT:-}" ]]; then
        "${ENACT_EXE:-${ENACT_BIN:-enact}}" helper free-ports --owner "${ENACT_FIXTURE_OWNER_PID:-${PPID}}" \
            --release "${ODOO_SHARD_HTTP_PORT}" 1 || status=$?
    fi
    [[ -z "${ODOO_SHARD_FILESTORE:-}" ]] || rm -rf -- "${ODOO_SHARD_FILESTORE}"
    return "${status}"
}

if [[ "${1:-}" == release ]]; then release; exit; fi
[[ "${1:-}" == acquire ]] || { echo 'usage: odoo-fixture.sh acquire [--shell] | release' >&2; exit 2; }
ODOO_SHARD_HTTP_PORT="$(PORTS_OWNER="${ENACT_FIXTURE_OWNER_PID:-${PPID}}" bash "${here}/free-port.sh")"
export ODOO_SHARD_HTTP_PORT
export ODOO_SHARD_FILESTORE=""
trap 'status=$?; if (( status != 0 )); then release >&2 || true; fi' EXIT
if [[ -n "${ENACT_SHARD_TEMPLATE:-}" ]]; then
    export ODOO_SHARD_FILESTORE="${ODOO_DATA_DIR}/filestore/${PGDATABASE:?}"
    rm -rf -- "${ODOO_SHARD_FILESTORE}"
    mkdir -p "${ODOO_DATA_DIR}/filestore"
    template="${ENACT_TEMPLATE_DIR:-${ODOO_DATA_DIR}}/filestore/${ENACT_SHARD_TEMPLATE}"
    if [[ -d "${template}" ]]; then
        cp -R "${template}" "${ODOO_SHARD_FILESTORE}"
    elif [[ -n "${ENACT_TEMPLATE_DIR:-}" ]]; then
        echo "odoo-shard: the template's file store ${template} is missing" >&2
        exit 1
    fi
    psql -q -v ON_ERROR_STOP=1 \
        -c "UPDATE ir_config_parameter SET value = 'http://localhost:${ODOO_SHARD_HTTP_PORT}' WHERE key = 'web.base.url'"
fi
python3 - "${2:-}" <<'PY'
import json, os, shlex, sys
values = {key: os.environ[key] for key in ('ODOO_SHARD_HTTP_PORT', 'ODOO_SHARD_FILESTORE')}
if sys.argv[1] == '--shell':
    for key, value in values.items():
        print(f'export {key}={shlex.quote(value)}')
else:
    context = json.dumps({'env': values, 'resources': ['port:' + values['ODOO_SHARD_HTTP_PORT']]})
    path = os.environ.get('ENACT_FIXTURE_CONTEXT_FILE')
    if path:
        with open(path, 'w') as file:
            file.write(context + '\n')
    else:
        print(context)
PY
