#!/usr/bin/env bash
# Materialize every addon's __manifest__.py in a sparse checkout via `bin/odoo-scope manifests`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$(git -C "${root}" config --bool core.sparseCheckout || true)" = true ] || exit 0
exec "${root}/bin/odoo-scope" --repo-root "${root}" manifests
