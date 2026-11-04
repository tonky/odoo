#!/usr/bin/env bash
# odoo-runner.sh <odoo-bin args...>: upstream's odoo-bin in the uv environment, exactly uv.lock,
# from the repository root, wherever a job runs it. Its data directory (file stores,
# sessions) is ODOO_DATA_DIR, else the checkout's for the service instance (odoo-env.sh).
# With ENACT_FOOTPRINT_DIR
# (a directory: `enact trace record` sets it), the run records each test class's footprint
# in a map there (odoo-footprint.py);
# with ODOO_DURATIONS (a directory), each test class's seconds (odoo-durations.py). A
# --test-enable run that runs 0 tests fails.
set -euo pipefail
# The process environment odoo needs beyond the env's PATH (libmagic on macOS, the data dir).
source "$(dirname "$0")/odoo-env.sh"
cd "$(git rev-parse --show-toplevel)"
# Each recorder runs the next as its odoo-bin, the last odoo-bin itself.
recorders=()
if [ -n "${ODOO_DURATIONS:-}" ]; then
    recorders+=(helpers/odoo-durations.py "${ODOO_DURATIONS}")
fi
if [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
    recorders+=(helpers/odoo-footprint.py "${ENACT_FOOTPRINT_DIR}")
fi
# A failed tour's screenshot and Chrome log go to the CI job's temp dir (the job uploads them,
# .enact/ci.cue diagnostic_paths), else the data dir: odoo's default is the host's /tmp/odoo_tests.
odoo=(uv run --frozen --exact python ${recorders[@]+"${recorders[@]}"} odoo-bin --data-dir="${ODOO_DATA_DIR}"
    --screenshots="${RUNNER_TEMP:-${ODOO_DATA_DIR}}/odoo_tests" "$@")
case " $* " in
    *" --test-enable "*) ;;
    *) exec "${odoo[@]}" ;;
esac
# A test run must run tests: odoo exits 0 with "0 failed, 0 error(s) of 0 tests when loading
# database" when --test-tags match nothing (a renamed class, a module whose tests aren't
# imported, an existing database whose at_install tests don't run again). Fail it instead.
# A file whose classes all skip (a skipTest in setUpClass: hr_holidays' TestWorkingHours once
# hr_contract is installed) counts 0 tests too, but logs each skip: it passes.
log="$(mktemp)"
trap 'rm -f "${log}"' EXIT
set +e
"${odoo[@]}" 2>&1 | tee "${log}"
rc=${PIPESTATUS[0]}
set -e
[ "${rc}" -eq 0 ] || exit "${rc}"
summary="" skipped=0
while IFS= read -r line; do
    case "${line}" in
        *" when loading database "*) summary="${line}" ;;
        # OdooTestResult.addSkip logs "INFO <db> <test's module>: skipped <test> : <reason>",
        # a class's skip in setUpClass as odoo.tests.suite's.
        *" INFO "*" odoo.tests.suite: skipped "*" : "* | *" INFO "*" odoo.addons."*".tests."*": skipped "*" : "*)
            skipped=$((skipped + 1)) ;;
    esac
done <"${log}"
case "${summary}" in
    "") echo "odoo-runner: odoo exited 0 without its test summary (\"... of N tests when loading database\")" >&2; exit 1 ;;
    *" of 0 tests when loading database "*)
        if [ "${skipped}" -eq 0 ]; then
            echo "odoo-runner: odoo ran 0 tests: --test-tags matched none (args: $*)" >&2
            exit 1
        fi
        echo "odoo-runner: odoo ran 0 tests, skipped ${skipped}" >&2
        ;;
esac
