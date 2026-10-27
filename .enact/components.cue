package replay

import (
	"list"
	"strings"

	"enact.dev/schema"
)

// How an addon's `test` job picks its tests: a changed Python file by import analysis,
// then odoo-scope's targets; a view, asset or data change runs the addon whole.
#OdooTargetScope: schema.#TargetScope & {
	fallback: "all"
}

// Was `[ -n '{changed_files}' ] && ruff check {changed_files} || true`: ruff read every changed
// file as Python (XML, JS) and `|| true` passed whatever happened, a missing ruff included.
#OdooLint: schema.#Task & {
	command: "bash \"$(git rev-parse --show-toplevel)/helpers/odoo-lint.sh\" {changed_files}"
	filter: {
		include: ["**/*.py", "**/*.js"]
		on_empty: "skip"
	}
}

#OdooAddonBase: schema.#Component & {
	technology: "python"
	resources: {
		cpus:      float | *1.0
		memory_mb: int | *2048
	}
	services: {
		db: schema.#PostgresService & {
			name:     "db"
			// As enve.cue declares it. Each shard's database is forked from the template.
			user:     "odoo"
			database: "postgres"
			port:     5436
			// Each addon's closure template (below).
			enact: {
				template:      string
				template_init: string
				template_inputs: {
					include: [...string]
					exclude: [...string]
				}
			}
		}
	}
	// Each changed Python or JavaScript file by its linter (helpers/odoo-lint.sh); none, no job.
	lint: schema.#SlotTask | *#OdooLint
	workspace_scope: {
		include_dependencies: true
	}
	// No `service_markers`: every odoo test runs through odoo-bin against a database. A test
	// file naming none of the old markers (sale_project_stock_account's
	// test_analytics_reinvoice.py, whose class comes from another addon) ran with no db.
	scoping: domain_roots: [...string]
}

// Generated per addon (addons.cue); `not_run` only where some test file runs no test, `template`
// only where a closure template fits (resolve_sparse_checkout.py TEMPLATE_SEEDS).
_addons: [string]: {
	not_run:       *[] | [...schema.#NotRun]
	known_not_run: *[] | [...schema.#NotRun]
	template:      *"base" | string
}

// Generated per template (addons.cue): the dirs of the addons its init installs.
_templates: [string]: addon_dirs: [...string]

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
			"cue.mod",
			"bin",
			"helpers",
			"odoo",
			"setup",
			"addons/api_doc",
			"addons/auth_passkey",
			"addons/auth_totp",
			"addons/base_import",
			"addons/base_import_module",
			"addons/base_setup",
			"addons/bus",
			"addons/html_editor",
			"addons/http_routing",
			"addons/iap",
			"addons/rpc",
			"addons/web",
			"addons/web_tour",
			"addons/web_unsplash",
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
			]
			paths: []
		}
		push: {
			branches: [
				"master",
				"19.0",
				"saas-19.4",
				"perf/ci-showcase",
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
				// Defaults, which the components below (base) override. A plain list conflicts
				// with theirs (`cue vet`: incompatible list lengths), though `enve cue` accepted it.
				depends_on: [...string] | *meta.depends
				watch_paths: [...string] | *["\(meta.dir)/**"]
				// The job's database is a fork of the largest closure template its install
				// contains: it installs only the addons that template lacks.
				services: db: enact: {
					template:      "test_odoo_tpl_\(meta.template)"
					template_init: "bash setup/ci/post-start-postgres.sh \(meta.template)"
					// What the template is built from: odoo's core, the addons the init installs
					// and the scripts it runs. A change to one rebuilds it (and its dump); tests
					// and addons it doesn't install don't.
					template_inputs: {
						include: list.Concat([[
							"odoo-bin",
							"helpers/odoo-runner.sh",
							"helpers/odoo-env.sh",
							"odoo/**",
						], _templates[meta.template].addon_dirs])
						exclude: ["**/tests/**", "odoo/addons/test_*/**"]
					}
				}
				if meta.has_tests {
					// Only a test job shards; an addon without `tests/` has none.
					shards: "auto"
					target_scope: #OdooTargetScope & {
						default_target: "/\(addon)"
						// The modules odoo's loader takes tests from, not every test-named file
						// (`models/test_models.py` defines test models). A default: test_lint narrows it.
						tests: [...string] | *[
							"\(meta.dir)/tests/**/test_*.py",
							"\(meta.dir)/migrations/tests/test_*.py",
							"\(meta.dir)/upgrades/tests/test_*.py",
						]
						// Test files running no test (resolve_sparse_checkout.py
						// `not_run_tests`): selected alone, odoo ran 0 tests and the shard failed.
						not_run: list.Concat([meta.not_run, meta.known_not_run])
						rules: [
							{
								match: ["addons/**/*.py", "odoo/**/*.py"]
								engine: "python"
							},
							{
								match: ["\(meta.dir)/**/*.js", "\(meta.dir)/**/*.xml", "\(meta.dir)/**/*.csv"]
								action: "full_component"
							},
						]
					}
					// odoo-runner.sh records (odoo-footprint.py).
					recorder: "own"
					// Known upstream failures (known_failures.cue) are left out by odoo's own
					// exclusion tags. No ODOO_TEST_MAX_FAILED_TESTS=1 on base: TestRunnerLogging
					// (test_test_suite.py) feeds 1 simulated error to a fresh OdooTestResult(),
					// which at max=1 logs odoo.tests.result's halt message and fails its assertion.
					let excluded = strings.Join([for f in meta.known_failures {",-/\(addon):\(f.test)"}], "")
					let max_failed = [if addon != "base" {"ODOO_TEST_MAX_FAILED_TESTS=1 "}, ""][0]
					test: schema.#SlotTask | *"\(max_failed)bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh -i \(addon) -u \(addon) --test-enable --stop-after-init --test-tags {targets_tags}\(excluded)"
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
		}
		"web": {
			description: "Odoo web client, owl components, and UI assets"
			title:       "Odoo Web Client & Owl UI Engine"
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
		"test_lint": {
			// TestPyLint (test_pylint.py) lints the whole repository in one test: 200-560 s.
			// A change's own Python files get its checks in the lint job (helpers/odoo-pylint.sh),
			// the whole tree in the nightly workflow (ci.cue), as this `pylint` job. The test job
			// runs test_lint's other tests: its suite leaves test_pylint.py out, and its tags leave out
			// TestPyLint, which a change to the file itself selects.
			target_scope: tests: [
				"odoo/addons/test_lint/tests/test_[!p]*.py",
				"odoo/addons/test_lint/tests/test_p[!y]*.py",
			]
			recorder: "own"
			test: "ODOO_TEST_MAX_FAILED_TESTS=1 bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh -i test_lint -u test_lint --test-enable --stop-after-init --test-tags {targets_tags},-/test_lint:TestPyLint"
			jobs: pylint: tasks: [{
				name:    "TestPyLint"
				command: "bash $(git rev-parse --show-toplevel)/helpers/odoo-shard.sh -i test_lint -u test_lint --test-enable --stop-after-init --test-tags /test_lint:TestPyLint"
				// A job without recorded durations of its own gets 600 s, which TestPyLint nears
				// on a loaded host (450-560 s). Kept until its durations are recorded on a quiet
				// host. CI's job limit (`timeout-minutes: 15`) is the lower of the two there.
				timeout: "20m"
			}]
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
				"requirements.txt",
				"ruff.toml",
				"setup.cfg",
				"setup.py",
				"uv.lock",
				"setup/**",
				"helpers/**",
				"debian/**",
				"bin/**",
				// The pipeline and its CI: what every job runs from.
				".enact/**",
				".github/**",
				"cue.mod/**",
			]
			lint: #OdooLint
		}
		"ci": {
			description: "CI/CD pipelines, schemas, and automation workflows"
			title:       "CI/CD & Pipeline Infrastructure"
			root:        ".github"
			// Checks the pipeline, which `root` owns: runs on every change to it.
			watch_paths: [
				".enact/**",
				".github/**",
				"cue.mod/**",
			]
			depends_on: ["root"]
			// The pipeline as cue evaluates it (enact evaluates with `enve cue`, which accepted a
			// conflict cue refuses). Was `cue vet .enact/... 2>/dev/null || true`: no cue in the
			// env, and the pattern isn't a package path, so it never checked anything.
			lint: "cd \"$(git rev-parse --show-toplevel)\" && cue vet ./.enact/"
		}
		"doc": {
			description: "Odoo documentation, guides, and Sphinx resources"
			title:       "Odoo Documentation"
			root:        "doc"
			watch_paths: [
				"doc/**",
			]
			depends_on: ["root"]
		}
	}
}
