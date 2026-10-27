"""odoo-durations.py <dir> <odoo-bin> <args...>: runs odoo-bin, recording how long each test
class ran, as the duration maps enact shards by (`analysis.durations`): `<dir>/<addon>.json`,
`{"<file>::<Class>": {"seconds": s, "contention": c}}`, keyed as enact names the class's tests (a file target takes
the sum of its classes).

A class's time is wall time from its setUpClass to the next class's (or the suite's end):
its tests and its class fixtures, what a shard spends on it. Odoo's own stats
(`odoo.tests.stats`) time the tests alone, without setUpClass, often the larger part.

The process's time outside its test classes is no class's: it is the addon's start-up,
`{"<addon dir>": {"startup": s, "contention": c}}`, which enact counts once per shard on top of
its classes (a shard's forecast and time limit). Mostly odoo installing the addon and its
dependencies (~2-60 s) before the first class; also, between the at_install and post_install
tests, the asset bundles odoo pregenerates when the post_install suite holds an HttpCase (~8-12
s), and the shutdown.

Each entry notes the host contention it ran under (`{"seconds": s, "contention": c}`, c the
1-minute load average per CPU, time-weighted over the class): enact counts a class recorded
on a loaded host for its uncontended time, s / c above 1.

Each run updates the classes it ran and keeps the others: a shard runs a part of an
addon's tests, and shards run at once, so a write merges under a lock and replaces the map
whole. Run it through enact to record an addon's suite: `ODOO_DURATIONS=$PWD/.enact/durations enact run -c <addon>:test`
(odoo-runner.sh wraps odoo-bin in it).
"""

import atexit
import fcntl
import json
import os
import runpy
import sys
import tempfile
import time

root = os.path.realpath(os.getcwd()) + os.sep

# Per test class (`<file>::<Class>`): its addon, the seconds it ran and those seconds
# weighted by the host contention (load per CPU) they ran under.
durations: dict[str, tuple[str, float, float]] = {}
current: tuple[str, str, float, float] | None = None
cpus = (getattr(os, "process_cpu_count", None) or os.cpu_count)() or 1


def contention() -> float:
    return os.getloadavg()[0] / cpus


process_started, process_load = time.monotonic(), contention()
# The addon whose test class ran first (the job's) and its directory, with the load then.
startup: tuple[str, str, float] | None = None


def class_of(cls) -> tuple[str, str] | None:
    """The class's addon and its target id, for a test class of the repository's addons."""
    module = sys.modules.get(cls.__module__)
    path = os.path.realpath(getattr(module, "__file__", "") or "")
    parts = cls.__module__.split(".")
    if not path.startswith(root) or parts[:2] != ["odoo", "addons"] or len(parts) < 3:
        return None
    return parts[2], f"{path[len(root):]}::{cls.__qualname__}"


def addon_dir(addon: str) -> str | None:
    """The addon's directory, relative to the repository."""
    package = sys.modules.get(f"odoo.addons.{addon}")
    path = os.path.realpath(os.path.dirname(getattr(package, "__file__", "") or ""))
    return path[len(root):] if (path + os.sep).startswith(root) else None


def switch(cls) -> None:
    global current, startup
    now, load = time.monotonic(), contention()
    if current is not None:
        addon, target, started, started_load = current
        _, seconds, loaded = durations.get(target, (addon, 0.0, 0.0))
        ran = now - started
        durations[target] = (addon, seconds + ran, loaded + ran * (started_load + load) / 2)
    found = class_of(cls) if cls is not None else None
    if found is not None and startup is None and (directory := addon_dir(found[0])):
        startup = (found[0], directory, load)
    current = None if found is None else (*found, now, load)


def patch_suite() -> None:
    from odoo.tests import suite

    handle_class_setup = suite.TestSuite._handleClassSetUp
    run = suite.TestSuite.run

    def _handleClassSetUp(self, test, result):
        if type(test) is not result._previousTestClass:
            switch(type(test))
        return handle_class_setup(self, test, result)

    def run_suite(self, result, debug=False):
        try:
            return run(self, result, debug)
        finally:
            switch(None)

    suite.TestSuite._handleClassSetUp = _handleClassSetUp
    suite.TestSuite.run = run_suite


def write(out_dir: str) -> None:
    switch(None)
    by_addon: dict[str, dict[str, dict[str, float]]] = {}
    for target, (addon, seconds, loaded) in durations.items():
        by_addon.setdefault(addon, {})[target] = {
            "seconds": round(seconds, 2),
            "contention": round(loaded / seconds, 2) if seconds > 0 else 0.0,
        }
    if startup is not None:
        addon, directory, first_load = startup
        outside = time.monotonic() - process_started - sum(s for _, s, _ in durations.values())
        by_addon.setdefault(addon, {})[directory] = {
            "startup": round(max(outside, 0.0), 2),
            "contention": round((process_load + first_load + contention()) / 3, 2),
        }
    os.makedirs(out_dir, exist_ok=True)
    for addon, recorded in sorted(by_addon.items()):
        path = os.path.join(out_dir, f"{addon}.json")
        # Under a lock beside it, replaced whole: a plan reading it meanwhile (enact
        # affected beside a run) reads the old map or the new one, never a truncated one.
        with open(os.path.join(out_dir, f".{addon}.lock"), "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            try:
                with open(path) as f:
                    merged = json.loads(f.read() or "{}")
            except (FileNotFoundError, json.JSONDecodeError):
                merged = {}
            merged.update(recorded)
            fd, temp = tempfile.mkstemp(dir=out_dir, prefix=f".{addon}.json.")
            with os.fdopen(fd, "w") as f:
                json.dump(dict(sorted(merged.items())), f, indent=1)
                f.write("\n")
            os.replace(temp, path)
        print(f"odoo-durations: {len(recorded)} entries -> {path}", file=sys.stderr)


def main() -> None:
    out_dir, odoo_bin, *args = sys.argv[1:]
    atexit.register(write, os.path.abspath(out_dir))
    # odoo-bin's directory, as running it puts first; the repository's too: the next
    # recorder (odoo-footprint.py) may stand in for odoo-bin, and odoo must import here.
    sys.path[:0] = [os.path.dirname(os.path.abspath(odoo_bin)), root.rstrip(os.sep)]
    patch_suite()
    sys.argv = [odoo_bin, *args]
    runpy.run_path(odoo_bin, run_name="__main__")


if __name__ == "__main__":
    main()
