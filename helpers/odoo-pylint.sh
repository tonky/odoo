#!/usr/bin/env bash
# odoo-pylint.sh <python files, by their path from the repository root...>: upstream's pylint
# checks (odoo/addons/test_lint/tests/test_pylint.py, TestPyLint) on the given files, which
# TestPyLint runs on the whole tree: the same options, its checker plugins and uv.lock's
# pylint. Its findings fail, as TestPyLint's do. TestPyLint lints odoo/ and the addons only:
# other files are skipped. The option lists below are upstream's: tests/conformance.rs
# compares them.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tests=odoo/addons/test_lint/tests

files=()
for file in "$@"; do
    case "${file}" in
    odoo/*.py | addons/*.py) [ -f "${file}" ] && files+=("${file}") ;;
    esac
done
[ "${#files[@]}" -gt 0 ] || exit 0

fixed=(
    --rcfile=/dev/null
    --disable=all,useless-option-value
    --reports=n
    "--msg-template='{msg} ({msg_id}) at {path}:{line}'"
    --bad-functions=input
)
enable=(
    used-before-assignment
    undefined-variable
    eval-used
    unreachable
    function-redefined
    # custom checkers
    sql-injection
    missing-gettext
    gettext-variable
    gettext-placeholders
    gettext-repr
    raise-unlink-override
)
plugins=(
    _pylint_path_setup
    pylint.extensions.bad_builtin
    _odoo_checker_sql_injection
    _odoo_checker_gettext
    _odoo_checker_unlink_override
)
# csv, urllib, cgi and odoo.tools.constants.SUPPORTED_DEBUGGER
deprecated=(
    csv
    urllib
    cgi
    ipdb
    pdb
    pudb
    wdb
)

join() {
    local IFS=,
    echo "$*"
}

# The plugins load from the tests directory and import odoo; `_pylint_path_setup` adds
# ADDONS_PATH to odoo.addons, as odoo's own addons path does.
PYTHONPATH="${PWD}/${tests}:${PWD}" ADDONS_PATH="${PWD}/odoo/addons:${PWD}/addons" \
    exec uv run --frozen --exact pylint "${fixed[@]}" \
    "--enable=$(join "${enable[@]}")" \
    "--load-plugins=$(join "${plugins[@]}")" \
    "--deprecated-modules=$(join "${deprecated[@]}")" \
    "${files[@]}"
