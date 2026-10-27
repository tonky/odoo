#!/usr/bin/env bash
# post-start-postgres.sh <addon>: the `db` service's template_init (.enact/components.cue).
# enact runs it when the template a job's database is forked from (PGDATABASE) has no tables,
# or another init built it. It installs <addon> there from scratch: its dependency closure and
# the auto_install addons those pull in (`base` alone for base's template). Each job forks the
# largest template its own install contains (resolve_sparse_checkout.py TEMPLATE_SEEDS) and
# installs only the rest. With demo data, as odoo's runbot tests: an addon installs its demo
# data when all its dependencies have, and tests rely on it (l10n_fr_hr_holidays reads
# OdooBot's timezone, which only demo data sets).
# odoo's data dir is enact's template dir (ENACT_TEMPLATE_DIR): the file store the install
# writes is kept with the template's dump, and each shard copies it (helpers/odoo-shard.sh).
set -euo pipefail
addon="${1:?usage: post-start-postgres.sh <addon>}"
if [ -n "${ENACT_TEMPLATE_DIR:-}" ]; then
    export ODOO_DATA_DIR="${ENACT_TEMPLATE_DIR}"
fi
exec bash "$(dirname "$0")/../../helpers/odoo-runner.sh" -d "${PGDATABASE:?}" -i "${addon}" --with-demo --stop-after-init --log-level=warn
