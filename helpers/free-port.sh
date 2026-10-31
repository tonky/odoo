#!/usr/bin/env bash
# Pick one unused loopback port and print it on stdout.
# Delegates to `enact helper free-ports` (`F-shell-loop-free-ports-timeout`).
set -euo pipefail

enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact)}}"
exec "${enact}" helper free-ports --count 1 --owner "${PORTS_OWNER:-${PPID}}" ${FREE_PORTS_RANGE:+--range "${FREE_PORTS_RANGE}"}
