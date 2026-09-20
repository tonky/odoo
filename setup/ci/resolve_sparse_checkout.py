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
import re
import sys
from pathlib import Path


def get_manifest(path: Path) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            val = ast.literal_eval(f.read())
        return val if isinstance(val, dict) else {}
    except Exception:
        return {}


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
            "test_depends": test_deps,
            "has_tests": has_tests,
            "auto_install": False,
        }
    return manifests


def index_all_manifests(repo_root: Path) -> dict:
    manifests = {}
    search_patterns = [
        str(repo_root / "addons" / "*" / "__manifest__.py"),
        str(repo_root / "odoo" / "addons" / "*" / "__manifest__.py"),
    ]
    for pattern in search_patterns:
        for m_path in glob.glob(pattern):
            p = Path(m_path)
            addon_name = p.parent.name
            data = get_manifest(p)
            rel_dir = p.parent.relative_to(repo_root).as_posix()
            tests_dir = p.parent / "tests"
            test_deps = set()
            if tests_dir.is_dir():
                for py in tests_dir.glob("**/*.py"):
                    test_deps.update(extract_python_imports(py))
            static_dir = p.parent / "static"
            if static_dir.is_dir():
                for js in static_dir.glob("**/*.js"):
                    test_deps.update(extract_js_imports(js))
            test_deps.discard(addon_name)
            manifests[addon_name] = {
                "name": addon_name,
                "dir": rel_dir,
                "depends": data.get("depends", []),
                "test_depends": sorted(list(test_deps)),
                "auto_install": data.get("auto_install", False),
                "has_tests": tests_dir.is_dir(),
            }

    # In a sparse checkout, disk manifests may be partial; fall back to .enact/addons.cue for unpopulated addons
    cue_manifests = load_addons_from_cue(repo_root / ".enact" / "addons.cue")
    for k, v in cue_manifests.items():
        if k not in manifests:
            manifests[k] = v

    return manifests


def extract_python_imports(file_path: Path) -> set:
    addons = set()
    try:
        with open(file_path, encoding="utf-8", errors="ignore") as f:
            tree = ast.parse(f.read())
        for node in ast.walk(tree):
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
    except Exception:
        pass
    return addons


def extract_js_imports(file_path: Path) -> set:
    addons = set()
    pattern = re.compile(r'(?:from|import)\s+["\']@([a-zA-Z0-9_-]+)/')
    try:
        with open(file_path, encoding="utf-8", errors="ignore") as f:
            content = f.read()
        for m in pattern.finditer(content):
            addons.add(m.group(1))
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
        for py in tests_dir.glob("**/*.py"):
            deps.update(extract_python_imports(py))

    # 2. Scan JS assets (tours, widgets, bundles)
    static_dir = addon_dir / "static"
    if static_dir.is_dir():
        for js in static_dir.glob("**/*.js"):
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


def generate_addons_cue(repo_root: Path, manifests: dict) -> str:
    lines = [
        "// Code generated by resolve_sparse_checkout.py; DO NOT EDIT.",
        "package replay",
        "",
        "_addons: {",
    ]
    for name in sorted(manifests.keys()):
        m = manifests[name]
        m_dir = m["dir"]
        has_tests = m.get("has_tests", (repo_root / m_dir / "tests").is_dir())
        deps = sorted([d for d in m.get("depends", []) if d in manifests and d != name])
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
        lines.append("\t}")
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
        "--dirs-only",
        action="store_true",
        help="Output only directory paths (one per line) for hook consumption",
    )
    parser.add_argument(
        "--repo-root",
        default=".",
        help="Path to repository root",
    )
    args = parser.parse_args()

    repo_root = Path(args.repo_root).resolve()
    manifests = index_all_manifests(repo_root)

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

    if args.dirs_only:
        all_dirs = set()
        for comp in components_to_check:
            all_dirs.update(resolve_component_sparse(repo_root, comp, manifests))
        for d in sorted(all_dirs):
            print(d)
        sys.exit(0)

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
