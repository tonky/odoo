#!/usr/bin/env bash
# Run a shard using the port and filestore context acquired by its declarative fixture.
# Standalone callers acquire the same fixture and release it when odoo exits.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
if [[ "${1:-}" == acquire || "${1:-}" == release ]]; then
    exec bash "${here}/odoo-fixture.sh" "$@"
fi
source "${here}/odoo-env.sh"
if [[ -z "${ODOO_SHARD_HTTP_PORT:-}" ]]; then
    export ENACT_FIXTURE_OWNER_PID="${ENACT_FIXTURE_OWNER_PID:-$$}"
    fixture_env="$(bash "${here}/odoo-fixture.sh" acquire --shell)"
    eval "${fixture_env}"
    trap 'status=$?; bash "${here}/odoo-fixture.sh" release || { cleanup=$?; if (( status == 0 )); then status=$cleanup; fi; }; exit "${status}"' EXIT
    bash "${here}/odoo-runner.sh" -d "${PGDATABASE:?}" --http-port="${ODOO_SHARD_HTTP_PORT}" "$@"
else
    exec bash "${here}/odoo-runner.sh" -d "${PGDATABASE:?}" --http-port="${ODOO_SHARD_HTTP_PORT}" "$@"
fi
