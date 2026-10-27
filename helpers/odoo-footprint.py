"""odoo-footprint.py <dir> <odoo-bin> <args...>: runs odoo-bin, recording which of the
repository's functions and files each test class uses, as an enact reach map in <dir>
(`{"shared": {...}, "targets": {"<file>::<Class>": {"files": [...], "functions": {"<file>":
[...]}, "dirs": [...], "probes": [...]}}}`, what every class holds written once as `shared`, a
file per run: `enact trace pack` merges them and notes each file's layout).

A file-open trace can't tell odoo's tests apart: every installed addon's Python is imported
before the first test. This records in the process instead (enact_footprint.py, shared with
usecases/posthog): the first call of each function in a test class's run (setUpClass, its
tests, tearDownClass, the requests its HttpCase serves) joins the class's footprint, as do
the files it reads, the directories it lists, the paths it finds missing and its Python
child processes. A function is named as enact's scanner names it: `co_qualname` up to
`.<locals>` (a nested function counts as the one it is in). Code outside functions (a field
default's lambda, module and class bodies) is no function: its file joins the footprint
alone.

What serves every class is every footprint's: start-up, installing the addons (their
imports, data files and registry set-up), what runs between classes, every module's import
and the computations of the ORM's caches (`ormcache`) and `functools`' caches, which run
once, for the first class needing them. A class that starts a program the recorder can't
follow is opaque: its outcome is partial, so it runs for any change (the reasons go to
the `.stats` file beside the map). A browser (an HttpCase's tours) or wkhtmltopdf reads
nothing of the repository but what the server sends it, which the server's threads record.

`enact run` records only the classes its map lacks or holds stale: it lists them (or their
files) in $ENACT_FOOTPRINT_TARGETS, and the others run unmonitored (their imports and cache
computations are recorded still, as every footprint holds them). The map says each class's
outcome (`"outcomes": true`): one with a failed or erroring test (setUpClass and
tearDownClass included) or cut short by a stopped run is incomplete (failed), so a failing
shard lands only its passing classes' footprints; an opaque one that passed is partial.
A class with a skipped test (`skipTest`, `@skip`/`skipIf`, a class skipped whole, a
`SkipTest` from setUpClass: no Chrome, a missing program) is kept, marked as skipped on this
platform (`skipped_on`): its footprint lacks what the skipped test reads, so planning on
another platform runs it on every change. A test `--test-tags` leaves out is no skip: the
same tags leave it out on every platform.
"""

import atexit
import os
import runpy
import sys

import enact_footprint as core  # helpers/, this script's directory

root = os.path.realpath(os.getcwd()) + os.sep
# The recorders (helpers/) aren't the repository's code under test.
own = os.path.dirname(os.path.realpath(__file__)) + os.sep
# Programs that read nothing of the repository: the server sends them what they load.
QUIET = ("chrome", "chrome-headless-shell", "chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "wkhtmltopdf")
# Programs that read only the files their arguments name (`eslint --no-ignore --no-eslintrc -c <rc> <files...>`).
READERS = {"eslint": ()}

# The platform as enact names it (`skipped_on`).
PLATFORM = "linux" if sys.platform.startswith("linux") else sys.platform

failed: set[str] = set()
skipped: set[str] = set()


def wanted_targets() -> set[str] | None:
    """The classes or files to record ($ENACT_FOOTPRINT_TARGETS); None: every class."""
    listed = os.environ.get("ENACT_FOOTPRINT_TARGETS")
    if not listed:
        return None
    with open(listed) as f:
        return {line.strip() for line in f if line.strip()}


WANTED = wanted_targets()


def wanted(target: str) -> bool:
    return WANTED is None or target in WANTED or target.split("::", 1)[0] in WANTED


def switch(target: str | None) -> None:
    """Records into `target`'s footprint (none: no class runs, shared); a class not wanted
    runs unmonitored."""
    if target is None:
        core.switch(core.SHARED)
    else:
        core.switch(target if wanted(target) else None)


def mark(into: set[str]) -> None:
    """Notes the class running now (none between classes) in `into`."""
    target = core.current_key
    if target is not None and target != core.SHARED:
        into.add(target)


def mark_failed() -> None:
    mark(failed)


# Files whose test classes depend on an earlier class in the same file having run in the
# same process (base's Test02ClassCleanupsCheck asserts `Test01ClassCleanups.executed`), so
# they must be recorded and sharded as a single file target, never split by class.
WHOLE_FILE_TARGETS = {"odoo/addons/base/tests/test_test_suite.py"}


def target_of(cls) -> str | None:
    module = sys.modules.get(cls.__module__)
    rel = core.relative(getattr(module, "__file__", "") or "")
    if not rel:
        return None
    return rel if rel in WHOLE_FILE_TARGETS else f"{rel}::{cls.__qualname__}"


def patch_ormcache() -> None:
    """An `ormcache` miss computes for every later class reading the registry's cache."""
    import gc

    from odoo.tools import cache

    bind = cache.ormcache.__call__

    def __call__(self, method):
        lookup = bind(self, method)
        self.method = core.extent(self.method)
        return lookup

    cache.ormcache.__call__ = __call__
    for obj in gc.get_objects():  # bound before this patch (none, as odoo is laid out today)
        if isinstance(obj, cache.ormcache) and hasattr(obj, "method"):
            obj.method = core.extent(obj.method)


def patch_suite() -> None:
    from odoo.tests import result as results
    from odoo.tests import suite

    handle_class_setup = suite.TestSuite._handleClassSetUp
    run = suite.TestSuite.run
    add_error = results.OdooTestResult.addError
    add_failure = results.OdooTestResult.addFailure
    add_skip = results.OdooTestResult.addSkip
    suite_results: set[results.OdooTestResult] = set()

    # A retried test's soft failures don't count: its last try decides. A class's
    # tearDownClass runs before the next class is switched to, so it counts for its own.
    # Ignore synthetic OdooTestResult() instances constructed inside test_test_suite.py.
    def addError(self, test, err):
        if self in suite_results and not self._soft_fail:
            mark_failed()
        return add_error(self, test, err)

    def addFailure(self, test, err):
        if self in suite_results and not self._soft_fail:
            mark_failed()
        return add_failure(self, test, err)

    # A class's skip: a test's, or setUpClass's (the class's every test).
    def addSkip(self, test, reason):
        if self in suite_results:
            mark(skipped)
        return add_skip(self, test, reason)

    def _handleClassSetUp(self, test, result):
        if type(test) is not result._previousTestClass:
            switch(target_of(type(test)) or core.SHARED)
        return handle_class_setup(self, test, result)

    def run_suite(self, result, debug=False):
        suite_results.add(result)
        try:
            return run(self, result, debug)
        finally:
            if result.shouldStop:
                mark_failed()  # cut short: its later tests never ran
            switch(None)

    suite.TestSuite._handleClassSetUp = _handleClassSetUp
    suite.TestSuite.run = run_suite
    results.OdooTestResult.addError = addError
    results.OdooTestResult.addFailure = addFailure
    results.OdooTestResult.addSkip = addSkip


def write(out_dir: str) -> None:
    shared, entries = core.finish()
    targets, opaque = {}, {}
    for target, (entry, why) in sorted(entries.items()):
        if why:
            opaque[target] = why
        if target in failed:
            entry["outcome"] = {"incomplete": {"exit": 1}}
        elif why:
            entry["outcome"] = "partial"
        if target in skipped:
            entry["skipped_on"] = [PLATFORM]
        targets[target] = entry
    if not targets:
        return
    prefix = os.environ.get("PGDATABASE", "odoo") + "-"
    out = core.write_map(out_dir, prefix, shared, targets)
    core.write_stats(out, len(targets), opaque)
    marked = len(skipped & targets.keys())
    print(f"odoo-footprint: {len(targets)} test classes ({len(opaque)} opaque, {marked} skipping) -> {out}", file=sys.stderr)


def main() -> None:
    out_dir, odoo_bin, *args = sys.argv[1:]
    core.start(root, recorders=(own,), quiet_programs=QUIET, readers=READERS)
    atexit.register(write, os.path.abspath(out_dir))
    sys.path.insert(0, os.path.dirname(os.path.abspath(odoo_bin)))
    patch_ormcache()
    patch_suite()
    sys.argv = [odoo_bin, *args]
    runpy.run_path(odoo_bin, run_name="__main__")


if __name__ == "__main__":
    main()
