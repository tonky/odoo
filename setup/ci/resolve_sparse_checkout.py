#!/usr/bin/env python3
# ruff: noqa: T201, BLE001
"""
Automated Odoo Sparse Checkout Dependency Resolver.

Extracts transitive dependencies from:
1. Module manifests (__manifest__.py: 'depends')
2. Test imports (tests/**/*.py: from odoo.addons.<name> ...)
3. Web assets & tour dependencies (static/src/**/*.js: '@<name>/...')

Can check or synchronize .enact/components.cue automatically.
"""

import argparse
import ast
import glob
import multiprocessing
import os
import re
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path


def _walk_files_str(root: str, suffix: str) -> list[str]:
    out: list[str] = []
    stack = [root]
    while stack:
        curr = stack.pop()
        try:
            with os.scandir(curr) as it:
                for entry in it:
                    if entry.is_dir(follow_symlinks=False):
                        stack.append(entry.path)
                    elif entry.name.endswith(suffix):
                        out.append(entry.path)
        except OSError:
            pass
    out.sort()
    return out


def _has_prefixed_py(directory: Path, prefix: str = "test_") -> bool:
    try:
        with os.scandir(directory) as it:
            return any(
                e.name.startswith(prefix) and e.name.endswith(".py") and e.is_file()
                for e in it
            )
    except OSError:
        return False


def unparseable(path: Path, error: SyntaxError) -> SystemExit:
    """A file this Python can't parse: skipping it would drop its dependencies from the closure
    (Python 3.9 silently lost a test's import of a 3.12-syntax module)."""
    version = ".".join(map(str, sys.version_info[:3]))
    return SystemExit(
        f"❌ Python {version} can't parse {path}: {error}. "
        "Run with the repository's Python: enve run -- python setup/ci/resolve_sparse_checkout.py",
    )


def get_manifest(path: Path) -> dict:
    with open(path, encoding="utf-8") as f:
        content = f.read()
    try:
        val = ast.literal_eval(content)
    except SyntaxError as error:
        raise unparseable(path, error) from error
    except ValueError:
        return {}
    return val if isinstance(val, dict) else {}


def has_test_modules(
    addon_dir: Path,
    not_run_map: dict | None = None,
    test_py_files: list | None = None,
) -> bool:
    """Whether odoo's test loader finds tests in the addon (`odoo/tests/loader.py`
    `get_test_modules`): a `test_*` module of its `tests` package running a test (none of
    `not_run_tests`), or an upgrade test (`migrations/tests/test_*.py`,
    `upgrades/tests/test_*.py`). A `tests/` holding only helpers (`common.py`), or only
    `-standard` tests (test_crm_full's performance tests), has none: its suite would list
    no test (TEST_SUITE_EMPTY), or run 0 and fail."""
    tests_dir = addon_dir / "tests"
    if test_py_files is not None or tests_dir.is_dir():
        files = (
            [Path(p) for p in _walk_files_str(str(tests_dir), ".py") if os.path.basename(p).startswith("test_")]
            if test_py_files is None
            else test_py_files
        )
        if files:
            nr = not_run_tests(addon_dir, files) if not_run_map is None else not_run_map
            idle = {f for group in nr.values() for f in group}
            if any(f not in idle for f in files):
                return True
    return any(
        _has_prefixed_py(addon_dir / d / "tests")
        for d in ("migrations", "upgrades")
    )


def _walk_stmts(node: ast.AST):
    stack = [node]
    while stack:
        cur = stack.pop()
        for attr in ("body", "orelse", "finalbody", "handlers", "cases"):
            children = getattr(cur, attr, None)
            if children:
                for child in children:
                    yield child
                    stack.append(child)


def loaded_test_files(tests_dir: Path) -> set:
    """The `test_*.py` files under `tests_dir` odoo's loader runs (`odoo/tests/loader.py`
    `_get_tests_modules`): the members of the `tests` package named `test_*`, which its
    `__init__.py` binds by importing them (`from . import test_x`, `from .test_x import X`),
    or by a subpackage's star import or named import of its own `test_*` submodules."""
    loaded = set()

    def walk(package: Path, names: set | None) -> None:
        init = package / "__init__.py"
        if not init.is_file():
            return
        tree = _tree(init)
        for node in _walk_stmts(tree):
            if not isinstance(node, ast.ImportFrom) or node.level != 1:
                continue
            if node.module is None:
                bound = [(alias.name, None) for alias in node.names]
            else:
                head = node.module.split(".")[0]
                star = any(alias.name == "*" for alias in node.names)
                bound = [(head, None if star else {a.name for a in node.names})]
            for name, wanted in bound:
                module = package / f"{name}.py"
                if module.is_file():
                    if name.startswith("test_") and (names is None or name in names):
                        loaded.add(module)
                elif (package / name / "__init__.py").is_file() and package == tests_dir:
                    # `from .sub import *` binds the test_* members sub's __init__ binds;
                    # `from .sub import test_x` imports that submodule itself.
                    sub = package / name
                    loaded.update(
                        sub / f"{n}.py" for n in wanted or () if n.startswith("test_") and (sub / f"{n}.py").is_file()
                    )
                    walk(sub, wanted)

    walk(tests_dir, None)
    return loaded


def _tagged(decorator: ast.expr) -> list | None:
    """The tags of an `@tagged(...)` decorator, None for another decorator."""
    if not isinstance(decorator, ast.Call):
        return None
    func = decorator.func
    name = func.id if isinstance(func, ast.Name) else getattr(func, "attr", None)
    if name != "tagged":
        return None
    return [a.value for a in decorator.args if isinstance(a, ast.Constant) and isinstance(a.value, str)]


# odoo's own test case classes: none sets `allow_inherited_tests_method`.
ODOO_TEST_BASES = {"BaseCase", "TransactionCase", "SingleTransactionCase", "HttpCase", "TestCase"}


def _base_name(base: ast.expr) -> str | None:
    if isinstance(base, ast.Name):
        return base.id
    return base.attr if isinstance(base, ast.Attribute) else None


def _sets_inherit(node: ast.ClassDef) -> bool:
    return any(
        isinstance(f, ast.Assign)
        and any(isinstance(t, ast.Name) and t.id == "allow_inherited_tests_method" for t in f.targets)
        for f in node.body
    )


_TREES: dict = {}
_HAS_ADDONS_IMPORT: dict = {}
_ADDON_HOME_CACHE: dict = {}
_LENDS_CACHE: dict = {}


def _tree(path: Path) -> ast.Module:
    if path not in _TREES:
        text = path.read_text(encoding="utf-8", errors="ignore")
        _HAS_ADDONS_IMPORT[path] = "odoo.addons." in text
        try:
            _TREES[path] = ast.parse(text)
        except SyntaxError as error:
            raise unparseable(path, error) from error
    return _TREES[path]


def _py_file(base: Path) -> Path | None:
    for file in (base.with_suffix(".py"), base / "__init__.py"):
        if file.is_file():
            return file
    return None


def _addon_home(addon: str, near: Path) -> Path | None:
    for parent in near.parents:
        key = (parent, addon)
        if key in _ADDON_HOME_CACHE:
            home = _ADDON_HOME_CACHE[key]
            if home is not None:
                return home
            continue
        found = None
        for addons in (parent / "addons", parent / "odoo" / "addons"):
            home = addons / addon
            if (home / "__manifest__.py").is_file():
                found = home
                break
        _ADDON_HOME_CACHE[key] = found
        if found is not None:
            return found
    return None


def _module_file(module, near: Path) -> Path | None:
    """The file of a relative module (`(directory, dotted rest)`) or of
    `odoo.addons.<addon>.<sub...>`, the addon looked up in the `addons/` and `odoo/addons/`
    of `near`'s ancestors; None when it isn't there."""
    if isinstance(module, tuple):
        directory, rest = module
        return _py_file(directory.joinpath(*rest.split("."))) if rest else _py_file(directory)
    parts = module.split(".")
    if parts[:2] != ["odoo", "addons"] or len(parts) < 3:
        return None
    addon, sub = parts[2], parts[3:]
    home = _addon_home(addon, near)
    if home is not None:
        return _py_file(home.joinpath(*sub))
    return None


def _lends_tests(path: Path, name: str, seen: set) -> bool:
    """Whether class `name` of `path`, or a base of it, sets `allow_inherited_tests_method`
    (odoo's loader then takes inherited `test*` methods too). A base it can't find counts
    as lending (it may)."""
    key = (path, name)
    if key in _LENDS_CACHE:
        return _LENDS_CACHE[key]
    if key in seen:
        return False
    is_root = not seen
    seen.add(key)
    tree = _tree(path)
    classes = {n.name: n for n in tree.body if isinstance(n, ast.ClassDef)}
    node = classes.get(name)
    if node is None:
        if is_root:
            _LENDS_CACHE[key] = True
        return True
    if _sets_inherit(node):
        _LENDS_CACHE[key] = True
        return True
    imported = {}
    for stmt in tree.body:
        if isinstance(stmt, ast.ImportFrom) and (stmt.module or stmt.level):
            # A relative module is `(directory, dotted rest)`; an absolute one its name.
            module = (path.parents[stmt.level - 1], stmt.module or "") if stmt.level else stmt.module
            for alias in stmt.names:
                imported[alias.asname or alias.name] = (module, alias.name)
    for base in node.bases:
        if isinstance(base, ast.Name) and base.id in classes:
            lent = _lends_tests(path, base.id, seen)
        elif _base_name(base) in ODOO_TEST_BASES:
            lent = False
        else:
            # `Name` imported from a module, or `module.Name` with the module imported.
            if isinstance(base, ast.Name) and base.id in imported:
                module, cls = imported[base.id]
            elif isinstance(base, ast.Attribute) and isinstance(base.value, ast.Name) and base.value.id in imported:
                (module, sub), cls = imported[base.value.id], base.attr
                module = (module[0], ".".join(filter(None, [module[1], sub]))) if isinstance(module, tuple) else f"{module}.{sub}"
            else:
                if is_root:
                    _LENDS_CACHE[key] = True
                return True
            file = _module_file(module, path)
            lent = True if file is None else _lends_tests(file, cls, seen)
        if lent:
            if is_root:
                _LENDS_CACHE[key] = True
            return True
    if is_root:
        _LENDS_CACHE[key] = False
    return False


def test_classes_standard(path: Path) -> list:
    """Whether each test class `path` defines (one with its own `test*` methods, as odoo's
    loader takes them, or inheriting some through `allow_inherited_tests_method`) is
    `standard`, the tag odoo's default run and a `--test-tags /<file>` selection need: tags
    are inherited and `@tagged('-standard')` drops it. A base defined elsewhere counts as
    standard (odoo's test classes are)."""
    tree = _tree(path)
    classes = {n.name: n for n in tree.body if isinstance(n, ast.ClassDef)}
    standard = {}

    def resolve(name: str) -> bool:
        if name not in standard:
            standard[name] = True  # a cycle can't happen in valid code; guard anyway
            node = classes[name]
            local = [b.id for b in node.bases if isinstance(b, ast.Name) and b.id in classes]
            value = all(resolve(b) for b in local) if local else True
            for decorator in node.decorator_list:
                tags = _tagged(decorator) or []
                if "-standard" in tags:
                    value = False
                elif "standard" in tags:
                    value = True
            standard[name] = value
        return standard[name]

    def has_tests(node: ast.ClassDef) -> bool:
        """Its own `test*` methods (odoo's loader reads the class's `__dict__`); or inherited
        ones, `allow_inherited_tests_method` set on it or a base (point_of_sale's
        TestGenericLocalization lends its tests). A `pass` subclass of a common base
        (website_event_crm's TestWebsiteEventCrmFlow) runs none."""
        if any(
            isinstance(f, (ast.FunctionDef, ast.AsyncFunctionDef)) and f.name.startswith("test")
            for f in node.body
        ):
            return True
        return _lends_tests(path, node.name, set())

    return [resolve(name) for name, node in classes.items() if has_tests(node)]


# Why a test-named file under an addon's `tests/` runs no test, as `target_scope.not_run`
# reasons: selecting it alone (`--test-tags /<file>`) ran 0 tests and failed the shard.
NOT_RUN_REASONS = {
    "unloaded": "tests/__init__.py doesn't import it: odoo's test loader never runs it",
    "nonstandard": "every test class is tagged -standard: odoo's default run and a --test-tags /<file> selection leave it out",
    "no_tests": "defines no test case class of its own (helpers, or @standalone scripts run by their tag alone): odoo's loader finds no test in it",
}


def not_run_tests(addon_dir: Path, test_py_files: list | None = None) -> dict:
    """The addon's test-named files (`tests/**/test_*.py`) that run no test, by reason
    (NOT_RUN_REASONS)."""
    tests_dir = addon_dir / "tests"
    found = {reason: [] for reason in NOT_RUN_REASONS}
    if test_py_files is None:
        if not tests_dir.is_dir():
            return found
        test_py_files = [
            Path(p) for p in _walk_files_str(str(tests_dir), ".py") if os.path.basename(p).startswith("test_")
        ]
    elif not test_py_files:
        return found
    loaded = loaded_test_files(tests_dir)
    for path in test_py_files:
        if path not in loaded:
            found["unloaded"].append(path)
            continue
        standard = test_classes_standard(path)
        if not standard:
            found["no_tests"].append(path)
        elif not any(standard):
            found["nonstandard"].append(path)
    return found


def load_addons_from_cue(cue_path: Path) -> dict:
    manifests = {}
    if not cue_path.is_file():
        return manifests
    with open(cue_path, encoding="utf-8") as f:
        content = f.read()
    entry_pattern = re.compile(
        r'"([a-zA-Z0-9_-]+)":\s*\{\s*dir:\s*"([^"]+)"\s*depends:\s*\[(.*?)\](?:\s*test_depends:\s*\[(.*?)\])?\s*has_tests:\s*(true|false)',
        re.DOTALL,
    )
    for m in entry_pattern.finditer(content):
        name = m.group(1)
        dir_path = m.group(2)
        raw_deps = m.group(3) or ""
        deps = [
            d.strip().strip(",").strip().strip('"').strip()
            for d in raw_deps.splitlines()
            if d.strip().strip(",").strip().strip('"').strip()
        ]
        raw_test_deps = m.group(4) or ""
        test_deps = [
            d.strip().strip(",").strip().strip('"').strip()
            for d in raw_test_deps.splitlines()
            if d.strip().strip(",").strip().strip('"').strip()
        ]
        has_tests = m.group(5) == "true"
        manifests[name] = {
            "name": name,
            "dir": dir_path,
            "depends": deps,
            "test_deps": test_deps,
            "test_depends": test_deps,
            "has_tests": has_tests,
            "auto_install": False,
        }
    return manifests


def parse_single_manifest(m_path: str, repo_root: Path):
    p = Path(m_path)
    addon_name = p.parent.name
    data = get_manifest(p)
    rel_dir = p.parent.relative_to(repo_root).as_posix()
    tests_dir = p.parent / "tests"
    test_deps = set()
    test_py_files = []
    if tests_dir.is_dir():
        all_py = [Path(fp) for fp in _walk_files_str(str(tests_dir), ".py")]
        for py in all_py:
            test_deps.update(extract_python_imports(py))
        test_py_files = [py for py in all_py if py.name.startswith("test_")]
    static_dir = p.parent / "static"
    if static_dir.is_dir():
        for js in _walk_files_str(str(static_dir), ".js"):
            test_deps.update(extract_js_imports(js))
    test_deps.discard(addon_name)
    raw_not_run = not_run_tests(p.parent, test_py_files)
    not_run = {
        reason: [f.relative_to(repo_root).as_posix() for f in files]
        for reason, files in raw_not_run.items()
    }
    sorted_test_deps = sorted(list(test_deps))
    return (addon_name, {
        "name": addon_name,
        "dir": rel_dir,
        "depends": data.get("depends", []),
        "test_deps": sorted_test_deps,
        "test_depends": sorted_test_deps,
        "auto_install": data.get("auto_install", False),
        "countries": data.get("countries", []),
        "installable": data.get("installable", True),
        "has_tests": has_test_modules(p.parent, raw_not_run, test_py_files),
        "not_run": not_run,
    })


def _parse_manifest_chunk(args: tuple[list[str], Path]) -> list[tuple[str, dict]]:
    files, repo_root = args
    out = []
    for f in files:
        try:
            out.append(parse_single_manifest(f, repo_root))
        except SystemExit as exc:
            return [("__error__", {"msg": str(exc)})]
    return out


def index_all_manifests(repo_root: Path) -> dict:
    manifests = {}
    search_patterns = [
        str(repo_root / "addons" / "*" / "__manifest__.py"),
        str(repo_root / "odoo" / "addons" / "*" / "__manifest__.py"),
    ]
    all_files = []
    for pattern in search_patterns:
        all_files.extend(glob.glob(pattern))

    if len(all_files) <= 32:
        for f in all_files:
            name, meta = parse_single_manifest(f, repo_root)
            manifests[name] = meta
    else:
        workers = min(os.cpu_count() or 4, 8)
        chunk_size = (len(all_files) + workers - 1) // workers
        chunks = [
            (all_files[i : i + chunk_size], repo_root)
            for i in range(0, len(all_files), chunk_size)
        ]
        ctx = (
            multiprocessing.get_context("fork")
            if "fork" in multiprocessing.get_all_start_methods()
            else None
        )
        with ProcessPoolExecutor(max_workers=workers, mp_context=ctx) as executor:
            for batch in executor.map(_parse_manifest_chunk, chunks):
                for name, meta in batch:
                    if name == "__error__":
                        raise SystemExit(meta["msg"])
                    manifests[name] = meta

    # In a sparse checkout, disk manifests may be partial; fall back to .enact/addons.cue for unpopulated addons
    cue_manifests = load_addons_from_cue(repo_root / ".enact" / "addons.cue")
    for k, v in cue_manifests.items():
        if k not in manifests:
            manifests[k] = v

    return manifests


def extract_python_imports(file_path: Path) -> set:
    addons = set()
    tree = _tree(file_path)
    if not _HAS_ADDONS_IMPORT.get(file_path, True):
        return addons
    for node in _walk_stmts(tree):
        if isinstance(node, ast.ImportFrom) and node.module:
            if node.module.startswith("odoo.addons."):
                parts = node.module.split(".")
                if len(parts) > 2:
                    addons.add(parts[2])
        elif isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name.startswith("odoo.addons."):
                    parts = alias.name.split(".")
                    if len(parts) > 2:
                        addons.add(parts[2])
    return addons


JS_IMPORT_BYTES_PATTERN = re.compile(rb'(?:from|import)\s+["\']@([a-zA-Z0-9_-]+)/')


def extract_js_imports(file_path: str | Path) -> set:
    addons = set()
    try:
        with open(file_path, "rb") as f:
            content = f.read()
        if b"@" not in content:
            return addons
        for m in JS_IMPORT_BYTES_PATTERN.finditer(content):
            addons.add(m.group(1).decode("ascii"))
    except Exception:
        pass
    return addons


def find_addon_dependencies(repo_root: Path, addon_dir: Path, manifests: dict) -> set:
    """Find direct dependencies from tests, JS, and manifest."""
    deps = set()
    addon_name = addon_dir.name
    if addon_name in manifests:
        deps.update(manifests[addon_name].get("depends", []))
        deps.update(manifests[addon_name].get("test_depends", []))

    # 1. Scan tests
    tests_dir = addon_dir / "tests"
    if tests_dir.is_dir():
        for py in _walk_files_str(str(tests_dir), ".py"):
            deps.update(extract_python_imports(Path(py)))

    # 2. Scan JS assets (tours, widgets, bundles)
    static_dir = addon_dir / "static"
    if static_dir.is_dir():
        for js in _walk_files_str(str(static_dir), ".js"):
            js_deps = extract_js_imports(js)
            for d in js_deps:
                if d in manifests:
                    deps.add(d)

    return deps


def resolve_component_sparse(
    repo_root: Path,
    comp_root: str,
    manifests: dict,
    include_l10n: bool = False,
) -> list:
    """Compute the transitive closure of needed directories for a component."""
    root_path = repo_root / comp_root
    direct_deps = find_addon_dependencies(repo_root, root_path, manifests)

    closure = set(direct_deps)
    queue = list(direct_deps)
    visited = set()

    while queue:
        addon = queue.pop(0)
        if addon in visited:
            continue
        visited.add(addon)

        if addon in manifests:
            all_deps = set(manifests[addon].get("depends", [])) | set(manifests[addon].get("test_depends", []))
            for dep in all_deps:
                if not include_l10n and dep.startswith("l10n_"):
                    continue
                if dep not in closure:
                    closure.add(dep)
                    queue.append(dep)

    # Convert to directory paths, excluding component root itself
    dirs = [
        manifests[a]["dir"]
        for a in closure
        if a in manifests and manifests[a]["dir"] != comp_root
    ]
    return sorted(dirs)


def get_global_pipeline_sparse(cue_content: str) -> set:
    global_sparse = set()
    m_global = re.search(r"pipeline:\s*\{.*?sparseCheckout:\s*\[(.*?)\]", cue_content, re.DOTALL)
    if m_global:
        for line in m_global.group(1).splitlines():
            clean = line.strip().strip('"').strip(",").strip('"').strip()
            if clean:
                global_sparse.add(clean)
    return global_sparse


def is_path_covered(path: str, available_paths: set) -> bool:
    """Check if path is directly in available_paths or covered by a parent directory."""
    if path in available_paths:
        return True
    parts = path.split("/")
    for i in range(1, len(parts)):
        parent = "/".join(parts[:i])
        if parent in available_paths:
            return True
    return False


def extract_component_blocks(cue_content: str) -> dict:
    blocks = {}
    pattern = re.compile(r'^\s*"([a-zA-Z0-9_-]+)":\s*\{', re.MULTILINE)
    for m in pattern.finditer(cue_content):
        name = m.group(1)
        start = m.end()
        depth = 1
        i = start
        while i < len(cue_content) and depth > 0:
            if cue_content[i] == "{":
                depth += 1
            elif cue_content[i] == "}":
                depth -= 1
            i += 1
        blocks[name] = cue_content[start : i - 1]
    return blocks


def get_component_sparse_map(cue_content: str) -> dict:
    comp_map = {}
    blocks = extract_component_blocks(cue_content)
    for name, block in blocks.items():
        sparse_dirs = set()
        c_sparse_m = re.search(r"sparseCheckout:\s*\[(.*?)\]", block, re.DOTALL)
        if c_sparse_m:
            for line in c_sparse_m.group(1).splitlines():
                clean = line.strip().strip('"').strip(",").strip('"').strip()
                if clean:
                    sparse_dirs.add(clean)

        deps = []
        dep_m = re.search(r"dependsOnComponents:\s*\[(.*?)\]", block, re.DOTALL)
        if dep_m:
            for line in dep_m.group(1).splitlines():
                clean = line.strip().strip('"').strip(",").strip('"').strip()
                if clean:
                    deps.append(clean)

        comp_map[name] = {
            "sparse": sparse_dirs,
            "depends": deps,
        }
    return comp_map


def manifest_depends(name: str, depends: list, manifests: dict) -> list:
    """An addon's dependencies as odoo loads them (`odoo/modules/module.py` `load_manifest`):
    `base` depends on nothing, and every other addon on `base` at least, even with no
    `depends` or only ones outside the repository. That edge is what connects every addon
    component to `root` (through `base`)."""
    if name == "base":
        return []
    return sorted({d for d in depends if d in manifests and d != name}) or ["base"]


# Closure templates: the databases test jobs fork (components.cue `services.db`). A seed's
# template holds what `odoo-bin -i <seed> --with-demo` installs on base's
# (setup/ci/post-start-postgres.sh): its dependency closure and the auto_install addons
# those pull in. An addon's job forks the largest template its own install contains, so
# it installs only the rest; one with none forks base's. Seeds are the closures the most
# suites share, weighed by their install time.
TEMPLATE_SEEDS = (
    "mail",
    "account",
    "stock_account",
    "sale",
    "website",
    "website_sale",
    "point_of_sale",
    "hr",
)


def dependency_closure(names, manifests: dict) -> set:
    """The addons `names` depend on, transitively, themselves included (in the repository)."""
    seen, stack = set(), list(names)
    while stack:
        name = stack.pop()
        if name in seen or name not in manifests:
            continue
        seen.add(name)
        stack.extend(manifest_depends(name, manifests[name].get("depends", []), manifests))
    return seen


def install_set(seed: str, manifests: dict) -> set:
    """What `odoo-bin -i <seed>` installs (`ir.module.module.button_install`): the dependency
    closure, then, until none is left, each auto_install addon whose required dependencies
    are all installed (`auto_install: [...]` names them; `True`, every dependency). A
    country-specific one (`countries`) is left out: it follows the companies, which data
    adds."""
    installed = dependency_closure([seed], manifests)
    auto = {
        name: (
            m["auto_install"]
            if isinstance(m["auto_install"], list)
            else manifest_depends(name, m.get("depends", []), manifests)
        )
        for name, m in manifests.items()
        if m.get("auto_install") and m.get("installable", True) and not m.get("countries")
    }
    added = True
    while added:
        added = False
        for name, required in auto.items():
            if name not in installed and set(required) <= installed:
                installed |= dependency_closure([name], manifests)
                added = True
    return installed


def closure_templates(manifests: dict) -> dict:
    """Each addon's template seed (TEMPLATE_SEEDS): the one with the largest install among
    those it depends on whose install doesn't contain it. A fork of it holds exactly what
    installing the addon from base's would have installed first."""
    seeds = {seed: install_set(seed, manifests) for seed in TEMPLATE_SEEDS if seed in manifests}
    chosen = {}
    for name in manifests:
        deps = dependency_closure([name], manifests) - {name}
        fits = [s for s in seeds if s in deps and name not in seeds[s]]
        if fits:
            chosen[name] = max(fits, key=lambda s: (len(seeds[s]), s))
    return chosen


def template_addon_dirs(manifests: dict, seeds) -> dict:
    """Each template's addons (a seed's install set, `base` alone for base's) by their dirs:
    what its init installs, so what its `template_inputs` hash (components.cue)."""
    return {
        seed: sorted(manifests[name]["dir"] for name in install_set(seed, manifests))
        for seed in sorted(seeds)
        if seed in manifests
    }


def generate_addons_cue(repo_root: Path, manifests: dict) -> str:
    lines = [
        "// Code generated by resolve_sparse_checkout.py; DO NOT EDIT.",
        "package replay",
        "",
        "_addons: {",
    ]
    templates = closure_templates(manifests)
    for name in sorted(manifests.keys()):
        m = manifests[name]
        m_dir = m["dir"]
        has_tests = m["has_tests"] if "has_tests" in m else has_test_modules(repo_root / m_dir)
        deps = manifest_depends(name, m.get("depends", []), manifests)
        test_deps = sorted([
            d for d in m.get("test_depends", [])
            if d in manifests and d != name and d not in deps
        ])
        lines.append(f'\t"{name}": {{')
        lines.append(f'\t\tdir: "{m_dir}"')
        if deps:
            lines.append("\t\tdepends: [")
            for d in deps:
                lines.append(f'\t\t\t"{d}",')
            lines.append("\t\t]")
        else:
            lines.append("\t\tdepends: []")
        if test_deps:
            lines.append("\t\ttest_depends: [")
            for d in test_deps:
                lines.append(f'\t\t\t"{d}",')
            lines.append("\t\t]")
        else:
            lines.append("\t\ttest_depends: []")
        ht_str = "true" if has_tests else "false"
        lines.append(f"\t\thas_tests: {ht_str}")
        if has_tests and name in templates:
            lines.append(f'\t\ttemplate: "{templates[name]}"')
        not_run = {r: t for r, t in m.get("not_run", {}).items() if t} if has_tests else {}
        if not_run:
            lines.append("\t\tnot_run: [")
            for reason, tests in not_run.items():
                lines.append("\t\t\t{")
                lines.append("\t\t\t\ttests: [")
                for t in tests:
                    lines.append(f'\t\t\t\t\t"{t}",')
                lines.append("\t\t\t\t]")
                lines.append(f'\t\t\t\treason: "{NOT_RUN_REASONS[reason]}"')
                lines.append("\t\t\t},")
            lines.append("\t\t]")
        lines.append("\t}")
    lines.append("}")
    lines.append("")
    lines.append("_templates: {")
    for seed, dirs in template_addon_dirs(manifests, {"base", *templates.values()}).items():
        lines.append(f'\t"{seed}": addon_dirs: [')
        for d in dirs:
            lines.append(f'\t\t"{d}",')
        lines.append("\t]")
    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def check_addons_cue(repo_root: Path, manifests: dict) -> bool:
    addons_cue_path = repo_root / ".enact" / "addons.cue"
    if not addons_cue_path.is_file():
        print(f"❌ Could not find {addons_cue_path}. Run with --sync to generate it.")
        return False

    with open(addons_cue_path, encoding="utf-8") as f:
        existing_content = f.read()

    expected_content = generate_addons_cue(repo_root, manifests)
    if existing_content != expected_content:
        print("❌ .enact/addons.cue is out of date with addon manifests. Run with --sync to synchronize.")
        return False

    print(f"✅ .enact/addons.cue is synchronized with {len(manifests)} manifests.")
    return True


def sync_addons_cue(repo_root: Path, manifests: dict):
    addons_cue_path = repo_root / ".enact" / "addons.cue"
    addons_cue_path.parent.mkdir(parents=True, exist_ok=True)
    content = generate_addons_cue(repo_root, manifests)
    with open(addons_cue_path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"✅ Generated {addons_cue_path} ({len(manifests)} addons)")


def main():
    parser = argparse.ArgumentParser(
        description="Resolve and verify Odoo sparse checkout dependencies.",
    )
    parser.add_argument(
        "--component",
        action="append",
        help="Component root directory (e.g. addons/account, addons/sale)",
    )
    parser.add_argument(
        "--all",
        action="store_true",
        help="Analyze all major components defined in repository",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check .enact/addons.cue against repository manifests",
    )
    parser.add_argument(
        "--sync",
        action="store_true",
        help="Synchronize .enact/addons.cue with repository manifests",
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Path to repository root",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    cue_file = repo_root / ".enact" / "addons.cue"

    if args.check or args.sync or not cue_file.is_file():
        manifests = index_all_manifests(repo_root)
    else:
        manifests = load_addons_from_cue(cue_file)

    if args.check:
        print(f"🔍 Validating .enact/addons.cue against {len(manifests)} manifests...")
        ok = check_addons_cue(repo_root, manifests)
        sys.exit(0 if ok else 1)

    if args.sync:
        print("🔄 Synchronizing .enact/addons.cue...")
        sync_addons_cue(repo_root, manifests)
        sys.exit(0)

    components_to_check = []
    if args.component:
        components_to_check = args.component
    elif args.all:
        components_to_check = [
            "odoo/addons/base",
            "addons/web",
            "addons/mail",
            "addons/account",
            "addons/sale",
            "addons/stock",
        ]
    else:
        print("Specify --component <path>, --all, --check, or --sync")
        sys.exit(1)

    print(f"📦 Indexed {len(manifests)} Odoo manifests across repository.")
    print("=" * 60)

    for comp in components_to_check:
        closure = resolve_component_sparse(repo_root, comp, manifests)
        print(f"\n🔹 Component: {comp}")
        print(f"   Transitive dependency directories ({len(closure)} total):")
        for d in closure:
            print(f"     - {d}")


if __name__ == "__main__":
    main()
