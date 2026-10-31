package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// Odoo 19.0 environment matching Ubuntu Noble runbot: Python 3.12, PostgreSQL 16, wkhtmltopdf, eslint 8.
profiles: dev: schema.#Profile & {
	name: "odoo-dev"
	tools: [
		pkgs.python & {version: "3.12"},
		pkgs.uv,
		{pname: "python313Packages.pytest"},
		pkgs.postgresql_16,
		{pname: "ruff"},
		{pname: "oxlint"},
		{pname: "gcc-unwrapped", attr: "gcc-unwrapped.lib"},
		{pname: "gcc", platforms: [schema.#Platform.Linux]},
		{pname: "openldap", attr: "openldap.dev"},
		{pname: "cyrus-sasl", attr: "cyrus_sasl.dev"},
		{pname: "file", libraries: true},
		{pname: "openssl"},
		{pname: "rtlcss"},
		{pname: "wkhtmltopdf", platforms: [schema.#Platform.Linux]},
		schema.#ArchiveBuildSpec & {
			pname: "eslint", version: "8.57.1"
			src:    "https://registry.npmjs.org/eslint/-/eslint-8.57.1.tgz"
			sha256: "d1b7839d38cd5738b2242eab4e00771c212e71cc2580468b97934f0fc2f2de3b"
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
		{pname: "git"},
		{pname: "bash"},
		{pname: "coreutils"},
		{pname: "cue"},
		pkgs.#PlaywrightBrowsers & {version: "1.62.1", features: ["chromium-headless-shell"]},
	]
	services: db: pkgs.#PostgresService & {
		name:    "db"
		package: pkgs.postgresql_16
		user: "odoo"
		lifecycle: init: ["initdb -D \"$DATA_DIR\" -U odoo --auth-local=trust --auth-host=trust --encoding=UTF8 --no-locale"]
		command: "postgres -D \"$DATA_DIR\" -k \"$SOCKET_DIR\" -h 127.0.0.1 -p $PORT -c fsync=off -c full_page_writes=off -c synchronous_commit=off -N 250"
		port:    5436
	}
	environment: {
		PGHOST:               "127.0.0.1"
		PGPORT:               "${ENVE_SERVICE_DB_PORT}"
		PGUSER:               "odoo"
		PYTHONNOUSERSITE:     "1"
		UV_PYTHON_PREFERENCE: "only-system"
		UV_PYTHON_DOWNLOADS:  "never"
	}
}
