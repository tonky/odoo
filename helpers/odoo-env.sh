# odoo-env.sh, sourced (odoo-runner.sh, odoo-shard.sh): what odoo's process needs from the
# env beyond PATH.
# odoo's data dir (file stores, sessions), unless ODOO_DATA_DIR names one: the checkout's, per
# enve service instance (ENVE_INSTANCE, which enact sets to each run's own), as the databases
# whose file stores it holds are. Never one per user ($HOME): two runs on one host name their
# shard databases alike (postgres_<n>), and one run's delete of a file store raced the
# other's copy.
if [ -z "${ODOO_DATA_DIR:-}" ]; then
    ODOO_DATA_DIR="$(git rev-parse --show-toplevel)/.enve${ENVE_INSTANCE:+/instances/${ENVE_INSTANCE}}/odoo"
    export ODOO_DATA_DIR
fi
# Libraries odoo loads by name (python-magic's libmagic): enve puts a `libraries: true` tool's lib
# dir on the loader path, LD_LIBRARY_PATH on Linux and DYLD_FALLBACK_LIBRARY_PATH on macOS. SIP
# drops DYLD_* when /usr/bin/env starts bash (odoo-runner.sh), so on macOS rebuild the fallback
# here from LIBRARY_PATH, which lists every declared tool's lib dir. Not /usr/local/lib, the
# default's: Homebrew's libmagic would answer.
if [ "$(uname -s)" = Darwin ] && [ -n "${LIBRARY_PATH:-}" ]; then
    export DYLD_FALLBACK_LIBRARY_PATH="${LIBRARY_PATH}:/usr/lib"
fi
# The browser HttpCase tours drive: odoo tries google-chrome before chromium on Linux and
# looks only in /Applications on macOS, so point ODOO_BROWSER_BIN at the env's headless
# shell (chrome-headless-shell-<platform>/chrome-headless-shell; Playwright's own Linux arm64
# build: chrome-linux/headless_shell).
if [ -z "${ODOO_BROWSER_BIN:-}" ] && [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
    for _bin in "${PLAYWRIGHT_BROWSERS_PATH}"/chromium_headless_shell-*/*/chrome-headless-shell \
        "${PLAYWRIGHT_BROWSERS_PATH}"/chromium_headless_shell-*/chrome-linux/headless_shell; do
        if [ -x "${_bin}" ]; then
            export ODOO_BROWSER_BIN="${_bin}"
            break
        fi
    done
    unset _bin
fi
# odoo's tests expect TMPDIR=/tmp:
# - base's TestConfigManager asserts `screenshots == '/tmp/odoo_tests'` after clearing
#   os.environ, whereas Python's `tempfile.gettempdir()` caches `tempfile.tempdir` when
#   `odoo.tools.config` imports at startup;
# - web.minimal_layout's wkhtmltopdf header/footer script splits `vars['webpage']`
#   (`file://<TMPDIR>/report.body.tmp.<idx>.<rand>.html`) with `split('.', 4)[3]`, so a dot in
#   $TMPDIR shifts the index and wipes PDF headers and footers (TestReportsRendering.test_layout).
export TMPDIR=/tmp
# Every addon's manifest odoo reads, in a sparse checkout (odoo-manifests.sh).
bash "$(dirname "${BASH_SOURCE[0]}")/odoo-manifests.sh"
