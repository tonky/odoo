package replay

pipeline: {
	ci: {
		no_cache: {
			labels: ["no-cache", "showcase"]
			branch_prefixes: ["showcase/"]
		}
		concurrency: {
			max_parallel_jobs: 8
		}
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
					"ubuntu-latest",
				]
				memory_mb: 32768
			}
		}
	}
	workflows: {
		ci: {
			layout:   "staged"
			services: "on_demand"
			stages:   _stages
		}
	}
}
