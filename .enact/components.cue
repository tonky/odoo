package replay

#OdooAddonBase: {
	technology: "python"
	resources: {
		cpus:      float | *1.5
		memory_mb: int | *3072
	}
	services: {
		db: {
			name:     "db"
			port:     5432
			database: "test_odoo"
			template: "test_odoo_template"
		}
	}
	shards: "auto"
	lint:   string | *"[ -n '{changed_files}' ] && ruff check --config $(git rev-parse --show-toplevel)/ruff.toml {changed_files} || true"
	scoping: {
		barrels: []
		domainRoots: [...string]
		fullRunPatterns: []
		selector: {
			command:     "enact scope -t python {changed_files} | grep -E '^{component_root}/' || true"
			fallback:    "all"
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
		"python setup/ci/resolve_sparse_checkout.py --component {component_root} --dirs-only",
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
					test: string | *"uv run python $(git rev-parse --show-toplevel)/odoo-bin -d test_odoo_${ENACT_SHARD_INDEX:-1} -i \(name) -u \(name) --test-enable --stop-after-init --no-http $([ -n '{selected_targets}' ] && echo --test-tags $(echo '{selected_targets}' | sed 's|^|/|; s| |,/|g'))"
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
			lint: "python $(git rev-parse --show-toplevel)/setup/ci/resolve_sparse_checkout.py --check && ([ -n '{changed_files}' ] && ruff check --config $(git rev-parse --show-toplevel)/ruff.toml {changed_files} || true)"
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
