package replay

import (
	"list"
	"strings"

	"enact.dev/schema"
)

let _baseIncidental = [
	"**/__manifest__.py",
	"**/README.md",
	"**/README.rst",
	"**/static/description/**",
	"**/static/img/**",
]

let _l10nAddons = [for k, _ in _addons if strings.HasPrefix(k, "l10n_") {k}]
let _l10nGlobs = [for k in _l10nAddons {"addons/\(k)/**"}]

#OdooTargetScope: schema.#TargetScope & {
	fallback:         "all"
	incidental_reads: [...string] | *_baseIncidental
}

#OdooLint: schema.#Task & {
	command: "bash \"$(git rev-parse --show-toplevel)/helpers/odoo-lint.sh\" {changed_files}"
	filter: {include: ["**/*.py", "**/*.js"], on_empty: "skip"}
}

let shardFixture = {
	setup:     "bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh acquire"
	release:   "bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh release"
	services:  ["db"]
	allow_env: ["ODOO_SHARD_HTTP_PORT", "ODOO_SHARD_FILESTORE"]
	inputs:    ["helpers/odoo-shard.sh", "helpers/odoo-fixture.sh", "helpers/odoo-env.sh"]
	timeout:   "120s"
}

#OdooAddonBase: schema.#Component & {
	kind:       schema.#ComponentKindMode | *"addon"
	domain:     string | *"erp"
	technology: "python"
	resources: {cpus: float | *1.0, memory_mb: int | *2048}
	services: db: schema.#PostgresService & {
		name:     "db"
		user:     "odoo"
		database: "postgres"
		port:     5436
		enact: {
			template:        string
			template_init:   string
			template_inputs: {include: [...string], exclude: [...string]}
		}
	}
	jobs: lint: {
		resources: {cpus: 2.0, memory_mb: 2048}
		tasks: [#OdooLint]
	}
	workspace_scope: include_dependencies: true
	scoping: domain_roots: [...string]
}

_addons: [string]: {
	not_run:       *[] | [...schema.#NotRun]
	known_not_run: *[] | [...schema.#NotRun]
	template:      *"base" | string
	test_install:  *[] | [...string]
}
_templates: [string]: addon_dirs: [...string]

pipeline: schema.#Pipeline & {
	name:        "odoo-platform"
	description: "Odoo Modular ERP: Accelerated CI/CD Pipeline (enact + enve)"
	env: {}
	workspace_scope: {
		include: [
			"enve.cue", "enve.lock", "odoo-bin", "requirements.txt", "setup.py", "setup.cfg",
			"pyproject.toml", "Justfile", "oxlint.json", "ruff.toml", "uv.lock", ".enact",
			"cue.mod", "bin", "helpers", "odoo", "setup", "addons/api_doc", "addons/auth_passkey",
			"addons/auth_totp", "addons/base_import", "addons/base_import_module", "addons/base_setup",
			"addons/bus", "addons/html_editor", "addons/http_routing", "addons/iap", "addons/rpc",
			"addons/web", "addons/web_tour", "addons/web_unsplash",
		]
		ignore: [
			"README.md", "CONTRIBUTING.md", "COPYRIGHT", "LICENSE", "SECURITY.md",
			".weblate.json", ".gitignore", "debian/**",
		]
		hooks: post: ["bin/odoo-scope sparse -c {component_root}"]
	}
	components: {
		for addon, meta in _addons {
			("\(addon)"): #OdooAddonBase & {
				name:        "\(addon)"
				title:       string | *"Odoo Addon \(addon)"
				root:        meta.dir
				depends_on:  [...string] | *meta.depends
				watch_paths: [...string] | *["\(meta.dir)/**"]
				workspace_scope: include: list.Concat([
					_templates[meta.template].addon_dirs,
					[if addon == "stock_delivery" {"addons/sale_management"}],
					[if addon == "stock_delivery" {"addons/sale_pdf_quote_builder"}],
				])
				services: db: enact: {
					template:      "test_odoo_tpl_\(meta.template)"
					template_init: "bash setup/ci/post-start-postgres.sh \(meta.template)"
					template_inputs: {
						include: list.Concat([[
							"odoo-bin", "uv.lock", "pyproject.toml", "enve.lock",
							"setup/ci/post-start-postgres.sh",
							"helpers/odoo-runner.sh", "helpers/odoo-env.sh",
							"helpers/odoo-manifests.sh", "odoo/**",
						], _templates[meta.template].addon_dirs])
						exclude: ["**/tests/**", "odoo/addons/test_*/**"]
					}
				}
				if meta.has_tests {
					shards: "auto"
					target_scope: #OdooTargetScope & {
						default_target: "/\(addon)"
						let _iban_incidental = [
							if addon != "base_iban" && !list.Contains(meta.depends, "base_iban") {"addons/base_iban/**"},
						]
						let _l10n_deps = [for d in meta.depends if strings.HasPrefix(d, "l10n_") {d}]
						let _l10n_ti = [for d in meta.test_install if strings.HasPrefix(d, "l10n_") {d}]
						if !strings.HasPrefix(addon, "l10n_") && len(_l10n_deps) == 0 && len(_l10n_ti) == 0 {
							incidental_reads: list.Concat([
								_baseIncidental,
								_iban_incidental,
								_l10nGlobs,
							])
						}
						if !strings.HasPrefix(addon, "l10n_") && (len(_l10n_deps) > 0 || len(_l10n_ti) > 0) {
							incidental_reads: list.Concat([
								_baseIncidental,
								_iban_incidental,
								[for k in _l10nAddons if !list.Contains(_l10n_deps, k) && !list.Contains(_l10n_ti, k) {"addons/\(k)/**"}],
							])
						}
						if strings.HasPrefix(addon, "l10n_") {
							let _cc_parts = strings.Split(addon, "_")
							let _cc_prefix = "\(_cc_parts[0])_\(_cc_parts[1])"
							incidental_reads: list.Concat([
								_baseIncidental,
								_iban_incidental,
								[for k in _l10nAddons if !strings.HasPrefix(k, _cc_prefix) && !list.Contains(_l10n_deps, k) && !list.Contains(_l10n_ti, k) {"addons/\(k)/**"}],
							])
						}
						tests: [...string] | *[
							"\(meta.dir)/tests/**/test_*.py",
							"\(meta.dir)/migrations/tests/test_*.py",
							"\(meta.dir)/upgrades/tests/test_*.py",
						]
						not_run: list.Concat([meta.not_run, meta.known_not_run])
						rules: [
							{match: ["addons/**/*.py", "odoo/**/*.py"], engine: "python"},
							{match: ["\(meta.dir)/**/*.js", "\(meta.dir)/**/*.xml", "\(meta.dir)/**/*.csv"], action: "full_component"},
						]
					}
					recorder: "own"
					let excluded = strings.Join([for f in meta.known_failures if f.os == "all" {",-/\(addon):\(f.test)"}], "")
					let darwin_excluded = strings.Join([for f in meta.known_failures if f.os == "darwin" {",-/\(addon):\(f.test)"}], "")
					let max_failed = [if addon != "base" {"ODOO_TEST_MAX_FAILED_TESTS=10 "}, ""][0]
					let install_addons = strings.Join(list.Concat([[addon], meta.test_install]), ",")
					jobs: test: {
						fixture: shardFixture
						tasks: [{
							command: string | *"\(max_failed)bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh -i \(install_addons) -u \(addon) --test-enable --stop-after-init --test-tags {targets_tags}\(excluded)"
							if darwin_excluded != "" {
								env: ODOO_DARWIN_EXCLUDE_TAGS: darwin_excluded
							}
							if addon == "point_of_sale" {
								timeout: "25m"
							}
						}]
					}
				}
			}
		}

		"base": {
			description: "Odoo core kernel, ORM, data models, security, and base addon"
			title:       "Odoo Base Framework & Core Models"
			kind:        "service"
			domain:      "kernel"
			uses:        [{protocol: schema.#Protocol.Sql, target: "db", title: "ORM relational model persistence"}]
			resources:   {cpus: 2.0, memory_mb: 4096}
			root:        "odoo/addons/base"
			scoping: domain_roots: ["odoo/addons/base", "odoo"]
			tags:        ["core", "base", "backend"]
			watch_paths: ["odoo/addons/base/**", "odoo/**"]
			depends_on:  ["root"]
		}
		"web": {
			description: "Odoo web client, owl components, and UI assets"
			title:       "Odoo Web Client & Owl UI Engine"
			kind:        "app"
			domain:      "web"
			uses:        [{protocol: schema.#Protocol.Http, target: "base", title: "JSON-RPC & Owl controller dispatch"}]
			tags:        ["web", "ui"]
		}
		"mail": {
			description: "Odoo discussions, activities, and communication gateways"
			title:       "Odoo Discussions & Activity Gateway"
			domain:      "communication"
			resources:   {cpus: 2.0, memory_mb: 4096}
			tags:        ["mail", "discuss"]
		}
		"account": {
			description: "Odoo Invoicing and Accounting core framework"
			title:       "Odoo Invoicing & Financial Accounting"
			domain:      "finance"
			resources:   {cpus: 2.0, memory_mb: 4096}
			tags:        ["account", "invoicing"]
		}
		"sale": {
			description: "Odoo Sales quotations, pricing rules, and sales orders"
			title:       "Odoo Sales & Quotation Management"
			domain:      "commerce"
			resources:   {cpus: 2.0, memory_mb: 4096}
			tags:        ["sale", "crm"]
		}
		"stock": {
			description: "Odoo Inventory, delivery orders, and warehouse management"
			title:       "Odoo Inventory & Warehouse Logistics"
			domain:      "logistics"
			tags:        ["stock", "inventory"]
		}
		"point_of_sale": {
			resources: {cpus: 2.0, memory_mb: 4096}
		}
		"pos_restaurant": {
			resources: {cpus: 2.0, memory_mb: 4096}
		}
		"website": {
			resources: {cpus: 2.0, memory_mb: 4096}
		}
		"website_sale": {
			resources: {cpus: 2.0, memory_mb: 4096}
		}
		"test_lint": {
			target_scope: tests: [
				"odoo/addons/test_lint/tests/test_[!p]*.py",
				"odoo/addons/test_lint/tests/test_p[!y]*.py",
			]
			recorder: "own"
			jobs: test: tasks: [{command: "ODOO_TEST_MAX_FAILED_TESTS=10 bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh -i test_lint -u test_lint --test-enable --stop-after-init --test-tags {targets_tags},-/test_lint:TestPyLint"}]
			jobs: pylint: {
				fixture: shardFixture
				tasks: [{
					name:    "TestPyLint"
					command: "bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh -i test_lint -u test_lint --test-enable --stop-after-init --test-tags /test_lint:TestPyLint"
					timeout: "20m"
				}]
			}
		}
		"root": {
			description: "Odoo platform entrypoints, runtime dependencies, packaging, and tooling"
			title:       "Odoo Platform Entrypoints & Packaging"
			root:        "."
			watch_paths: [
				"Justfile", "MANIFEST.in", "enve.cue", "enve.lock",
				"odoo-bin", "pyproject.toml", "requirements.txt",
				"setup.cfg", "setup.py", "uv.lock", "setup/**", "helpers/**",
				"bin/**", ".enact/**", ".github/**", "cue.mod/**",
			]
			lint: #OdooLint
		}
		"lint_config": {
			description: "Repository-wide Python and JavaScript linter configuration"
			title:       "Linter Configuration"
			root:        "."
			watch_paths: ["oxlint.json", "ruff.toml"]
			depends_on:  ["root"]
			jobs: lint: {
				direct:    true
				services:  false
				resources: {cpus: 2.0, memory_mb: 2048}
				tasks: [{
					name:    "verify-lint-config"
					command: "ruff check --config ruff.toml --exit-zero odoo-bin && oxlint -c oxlint.json addons/web/static/src/start.js"
				}]
			}
		}
		"ci": {
			description: "CI/CD pipelines, schemas, and automation workflows"
			title:       "CI/CD & Pipeline Infrastructure"
			root:        ".github"
			watch_paths: [".enact/**", ".github/**", "cue.mod/**"]
			depends_on:  ["root"]
			lint: "cd \"$(git rev-parse --show-toplevel)\" && cue vet ./.enact/"
		}
		"doc": {
			description: "Odoo documentation, guides, and Sphinx resources"
			title:       "Odoo Documentation"
			root:        "doc"
			watch_paths: ["doc/**"]
			depends_on:  ["root"]
		}
	}
}
