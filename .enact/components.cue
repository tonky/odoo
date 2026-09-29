package replay

import "enact.dev/schema"

// How an addon's `test` job picks its tests: a changed Python file by import analysis,
// then odoo-scope's targets; a view, asset or data change runs the addon whole.
#OdooTargetScope: schema.#TargetScope & {
	fallback: "all"
	hooks: {
		post: [
			"bin/odoo-scope targets -c {component_root} {changed_files}",
		]
	}
}

#OdooAddonBase: schema.#Component & {
	technology: "python"
	resources: {
		cpus:      float | *1.5
		memory_mb: int | *3072
	}
	services: {
		db: schema.#PostgresService & {
			name:     "db"
			user:     "odoo"
			database: "test_odoo"
			enact: {
				template:      "test_odoo_template"
				template_init: "bash $(git rev-parse --show-toplevel)/setup/ci/post-start-postgres.sh"
			}
		}
	}
	shards: "auto"
	lint:   string | *"[ -n '{changed_files}' ] && ruff check --config $(git rev-parse --show-toplevel)/ruff.toml {changed_files} || true"
	workspace_scope: {
		include_dependencies: true
	}
	scoping: {
		barrels: []
		domain_roots: [...string]
		full_run_patterns: []
		service_markers: [
			"odoo-bin",
			"odoo.tests",
			"tagged",
			"TransactionCase",
			"HttpCase",
			"SingleTransactionCase",
			"Common",
		]
		universal_symbols: []
	}
}

pipeline: schema.#Pipeline & {
	name:        "odoo-platform"
	description: "Odoo Modular ERP: Accelerated CI/CD Pipeline (enact + enve)"
	env: {}
	workspace_scope: {
		include: [
			"enve.cue",
			"enve.lock",
			"odoo-bin",
			"requirements.txt",
			"setup.py",
			"setup.cfg",
			"pyproject.toml",
			"Justfile",
			"oxlint.json",
			"ruff.toml",
			"uv.lock",
			".enact",
			"bin",
			"odoo",
			"setup",
			"addons/bus",
			"addons/rpc",
			"addons/web",
			"addons/http_routing",
			"addons/web_tour",
			"addons/iap",
		]
		hooks: {
			post: [
				"bin/odoo-scope sparse -c {component_root}",
			]
		}
	}
	triggers: {
		pull_request: {
			branches: [
				"master",
				"19.0",
				"saas-19.4",
				"perf/ci-modernization",
			]
			paths: []
		}
		push: {
			branches: [
				"master",
				"19.0",
				"saas-19.4",
				"perf/ci-modernization",
			]
			paths: [
				"**/*",
			]
		}
		schedule: []
	}
	components: {
		for addon, meta in _addons {
			("\(addon)"): #OdooAddonBase & {
				name:                  "\(addon)"
				title:                 string | *"Odoo Addon \(addon)"
				root:                  meta.dir
				depends_on:            meta.depends
				watch_paths: [...string] | *["\(meta.dir)/**"]
				if meta.has_tests {
					target_scope: #OdooTargetScope & {
						default_target: "/\(addon)"
						rules: [
							{
								match: ["\(meta.dir)/**/*.py"]
								engine: "python"
							},
							{
								match: ["\(meta.dir)/**/*.js", "\(meta.dir)/**/*.xml", "\(meta.dir)/**/*.csv"]
								action: "full_component"
							},
						]
					}
					test: string | *"ODOO_TEST_MAX_FAILED_TESTS=1 uv run python $(git rev-parse --show-toplevel)/odoo-bin -d {shard_db} --http-port=$(( 8069 + ${ENACT_SHARD_INDEX:-1} )) --db_host=127.0.0.1 --db_port=5432 --db_user=odoo --db_password=odoo -i \(addon) -u \(addon) --test-enable --stop-after-init --test-tags {targets_tags}"
				}
			}
		}

		"base": {
			description: "Odoo core kernel, ORM, data models, security, and base addon"
			title:       "Odoo Base Framework & Core Models"
			resources: {
				cpus:      2.0
				memory_mb: 4096
			}
			root: "odoo/addons/base"
			scoping: domain_roots: [
				"odoo/addons/base",
				"odoo",
			]
			tags: [
				"core",
				"base",
				"backend",
			]
			watch_paths: [
				"odoo/addons/base/**",
				"odoo/**",
			]
			depends_on: [
				"root",
			]
			lint: "([ -n '{changed_files}' ] && ruff check --config $(git rev-parse --show-toplevel)/ruff.toml {changed_files} || true)"
			test: "ODOO_TEST_MAX_FAILED_TESTS=1 uv run python $(git rev-parse --show-toplevel)/odoo-bin -d test_odoo_${ENACT_SHARD_INDEX:-1} --http-port=$(( 8069 + ${ENACT_SHARD_INDEX:-1} )) --db_host=127.0.0.1 --db_port=5432 --db_user=odoo --db_password=odoo -i base -u base --test-enable --stop-after-init --test-tags {targets_tags}"
		}
		"web": {
			description: "Odoo web client, owl components, and UI assets"
			title:       "Odoo Web Client & Owl UI Engine"
			lint:        "[ -n '{changed_files}' ] && (ruff check --config $(git rev-parse --show-toplevel)/ruff.toml {changed_files} || true; oxlint -c $(git rev-parse --show-toplevel)/oxlint.json {changed_files} || true) || true"
			tags: [
				"web",
				"ui",
			]
		}
		"mail": {
			description: "Odoo discussions, activities, and communication gateways"
			title:       "Odoo Discussions & Activity Gateway"
			tags: [
				"mail",
				"discuss",
			]
		}
		"account": {
			description: "Odoo Invoicing and Accounting core framework"
			title:       "Odoo Invoicing & Financial Accounting"
			resources: {
				cpus:      2.0
				memory_mb: 4096
			}
			tags: [
				"account",
				"invoicing",
			]
		}
		"sale": {
			description: "Odoo Sales quotations, pricing rules, and sales orders"
			title:       "Odoo Sales & Quotation Management"
			tags: [
				"sale",
				"crm",
			]
		}
		"stock": {
			description: "Odoo Inventory, delivery orders, and warehouse management"
			title:       "Odoo Inventory & Warehouse Logistics"
			tags: [
				"stock",
				"inventory",
			]
		}
		"root": {
			description: "Odoo platform entrypoints, runtime dependencies, packaging, and tooling"
			title:       "Odoo Platform Entrypoints & Packaging"
			root:        "."
			watch_paths: [
				".gitignore",
				".weblate.json",
				"CONTRIBUTING.md",
				"COPYRIGHT",
				"Justfile",
				"LICENSE",
				"MANIFEST.in",
				"README.md",
				"SECURITY.md",
				"enve.cue",
				"enve.lock",
				"odoo-bin",
				"oxlint.json",
				"pyproject.toml",
				"replay-runtime.json",
				"requirements.txt",
				"ruff.toml",
				"setup.cfg",
				"setup.py",
				"uv.lock",
				"setup/**",
				"debian/**",
				"bin/**",
				"tools/**",
			]
			lint: "([ -n '{changed_files}' ] && ruff check --config $(git rev-parse --show-toplevel)/ruff.toml {changed_files} || true)"
		}
		"ci": {
			description: "CI/CD pipelines, schemas, and automation workflows"
			title:       "CI/CD & Pipeline Infrastructure"
			root:        ".github"
			watch_paths: [
				".enact/**",
				".github/**",
				"cue.mod/**",
			]
			lint: "cue vet .enact/... 2>/dev/null || true"
		}
		"doc": {
			description: "Odoo documentation, guides, and Sphinx resources"
			title:       "Odoo Documentation"
			root:        "doc"
			watch_paths: [
				"doc/**",
			]
			lint: "true"
		}
	}
}
