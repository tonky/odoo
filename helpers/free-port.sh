#!/usr/bin/env bash
# Prints a TCP port for a server a test run starts itself (odoo-shard.sh: odoo's HTTP port).
#
#   port="$(PORTS_OWNER=$$ bash helpers/free-port.sh)"
#
# A port from the shard's number or service slot collides: slots are per run, so two runs
# on one host (two agents' gates) both started their first shard's odoo on 8070, and one
# failed "Port 8070 is in use by another program". odoo can't take port 0: its tests read
# the port from its config (`config['http_port']`). So a port is
#   - outside the kernel's ephemeral range (Linux 32768+, macOS 49152+), where outgoing
#     connections take theirs, and below enve's instance ports (20000-32767);
#   - reserved for its owner's life: a directory per port under FREE_PORTS_DIR holds the
#     owner's pid (PORTS_OWNER, else the caller). A port a live owner holds is skipped, a
#     dead owner's taken over. The directory is the one forgejo's helpers/free-ports.sh
#     uses, so the two usecases' runs on one host never pick the same port;
#   - free when picked: nothing accepts a connection on it.
# Linux and macOS take halves of the range: OrbStack forwards a VM's listeners to the
# Mac's 127.0.0.1. FREE_PORTS_RANGE (`low-high`) narrows it.
set -euo pipefail

owner="${PORTS_OWNER:-${PPID}}"
dir="${FREE_PORTS_DIR:-/tmp/test-ports-$(id -u)}"
if [[ -n "${FREE_PORTS_RANGE:-}" ]]; then
    low="${FREE_PORTS_RANGE%-*}" high="${FREE_PORTS_RANGE#*-}"
elif [[ "$(uname -s)" == Linux ]]; then
    low=10000 high=14999
else
    low=15000 high=19999
fi
mkdir -p "${dir}"

# Takes the port's reservation for the owner; a reservation whose owner is gone is stale.
reserve() {
    local lock="${dir}/$1" pid
    if mkdir "${lock}" 2>/dev/null; then
        echo "${owner}" > "${lock}/owner"
        return 0
    fi
    pid="$(cat "${lock}/owner" 2>/dev/null || true)"
    # A reservation being written has no pid yet: it's taken. The owner's own is too.
    [[ -n "${pid}" && "${pid}" != "${owner}" ]] || return 1
    ! kill -0 "${pid}" 2>/dev/null || return 1
    echo "${owner}" > "${lock}/owner"
}
# Nothing accepts a connection on the port.
unused() {
    ! (exec 3<> "/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

span=$((high - low + 1))
# Random first, then every port of the range in turn: a narrow range is searched whole.
start=$(((RANDOM * 32768 + RANDOM) % span))
for ((i = 0; i < span && i < 2000; i++)); do
    port=$((low + (start + i) % span))
    reserve "${port}" || continue
    if unused "${port}"; then
        echo "${port}"
        exit 0
    fi
    rm -rf "${dir:?}/${port}"
done
echo "free-port: no free port in ${low}-${high} (${dir})" >&2
exit 1
