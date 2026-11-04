#!/usr/bin/env bash
# odoo-shard.sh <odoo-bin args...>: a shard's odoo run on its database (PGDATABASE), which
# enact forked from the `db` service's template (ENACT_SHARD_TEMPLATE, .enact/components.cue).
# The fork copies the database only, so first this gives it what odoo keeps outside it:
# - the template's file store, under the shard database's name in this run's data dir
#   (odoo-env.sh): the attachments installing base created live there, and the fork's
#   records point at them. The template's build wrote it in enact's template dir
#   (ENACT_TEMPLATE_DIR, setup/ci/post-start-postgres.sh), which a restored dump gets back;
# - web.base.url, which the template's build set to its own port: the links the tests check
#   carry the shard's HTTP port.
set -euo pipefail
source "$(dirname "$0")/odoo-env.sh" # ODOO_DATA_DIR
# odoo's HTTP port: a free one, reserved while this process (odoo-runner.sh, after the exec) lives.
# Never one from the shard or slot number: those are per run, and two runs on one host
# collided on it (free-port.sh).
port="$(PORTS_OWNER=$$ bash "$(dirname "$0")/free-port.sh")"
if [ -n "${ENACT_SHARD_TEMPLATE:-}" ]; then
    filestore="${ODOO_DATA_DIR}/filestore"
    rm -rf "${filestore:?}/${PGDATABASE:?}"
    mkdir -p "${filestore}"
    template="${ENACT_TEMPLATE_DIR:-${ODOO_DATA_DIR}}/filestore/${ENACT_SHARD_TEMPLATE}"
    if [ -d "${template}" ]; then
        cp -R "${template}" "${filestore}/${PGDATABASE}"
    elif [ -n "${ENACT_TEMPLATE_DIR:-}" ]; then
        # Installing base always writes some: its attachments would be missing.
        echo "odoo-shard: the template's file store ${template} is missing" >&2
        exit 1
    fi
    psql -q -v ON_ERROR_STOP=1 \
        -c "UPDATE ir_config_parameter SET value = 'http://localhost:${port}' WHERE key = 'web.base.url'"
fi
exec bash "$(dirname "$0")/odoo-runner.sh" -d "${PGDATABASE:?}" --http-port="${port}" "$@"
