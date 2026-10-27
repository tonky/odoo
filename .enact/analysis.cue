package replay

// Odoo conventions: addon manifests declare dependencies, and `odoo.addons.<name>` imports
// and `@<name>/...` asset specifiers reference addons.
pipeline: analysis: {
	dependencies: {
		manifests: [{file: "__manifest__.py", keys: ["depends", "auto_install"]}]
		import_prefixes: ["odoo.addons."]
		asset_prefixes: ["@"]
	}
}

// Per-test-class seconds, recorded by running an addon's tests through enact with
// ODOO_DURATIONS (helpers/odoo-durations.py: `ODOO_DURATIONS=$PWD/.enact/durations enact run
// -c <addon>:test`). Shards are balanced by them, and a shard's step may run a ratio of its
// recorded estimate (600 s without one). Before them, test_lint's TestPyLint (minutes, one
// test) was killed at 90 s against its seconds-long peers.
// Provisional: recorded 2026-10-06 on a host loaded ~3x its cores, so inflated; re-record on
// a quiet host before deriving timeouts or shard counts from them.
// One file per recorded addon (`.enact/*.json` is git-ignored as run output).
pipeline: analysis: durations: [".enact/durations/*.json"]

// The footprint recorder's version (enact_footprint.py writes `"recorder"`): bumping it
// re-records only the footprints it wrote.
pipeline: analysis: recorders: "enact_footprint.py": "5"
