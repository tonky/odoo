package replay

import (
	"list"
	"strings"

	"enact.dev/schema"
)

#OdooTargetScope: schema.#TargetScope & {fallback: "all"}

#OdooLint: schema.#Task & {
	command: "bash \"$(git rev-parse --show-toplevel)/helpers/odoo-lint.sh\" {changed_files}"
	filter: {include: ["**/*.py", "**/*.js"], on_empty: "skip"}
}

#OdooAddonBase: schema.#Component & {
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
	lint:            schema.#SlotTask | *#OdooLint
	workspace_scope: include_dependencies: true
	scoping: domain_roots: [...string]
}

_addons: [string]: {
	not_run:       *[] | [...schema.#NotRun]
	known_not_run: *[] | [...schema.#NotRun]
	template:      *"base" | string
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
		hooks: post: ["bin/odoo-scope sparse -c {component_root}"]
	}
	triggers: {
		pull_request: {branches: ["master", "19.0", "saas-19.4"], paths: []}
		push: {branches: ["master", "19.0", "saas-19.4", "perf/ci-showcase"], paths: ["**/*"]}
		schedule: []
	}
	components: {
		for addon, meta in _addons {
			("\(addon)"): #OdooAddonBase & {
				name:        "\(addon)"
				title:       string | *"Odoo Addon \(addon)"
				root:        meta.dir
				depends_on:  [...string] | *meta.depends
				watch_paths: [...string] | *["\(meta.dir)/**"]
				services: db: enact: {
					template:      "test_odoo_tpl_\(meta.template)"
					template_init: "bash setup/ci/post-start-postgres.sh \(meta.template)"
					template_inputs: {
						include: list.Concat([[
							"odoo-bin", "helpers/odoo-runner.sh", "helpers/odoo-env.sh",
							"helpers/odoo-manifests.sh", "odoo/**",
						], _templates[meta.template].addon_dirs])
						exclude: ["**/tests/**", "odoo/addons/test_*/**"]
					}
				}
				if meta.has_tests {
					shards: "auto"
					target_scope: #OdooTargetScope & {
						default_target: "/\(addon)"
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
					let excluded = strings.Join([for f in meta.known_failures {",-/\(addon):\(f.test)"}], "")
					let max_failed = [if addon != "base" {"ODOO_TEST_MAX_FAILED_TESTS=1 "}, ""][0]
					test: schema.#SlotTask | *"\(max_failed)bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh -i \(addon) -u \(addon) --test-enable --stop-after-init --test-tags {targets_tags}\(excluded)"
				}
			}
		}

		"base": {
			description: "Odoo core kernel, ORM, data models, security, and base addon"
			title:       "Odoo Base Framework & Core Models"
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
			tags:        ["web", "ui"]
		}
		"mail": {
			description: "Odoo discussions, activities, and communication gateways"
			title:       "Odoo Discussions & Activity Gateway"
			tags:        ["mail", "discuss"]
		}
		"account": {
			description: "Odoo Invoicing and Accounting core framework"
			title:       "Odoo Invoicing & Financial Accounting"
			resources:   {cpus: 2.0, memory_mb: 4096}
			tags:        ["account", "invoicing"]
		}
		"sale": {
			description: "Odoo Sales quotations, pricing rules, and sales orders"
			title:       "Odoo Sales & Quotation Management"
			tags:        ["sale", "crm"]
		}
		"stock": {
			description: "Odoo Inventory, delivery orders, and warehouse management"
			title:       "Odoo Inventory & Warehouse Logistics"
			tags:        ["stock", "inventory"]
		}
		"test_lint": {
			target_scope: tests: [
				"odoo/addons/test_lint/tests/test_[!p]*.py",
				"odoo/addons/test_lint/tests/test_p[!y]*.py",
			]
			recorder: "own"
			test: "ODOO_TEST_MAX_FAILED_TESTS=1 bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh -i test_lint -u test_lint --test-enable --stop-after-init --test-tags {targets_tags},-/test_lint:TestPyLint"
			jobs: pylint: tasks: [{
				name:    "TestPyLint"
				command: "bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh -i test_lint -u test_lint --test-enable --stop-after-init --test-tags /test_lint:TestPyLint"
				timeout: "20m"
			}]
		}
		"root": {
			description: "Odoo platform entrypoints, runtime dependencies, packaging, and tooling"
			title:       "Odoo Platform Entrypoints & Packaging"
			root:        "."
			watch_paths: [
				".gitignore", ".weblate.json", "CONTRIBUTING.md", "COPYRIGHT", "Justfile",
				"LICENSE", "MANIFEST.in", "README.md", "SECURITY.md", "enve.cue", "enve.lock",
				"odoo-bin", "oxlint.json", "pyproject.toml", "requirements.txt", "ruff.toml",
				"setup.cfg", "setup.py", "uv.lock", "setup/**", "helpers/**", "debian/**",
				"bin/**", ".enact/**", ".github/**", "cue.mod/**",
			]
			lint: #OdooLint
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
