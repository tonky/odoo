package replay

// Odoo conventions: addon manifests declare dependencies, `odoo.addons.<name>` imports
// and `@<name>/...` asset specifiers reference addons, models inherit via `_inherit`,
// and `odoo.addons` spans two directories.
pipeline: analysis: {
	dependencies: {
		manifests: [{file: "__manifest__.py", keys: ["depends", "auto_install"]}]
		import_prefixes: ["odoo.addons."]
		asset_prefixes: ["@"]
	}
	python: {
		module_markers: ["__manifest__.py", "__openerp__.py"]
		// `odoo.addons.<addon>` is looked up along the addons path: Odoo's own addons,
		// then the repository's.
		namespaces: [{module: "odoo.addons", dirs: ["odoo/addons", "addons"]}]
		// Each test process installs one addon's `depends` closure, then what that
		// auto-installs: installing an addon imports its package, registering what it
		// defines, and loads its data files; the runner imports every installed addon's
		// tests package. `base`, `rpc` and `web` load server-wide.
		plugins: {
			namespace:    "odoo.addons"
			manifest:     "__manifest__.py"
			depends:      "depends"
			auto_install: "auto_install"
			data: ["data", "demo", "init_xml"]
			tests: ["tests"]
			always: ["base", "rpc", "web"]
		}
		loads: [
			{file: "odoo/modules/module.py", function: "load_openerp_module", loads: "plugins"
			 reason: "the registry imports the addons the process installs"},
			{file: "odoo/tests/loader.py", loads: "plugins"
			 reason: "the runner imports the installed addons' tests and upgrade packages"},
			{file: "addons/base_setup/controllers/kpi.py", function: "_get_kpi_providers"
			 loads: "plugins", reason: "the KPI summary imports installed addons' providers"},
			{file: "addons/account/models/ir_module.py"
			 function: "IrModuleModule._compute_account_templates"
			 loads: ["odoo.addons.l10n_*.models", "odoo.addons.account.models"]
			 reason: "chart templates are read from the chart modules, installed or not"},
			{file: "odoo/modules/module.py", function: "UpgradeHook.load_module"
			 loads: ["odoo.upgrade.*"], reason: "legacy migrations names alias `odoo.upgrade`"},
			{file: "odoo/modules/module.py", function: "check_python_external_dependency"
			 loads: [], reason: "manifests' external Python dependencies are installed packages"},
			{file: "odoo/addons/base/models/ir_qweb.py", function: "IrQweb._debug_trace"
			 loads: [], reason: "`t-debug` loads an installed debugger"},
			{file: "odoo/tools/pdf/__init__.py"
			 loads: ["odoo.tools.pdf._pypdf2_2", "odoo.tools.pdf._pypdf", "odoo.tools.pdf._pypdf2_1"]
			 reason: "the first pypdf backend importable"},
		]
		entities: {
			track_models:   true
			track_fields:   true
			qualify_fields: true
			model_attributes: ["_name", "_inherit"]
		}
		inheritance: {
			globs: ["addons/**/*.py", "odoo/addons/**/*.py"]
			model_attribute:   "_name"
			inherit_attribute: "_inherit"
			max_depth:         4
		}
		data: {
			xml: [{globs: ["**/*.xml"], extract: ["record@model", "field@name", "template@id"]}]
			csv: [{globs: ["**/security/*.csv", "**/*access*.csv"], columns: ["model_id:id"], strip_prefix: "model_"}]
		}
		references: globs: ["**/*.py", "**/*.xml"]
		tests: conventions: [
			"{module}/tests/test_{stem}.py",
			"{module}/tests/test_{stem}_*.py",
			"{module}/tests/test_*.py",
			"{module}/tests/test_tour.py",
			"{module}/tests/test_ui*.py",
		]
	}
}
