package replay

#OdooAddonBase: {
	technology: "python"
	resources: {
		cpus:      float | *1.5
		memory_mb: int | *3072
	}
	services: {
		db: {
			name:          "db"
			port:          5432
			user:          "odoo"
			database:      "test_odoo"
			template:      "test_odoo_template"
			template_init: "bash $(git rev-parse --show-toplevel)/setup/ci/post-start-postgres.sh"
		}
	}
	shards: "auto"
	lint:   string | *"[ -n '{changed_files}' ] && ruff check --config $(git rev-parse --show-toplevel)/ruff.toml {changed_files} || true"
	scoping: {
		barrels: []
		domainRoots: [...string]
		fullRunPatterns: []
		selector: {
			command:     "bin/odoo-scope targets -c {component_root} {changed_files}"
			fallback:    "none"
			format:      "lines"
			granularity: "file"
			originDir:   "."
			timeout:     60
		}
		serviceMarkers: [
			"odoo-bin",
			"odoo.tests",
			"tagged",
			"TransactionCase",
			"HttpCase",
			"SingleTransactionCase",
			"Common",
		]
		universalSymbols: []
	}
}

pipeline: {
	name:        "odoo-platform"
	description: "Odoo Modular ERP: Accelerated CI/CD Pipeline (enact + enve)"
	env: {
		PATH: "${{ github.workspace }}/bin:${{ env.PATH }}"
	}
	sparseCheckout: [
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
	sparseCheckoutHooks: [
		"bin/odoo-scope sparse -c {component_root}",
	]
	jobs: {}
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
			tags: []
		}
		schedule: []
	}
	components: {
		for name, meta in _addons {
			"\(name)": #OdooAddonBase & {
				name:                "\(name)"
				title:               string | *"Odoo Addon \(name)"
				root:                meta.dir
				dependsOnComponents: meta.depends
				watch_paths: [...string] | *["\(meta.dir)/**"]
				scoping: domainRoots: [...string] | *[meta.dir]
				if meta.has_tests {
					test: string | *"ODOO_TEST_MAX_FAILED_TESTS=1 uv run python $(git rev-parse --show-toplevel)/odoo-bin -d test_odoo_${ENACT_SHARD_INDEX:-1} --http-port=$(( 8069 + ${ENACT_SHARD_INDEX:-1} )) -i \(name) -u \(name) --test-enable --stop-after-init --test-tags $([ -n '{selected_targets}' ] && echo '{selected_targets}' | sed 's|addons/||g; s|^|/|; s| |,/|g' || echo '/\(name)')"
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
			scoping: domainRoots: [
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
			lint: "([ -n '{changed_files}' ] && ruff check --config $(git rev-parse --show-toplevel)/ruff.toml {changed_files} || true)"
			test: string | *"ODOO_TEST_MAX_FAILED_TESTS=1 uv run python $(git rev-parse --show-toplevel)/odoo-bin -d test_odoo_${ENACT_SHARD_INDEX:-1} --http-port=$(( 8069 + ${ENACT_SHARD_INDEX:-1} )) -i base -u base --test-enable --stop-after-init --test-tags /base"
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
	}
}
