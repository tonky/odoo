package replay

pipeline: {
	// Postgres template dumps and filestores:
	// post-start-postgres.sh writes both into .enact/state/templates.
	caches: "templates": {
		name:    "Postgres template dumps"
		paths:   [".enact/state/templates"]
		version: "1"
		used_by: jobs: ["test", "pylint"]
	}
	ci: {
		concurrency: {
			max_parallel_jobs: 8
		}
		// The fork's jobs run on the user's tonky-ci fleet, one fresh container per job (enact's
		// .enact/workflows.cue workers `tonky-ci`, `tonky-ci-arm64`): stage jobs on the x86_64
		// slots, matrix rows on the cheapest slot they fit, so small ones take the arm64 slot.
		workers: {
			"standard": {
				labels: ["self-hosted", "Linux", "X64", "tonky-ci"]
				tier:         "dedicated"
				available:    2
				cost_per_min: 0.010
				cpus:         6
				memory_mb:    13312
			}
			"arm64": {
				labels: ["self-hosted", "Linux", "ARM64", "tonky-ci"]
				tier:         "dedicated"
				available:    1
				cost_per_min: 0.008
				cpus:         4
				memory_mb:    8192
			}
		}
	}
	workflows: {
		ci: {
			layout:   "staged"
			services: "on_demand"
			stages:   _stages
		}
		// What is too slow for every change: the whole tree's pylint checks (test_lint's
		// TestPyLint), which a change's lint job runs on its own Python files.
		nightly: {
			layout: "staged"
			scope:  "all"
			triggers: {
				schedule: ["0 3 * * *"]
				workflow_dispatch: true
			}
			stages: [{
				name:   "pylint"
				matrix: true
				select: [{component: "test_lint", job: "pylint"}]
				services: "on_demand"
			}]
		}
	}
}
