package replay

pipeline: analysis: {
	dependencies: {
		manifests:       [{file: "__manifest__.py", keys: ["depends", "auto_install"]}]
		import_prefixes: ["odoo.addons."]
		asset_prefixes:  ["@"]
	}
	durations: [".enact/durations/*.json"]
}
