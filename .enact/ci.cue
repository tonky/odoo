package replay

pipeline: {
	ci: {
		concurrency: {
			max_parallel_jobs: 8
			max_total_shards:  16
		}
		strategy: "auto"
		workers: {
			"standard": {
				available:    4
				cost_per_min: 0.008
				cpus:         2.0
				labels: [
					"ubuntu-latest",
				]
				memory_mb: 7168
			}
			"large": {
				available:    2
				cost_per_min: 0.032
				cpus:         8.0
				labels: [
					"ubuntu-latest-8",
				]
				memory_mb: 32768
			}
		}
	}
	workflows: {
		ci: {
			layout:   "staged"
			services: "on_demand"
			stages: [
				_preflightStage,
				_testStage,
			]
		}
	}
}
