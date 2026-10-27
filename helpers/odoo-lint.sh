#!/usr/bin/env bash
# odoo-lint.sh <changed files...>: a component's lint, each file by its own linter.
# - Python: ruff with upstream's ruff.toml, advisory (--exit-zero) as on runbot, whose nightly
#   writes that config: the tree has ~37k findings under it. A missing ruff or a bad config
#   still fails, which `ruff check … || true` hid. Then upstream's pylint checks
#   (odoo-pylint.sh, TestPyLint's on the whole tree), whose findings fail the job.
# - JavaScript: oxlint with the overlay's oxlint.json; its errors fail the job (the tree has
#   warnings only).
# Other files (XML, CSV, SCSS) have no linter here: ruff read them as Python.
# The files are relative to the working directory: a job's is its component's root, and
# enact names changed files from there (`../../../odoo/...`). The linters run from the
# repository root, on the files by their path from it.
set -euo pipefail
py=()
js=()
for file in "$@"; do
    [ -f "${file}" ] || continue
    file="$(cd "$(dirname "${file}")" && git rev-parse --show-prefix)$(basename "${file}")"
    case "${file}" in
    *.py) py+=("${file}") ;;
    *.js) js+=("${file}") ;;
    esac
done
cd "$(git rev-parse --show-toplevel)"
status=0
if [ "${#py[@]}" -gt 0 ]; then
    ruff check --exit-zero "${py[@]}" || status=$?
    bash helpers/odoo-pylint.sh "${py[@]}" || status=$?
fi
if [ "${#js[@]}" -gt 0 ]; then
    oxlint -c oxlint.json "${js[@]}" || status=$?
fi
exit "${status}"
