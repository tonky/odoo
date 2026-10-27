#!/usr/bin/env bash
# odoo-manifests.sh: in a sparse checkout, write every addon's __manifest__.py its cone left
# out. odoo reads all of them, not only the installed addons': `update_list` registers each
# addon on disk, and base's data refers to the module categories their manifests declare
# (ir_module_module.xml's `base.module_category_services_timesheets` comes from
# hr_timesheet's `'category': 'Services/Timesheets'`), so base failed to install without
# them. A cone-mode checkout can't hold single files, so they're checked out from the index:
# one batched fetch of their blobs (a blobless clone would fetch each on its own), as git's
# own lazy fetch does. A full checkout, or one already holding them, returns at once.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
[ "$(git -C "${root}" config --bool core.sparseCheckout || true)" = true ] || exit 0
missing=()
while IFS= read -r path; do
    [ -f "${root}/${path}" ] || missing+=("${path}")
done < <(git -C "${root}" ls-files -t -- ':(glob)addons/*/__manifest__.py' ':(glob)odoo/addons/*/__manifest__.py' | sed -n 's/^S //p')
[ "${#missing[@]}" -gt 0 ] || exit 0
if [ -n "$(git -C "${root}" config remote.origin.promisor || true)" ]; then
    git -C "${root}" ls-files -s -- "${missing[@]}" | awk '{print $2}' |
        git -C "${root}" -c fetch.negotiationAlgorithm=noop fetch --quiet --no-tags \
            --no-write-fetch-head --recurse-submodules=no --filter=blob:none --stdin origin
fi
# checkout-index writes them as checkout would (mode, eol); git then clears their
# skip-worktree bits, as for any file present on disk.
printf '%s\n' "${missing[@]}" | git -C "${root}" checkout-index -f --ignore-skip-worktree-bits --stdin
