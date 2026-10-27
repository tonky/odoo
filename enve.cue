package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// Odoo 19.0 as upstream tests it on Ubuntu Noble: Python 3.12 (requirements.txt's Noble
// pins, in pyproject.toml/uv.lock with wheels: psycopg2-binary), PostgreSQL with an `odoo`
// superuser, wkhtmltopdf 0.12.6.1 on Linux, eslint 8, and openldap/cyrus-sasl headers for python-ldap.
profiles: dev: schema.#Profile & {
	name: "odoo-dev"
	tools: [
		pkgs.python & {version: "3.12"},
		pkgs.uv,
		// enact's pytest tracer tests (enact-runner granular_reach_test) trace the fixtures with
		// `pytest` from the env; odoo's own jobs run odoo-bin, not pytest. The catalog has no
		// python312Packages, so it runs on its own 3.13: `python3` stays 3.12.
		{pname: "python313Packages.pytest"},
		pkgs.postgresql_16,
		{pname: "ruff"},
		{pname: "oxlint"},
		// libstdc++ for the wheels linking it (libsass compiles the asset bundles HttpCase
		// tests load): nix's Python doesn't search the host's library dirs. Its lib output
		// only: the unwrapped gcc on PATH compiled with the host's `as` and `ld`.
		{pname: "gcc-unwrapped", attr: "gcc-unwrapped.lib"},
		// uv builds the sdists with no wheel for this Python: psutil and libsass on aarch64-linux,
		// rjsmin and python-ldap everywhere. The wrapped gcc runs its own snapshot's binutils
		// (`as`, `ld` in its bin): the unwrapped GCC 16 with Ubuntu's binutils 2.42 failed on psutil
		// ("unknown pseudo-op: `.aeabi_subsection'"). macOS builds with Xcode's clang, `as`
		// and `ld` (Python's CC is `clang`), one toolchain.
		{pname: "gcc", platforms: [schema.#Platform.Linux]},
		// OpenLDAP and Cyrus SASL headers + libraries so uv builds python-ldap==3.4.4 from sdist
		// for Python 3.12 (auth_ldap's external_dependencies).
		{pname: "openldap", attr: "openldap.dev"},
		{pname: "cyrus-sasl", attr: "cyrus_sasl.dev"},
		// libmagic for python-magic (upstream requirements.txt on Noble): without it `import magic`
		// fails and odoo guesses mimetypes with its own fallback, unlike upstream CI. python-magic
		// dlopens libmagic by name, so `file` puts its own lib dir on the loader path (libraries).
		{pname: "file", libraries: true},
		// Optional tools odoo's tests probe PATH for, as runbot's Noble image installs them: the
		// SMTPD tests skip without `openssl`, test_assetsbundle's RTL tests fail without `rtlcss`
		// (runbot: npm rtlcss@3.4.0), and report/marketing_card tests call `wkhtmltopdf`/`wkhtmltoimage`
		// (nixpkgs builds wkhtmltopdf 0.12.6.1-3 with patched Qt for Linux only).
		{pname: "openssl"},
		{pname: "rtlcss"},
		{pname: "wkhtmltopdf", platforms: [schema.#Platform.Linux]},
		// test_lint's TestESLint runs `eslint --no-ignore --no-eslintrc -c …` (ESLint 8's legacy
		// config CLI) andaddons/web/tooling/_eslintrc.json extends plugin:prettier/recommended;
		// emoji_data.js needs >1 MB of V8 stack in espree (--stack-size=4096), and in a sparse
		// cone where strict_test has 0 files stock eslint exits 2 unless guarded.
		schema.#ArchiveBuildSpec & {
			pname:   "eslint"
			version: "8.57.1"
			src:     "https://registry.npmjs.org/eslint/-/eslint-8.57.1.tgz"
			sha256:  "d1b7839d38cd5738b2242eab4e00771c212e71cc2580468b97934f0fc2f2de3b"
			buildInputs: [{pname: "nodejs", version: "24"}]
			installPhase: """
				set -euo pipefail
				mkdir -p "$out/lib" "$out/bin" "$src/.home"
				cat > "$out/lib/package.json" << 'PKG'
				{"name": "odoo-eslint", "private": true, "dependencies": {"eslint": "8.57.1", "eslint-plugin-prettier": "4.2.1", "eslint-config-prettier": "8.10.0", "prettier": "2.8.8"}}
				PKG
				HOME="$src/.home" npm install --prefix "$out/lib" --no-audit --no-fund --no-update-notifier --strict-ssl=false
				node_bin="$(command -v node)"
				cat > "$out/bin/eslint" << EOF
				#!/usr/bin/env bash
				dir="\\$(cd "\\$(dirname "\\${BASH_SOURCE[0]}")/.." && pwd)"
				has_file=0
				skip=0
				for arg in "\\$@"; do
				    if [ "\\$skip" = 1 ]; then skip=0; continue; fi
				    case "\\$arg" in
				        -c|--config|--resolve-plugins-relative-to|--rule|--ext|--parser|--parser-options|--env|--global|--ignore-path|--ignore-pattern|-f|--format|-o|--output-file|--max-warnings) skip=1 ;;
				        -v|--version|-h|--help) has_file=1 ;;
				        -*) ;;
				        *) has_file=1 ;;
				    esac
				done
				[ "\\$has_file" = 1 ] || exit 0
				exec "${node_bin}" --stack-size=4096 "\\${dir}/lib/node_modules/eslint/bin/eslint.js" --resolve-plugins-relative-to "\\${dir}/lib" "\\$@"
				EOF
				chmod +x "$out/bin/eslint"
				"""
		},
		// The helpers' `git rev-parse` and `#!/usr/bin/env bash` (macOS ships bash 3.2), and
		// their cp/rm/uname: resolved inside `enve run`, these were the host's.
		{pname: "git"},
		{pname: "bash"},
		{pname: "coreutils"},
		// The `ci` component's lint (`cue vet .enact/...`).
		{pname: "cue"},
		// The browser HttpCase tours drive (helpers/odoo-env.sh sets ODOO_BROWSER_BIN):
		// nixpkgs chromium on Linux; on macOS (where nixpkgs builds no chromium), Playwright's
		// chromium-headless-shell from the store so odoo never falls back to a host Chrome in /Applications.
		{pname: "chromium", platforms: [schema.#Platform.Linux]},
		pkgs.#PlaywrightBrowsers & {version: "1.62.1", features: ["chromium-headless-shell"], platforms: [schema.#Platform.Darwin]},
	]
	services: {
		// The pipeline's `db` (.enact/components.cue): each job's database is forked from its
		// addon's closure template `test_odoo_tpl_<seed>`, which setup/ci/post-start-postgres.sh
		// initializes by installing <seed>.
		// On 5436: 5432 is the other usecases' postgres (forgejo, grafana, posthog), and on a
		// shared host (OrbStack forwards the VM's ports to the Mac) odoo reached theirs. enact
		// passes the port to the jobs as PGPORT, which odoo reads: the commands name no port.
		// 5436 is the default instance's (`enve up` by hand): enact runs each run's services in
		// an instance of its own, on free ports ($PORT, ${ENVE_SERVICE_DB_PORT}).
		db: pkgs.#PostgresService & {
			name:    "db"
			package: pkgs.postgresql_16
			// The role initdb creates, which the health and readiness probes connect as.
			user: "odoo"
			lifecycle: init: ["initdb -D \"$DATA_DIR\" -U odoo --auth-local=trust --auth-host=trust --encoding=UTF8 --no-locale"]
			command: "postgres -D \"$DATA_DIR\" -k \"$SOCKET_DIR\" -h 127.0.0.1 -p $PORT -c fsync=off -c full_page_writes=off -c synchronous_commit=off -N 250"
			port:    5436
		}
	}
	environment: {
		PGHOST:           "127.0.0.1"
		PGPORT:           "${ENVE_SERVICE_DB_PORT}"
		PGUSER:           "odoo"
		PYTHONNOUSERSITE: "1"
		// uv runs the env's Python only: by default it prefers its own managed interpreters (a
		// host's ~/.local/share/uv/python) and downloads one when none matches.
		UV_PYTHON_PREFERENCE: "only-system"
		UV_PYTHON_DOWNLOADS:  "never"
	}
}
