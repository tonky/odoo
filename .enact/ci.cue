package replay

let J = pipeline.#jobs

_stages: [
	{name: "preflight", select: [J.lint], fail_fast: true, services: "disabled"},
	{name: "tests", matrix: true, select: [J.test], fail_fast: false, services: "on_demand"},
]

pipeline: {
	analysis: {
		dependencies: {
			manifests:       [{file: "__manifest__.py", keys: ["depends", "auto_install"]}]
			import_prefixes: ["odoo.addons."]
			asset_prefixes:  ["@"]
		}
		durations: [".enact/durations/*.json"]
		recorders: "enact_footprint.py": "7"
	}
	caches: "templates": {
		name:    "Postgres template dumps"
		paths:   [".enact/state/templates"]
		version: "1"
		used_by: jobs: ["test", "pylint"]
	}
	ci: {
		concurrency: max_parallel_jobs: 8
		diagnostic_paths: ["${{ runner.temp }}/odoo_tests/**/*.png", "${{ runner.temp }}/odoo_tests/*/chrome_logs/*"]
		workers: {
			"standard": {
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"]
				tier: "dedicated", available: 1, cost_per_min: 0.010
				pool: {
					cpus: 14, memory_mb: 28672
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
						"tonky-ci-l": {cpus: 6, memory_mb: 13312}
					}
				}
			}
			"arm64": {
				labels: ["self-hosted", "Linux", "ARM64", "tonky-ci"]
				tier: "dedicated", available: 1, cost_per_min: 0.008
				pool: {
					cpus: 4, memory_mb: 8192
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
					}
				}
			}
		}
	}
	workflows: {
		ci:    {layout: "staged", services: "on_demand", stages: _stages}
		local: {layout: "staged", services: "on_demand", stages: _stages}
		nightly: {
			layout: "staged", scope: "all"
			triggers: {schedule: ["0 3 * * *"], workflow_dispatch: true}
			stages: [{
				name: "pylint", matrix: true, services: "on_demand"
				select: [{component: "test_lint", job: "pylint"}]
			}]
		}
	}
}
