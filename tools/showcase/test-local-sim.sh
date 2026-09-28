#!/usr/bin/env bash
set -euo pipefail

PR="${1:-290896}"
echo "=========================================="
echo "🧪 Local Showcase Simulation for PR #${PR}"
echo "=========================================="

WORKSPACE="$(pwd)"

# 1. Prepare showcase environment
echo "▶ Tier 1: Preparing showcase baseline and patch..."
python3 tools/showcase/prepare-showcase-env.py --pr "$PR" --workspace "$WORKSPACE"

# 2. Extract changed files and compute affected matrix
echo "▶ Tier 2: Computing affected matrix via enact reachability..."
FILES_CSV=""
if [ -f ".enact/changed-files.txt" ] && [ -s ".enact/changed-files.txt" ]; then
    FILES_CSV=$(paste -sd, .enact/changed-files.txt)
fi

echo "   Changed files: $FILES_CSV"
enact affected --pipeline .enact --workflow ci ${FILES_CSV:+--files "$FILES_CSV"} --format text

# 3. Dry-run CI workflow graph
echo "▶ Tier 3: Validating pipeline graph schema..."
enact dry-run --pipeline .enact -w ci

# 4. Run preflight quality gates locally
echo "▶ Tier 4: Executing preflight stage..."
enact run --pipeline .enact -w ci -s preflight ${FILES_CSV:+--files "$FILES_CSV"}

# 5. Generate benchmark preview
echo "▶ Tier 5: Testing benchmark reporter..."
python3 tools/showcase/report-showcase-benchmark.py

echo "=========================================="
echo "✅ Local verification PASSED for PR #${PR}!"
echo "=========================================="
