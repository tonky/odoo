package replay

let J = pipeline.#jobs

// Reusable Stage Catalog for Odoo
_stages: [
	{
		name: "preflight"
		select: [J.lint]
		fail_fast: true
		services:  "disabled"
	},
	{
		name:   "tests"
		matrix: true
		select: [J.test]
		fail_fast: false
		services:  "on_demand"
	},
]
