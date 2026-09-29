#!/usr/bin/env python3
"""
tools/showcase/prepare-showcase-env.py
======================================
Prepares the repository workspace for a showcase benchmark run.
Supports:
  1. Resolving PR metadata from GitHub CLI (`gh pr view`) or explicit commit SHAs.
  2. Scraping upstream GitHub Actions check-run telemetry (actual run duration, CPU time, shard count).
  3. Non-destructively overlaying the PR code onto the workspace while preserving .enact/ and enve configurations.
  4. Computing changed files and outputting GitHub Actions step variables.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def run_cmd(cmd, cwd=None, check=True, capture=True, strip=True):
    """Executes a shell command and returns stdout."""
    res = subprocess.run(
        cmd,
        cwd=cwd,
        check=check,
        shell=isinstance(cmd, str),
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )
    if not capture:
        return ""
    return res.stdout.strip() if strip else res.stdout


def set_gha_output(key: str, value: str):
    """Sets a GitHub Actions step output."""
    output_file = os.environ.get("GITHUB_OUTPUT")
    if output_file:
        with open(output_file, "a") as f:
            if "\n" in value:
                delimiter = "EOF_" + os.urandom(8).hex()
                f.write(f"{key}<<{delimiter}\n{value}\n{delimiter}\n")
            else:
                f.write(f"{key}={value}\n")
    print(f"   [GHA Output] {key} = {value[:80] if len(value) > 80 else value}")


def scrape_upstream_checks(repo: str, commit_sha: str) -> dict:
    """Scrapes upstream check runs for a commit and computes total CPU & max wall time."""
    print(f"🔍 Scraping upstream CI check runs for {repo}@{commit_sha[:10]}...")
    try:
        out = run_cmd(["gh", "api", f"repos/{repo}/commits/{commit_sha}/check-runs?per_page=100"])
        data = json.loads(out)
        check_runs = data.get("check_runs", [])
    except Exception as e:
        print(f"⚠️ Warning: could not scrape upstream checks via gh api: {e}")
        return {}

    total_cpu_seconds = 0.0
    max_wall_seconds = 0.0
    runs_summary = []

    for cr in check_runs:
        started = cr.get("started_at")
        completed = cr.get("completed_at")
        conclusion = cr.get("conclusion") or "pending"
        name = cr.get("name", "unnamed")
        if started and completed:
            try:
                t0 = datetime.fromisoformat(started.replace("Z", "+00:00"))
                t1 = datetime.fromisoformat(completed.replace("Z", "+00:00"))
                dur = (t1 - t0).total_seconds()
                if dur > 3:  # ignore sub-second noise
                    total_cpu_seconds += dur
                    max_wall_seconds = max(max_wall_seconds, dur)
                    runs_summary.append({
                        "name": name,
                        "duration_s": dur,
                        "conclusion": conclusion,
                    })
            except Exception:
                continue

    runs_summary.sort(key=lambda x: x["duration_s"], reverse=True)
    return {
        "repo": repo,
        "commit": commit_sha,
        "total_check_runs": len(check_runs),
        "timed_runs_count": len(runs_summary),
        "total_cpu_seconds": total_cpu_seconds,
        "total_cpu_minutes": round(total_cpu_seconds / 60.0, 1),
        "max_wall_seconds": max_wall_seconds,
        "max_wall_minutes": round(max_wall_seconds / 60.0, 1),
        "top_runs": runs_summary[:10],
    }


def main():
    parser = argparse.ArgumentParser(description="Prepare showcase benchmark environment")
    parser.add_argument("--pr", help="Upstream PR number or URL (e.g. 102450 or https://github.com/...)")
    parser.add_argument("--head", help="PR head commit SHA or branch name")
    parser.add_argument("--base", default="master", help="Target base commit SHA or branch name (default: master)")
    parser.add_argument("--repo", help="Upstream GitHub repository (e.g. PostHog/posthog, n8n-io/n8n, odoo/odoo)")
    parser.add_argument("--workspace", default=".", help="Target repository directory (default: .)")
    parser.add_argument("--overlay", help="Directory containing .enact/ and enve configs to preserve/project")
    args = parser.parse_args()

    repo_dir = Path(args.workspace).resolve()
    print(f"🚀 Preparing showcase environment in {repo_dir}...")

    # Determine default upstream repo if not passed
    upstream_repo = args.repo
    if not upstream_repo:
        try:
            remote_url = run_cmd("git config --get remote.upstream.url || git config --get remote.origin.url", cwd=repo_dir)
            if "github.com" in remote_url:
                # git@github.com:owner/repo.git or https://github.com/owner/repo.git
                parts = remote_url.split("github.com")[-1].lstrip("/:").rstrip(".git")
                upstream_repo = parts
        except Exception:
            pass

    pr_title = ""
    pr_url = ""
    pr_author = ""
    head_sha = args.head or ""
    base_sha = args.base or "master"

    # 1. Resolve PR details via gh CLI if PR is provided
    if args.pr:
        pr_id = args.pr.strip()
        if pr_id.startswith("http"):
            # Extract number from URL
            pr_id = pr_id.rstrip("/").split("/")[-1]

        gh_cmd = ["gh", "pr", "view", pr_id, "--json", "number,title,url,author,baseRefOid,headRefOid,headRefName,baseRefName"]
        if upstream_repo:
            gh_cmd.extend(["--repo", upstream_repo])

        print(f"📋 Resolving PR #{pr_id} from {upstream_repo or 'origin'}...")
        try:
            out = run_cmd(gh_cmd, cwd=repo_dir)
            pr_data = json.loads(out)
            head_sha = pr_data.get("headRefOid") or head_sha
            base_sha = pr_data.get("baseRefOid") or base_sha
            pr_title = pr_data.get("title", "")
            pr_url = pr_data.get("url", "")
            pr_author = (pr_data.get("author") or {}).get("login", "")
            print(f"   ✓ PR #{pr_id}: '{pr_title}' by @{pr_author}")
            print(f"   ✓ Base: {base_sha[:10]} | Head: {head_sha[:10]}")
        except Exception as e:
            print(f"⚠️ Warning: Could not resolve PR #{pr_id} via gh: {e}")

    if not head_sha:
        head_sha = run_cmd("git rev-parse HEAD", cwd=repo_dir)
    if not base_sha:
        base_sha = "master"

    # 2. Scrape Upstream CI Baseline
    upstream_baseline = {}
    if upstream_repo and head_sha:
        upstream_baseline = scrape_upstream_checks(upstream_repo, head_sha)
        enact_dir = repo_dir / ".enact"
        enact_dir.mkdir(parents=True, exist_ok=True)
        baseline_file = enact_dir / "upstream-baseline.json"
        with open(baseline_file, "w") as f:
            json.dump(upstream_baseline, f, indent=2)
        print(f"   💾 Saved upstream baseline metrics to {baseline_file}")

    # 3. Resolve changed files & patch
    print("🌿 Resolving PR diff and changed files...")
    enact_dir = repo_dir / ".enact"
    enact_dir.mkdir(parents=True, exist_ok=True)
    changed_files = []
    patch_content = ""

    if args.pr:
        pr_id_clean = args.pr.strip().rstrip("/").split("/")[-1]
        repo_flag = ["--repo", upstream_repo] if upstream_repo else []
        try:
            diff_files_out = run_cmd(["gh", "pr", "diff", pr_id_clean, "--name-only"] + repo_flag, cwd=repo_dir)
            changed_files = [line.strip() for line in diff_files_out.splitlines() if line.strip()]
        except Exception as e:
            print(f"⚠️ Could not list changed files via gh pr diff: {e}")

        try:
            patch_content = run_cmd(["gh", "pr", "diff", pr_id_clean] + repo_flag, cwd=repo_dir, strip=False)
        except Exception as e:
            print(f"⚠️ Could not obtain patch via gh pr diff: {e}")

    # Fallback to local git diff if gh pr diff was not used
    if not changed_files and base_sha and head_sha:
        try:
            diff_files_out = run_cmd(f"git diff --name-only {base_sha}...{head_sha}", cwd=repo_dir)
            changed_files = [line.strip() for line in diff_files_out.splitlines() if line.strip()]
        except Exception:
            try:
                diff_files_out = run_cmd("git diff --name-only HEAD~1", cwd=repo_dir)
                changed_files = [line.strip() for line in diff_files_out.splitlines() if line.strip()]
            except Exception:
                changed_files = []

    print(f"📝 Changed files detected: {len(changed_files)}")
    for f in changed_files[:8]:
        print(f"   • {f}")
    if len(changed_files) > 8:
        print(f"   ... and {len(changed_files) - 8} more")

    # Save changed-files.txt
    with open(enact_dir / "changed-files.txt", "w") as f:
        f.write("\n".join(changed_files))

    # 4. Save and Apply PR patch to workspace
    if patch_content:
        with open(enact_dir / "pr-changes.patch", "w") as f:
            f.write(patch_content)
        print(f"   💾 Saved pr-changes.patch ({len(patch_content)} bytes)")

        # Ensure changed files are materialized if running under sparse checkout
        if changed_files:
            try:
                run_cmd(["git", "sparse-checkout", "add"] + changed_files, cwd=repo_dir, check=False)
            except Exception:
                pass

        # Apply patch non-destructively
        print(f"🔄 Projecting PR code changes onto workspace...")
        res = subprocess.run(["git", "apply", "--check", "-"], input=patch_content, text=True, cwd=repo_dir, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if res.returncode == 0:
            subprocess.run(["git", "apply", "-"], input=patch_content, text=True, cwd=repo_dir, check=True)
            print("   ✓ PR code patch applied cleanly.")
        else:
            res_3way = subprocess.run(["git", "apply", "--3way", "-"], input=patch_content, text=True, cwd=repo_dir, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if res_3way.returncode == 0:
                print("   ✓ PR code patch applied via 3-way merge.")
            else:
                print("   ⚠️ Clean apply failed; trying with reject fallback...")
                subprocess.run(["git", "apply", "--reject", "-"], input=patch_content, text=True, cwd=repo_dir, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # 6. Set GitHub Actions outputs
    set_gha_output("base_sha", base_sha)
    set_gha_output("head_sha", head_sha)
    set_gha_output("pr_title", pr_title or f"Showcase run: {base_sha[:8]}..{head_sha[:8]}")
    set_gha_output("pr_url", pr_url)
    set_gha_output("pr_author", pr_author)
    set_gha_output("changed_files_count", str(len(changed_files)))
    set_gha_output("has_upstream_baseline", "true" if upstream_baseline.get("total_cpu_seconds", 0) > 0 else "false")
    set_gha_output("upstream_cpu_minutes", str(upstream_baseline.get("total_cpu_minutes", "N/A")))
    set_gha_output("upstream_wall_minutes", str(upstream_baseline.get("max_wall_minutes", "N/A")))

    print("\n✅ Showcase environment preparation complete.")


if __name__ == "__main__":
    main()
