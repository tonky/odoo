package replay

// Reusable Stage Catalog for Odoo
_preflightStage: {
	name:      "preflight"
	tasks:     ["lint", "style", "security"]
	fail_fast: true
	services:  "disabled"
}

_testStage: {
	name:      "tests"
	tasks:     ["test", "unit"]
	fail_fast: false
	services:  "on_demand"
}
