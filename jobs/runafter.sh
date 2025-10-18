#!/usr/bin/env bash
# Usage: ./runafter.sh --randomwait SECONDS command [args...]

set -euo pipefail

[[ $# -lt 2 || "$1" != "--randomwait" ]] && { echo "Usage: $0 --randomwait SECONDS command [args...]"; exit 1; }

RANDOMWAIT="$2"
shift 2

# Sleep randomly if requested
((RANDOMWAIT > 0)) && sleep $(( RANDOM % (RANDOMWAIT + 1) ))

# Print timestamp and command
echo "[$(date '+%F %T')] Running: $*"

# Execute the command
exec "$@"
