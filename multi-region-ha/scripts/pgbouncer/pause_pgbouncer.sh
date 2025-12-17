#!/bin/bash
# =============================================================================
# Pause PgBouncer
# =============================================================================
# Pauses all PgBouncer pools. Existing connections complete their current
# transaction, then wait. New connections queue until RESUME.
#
# Usage:
#   ./pause_pgbouncer.sh
#
# Exit codes:
#   0 - Successfully paused
#   1 - Error
# =============================================================================

set -e

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../../config/.env"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# Validate required variables
if [ -z "$FLY_APP_NAME" ]; then
    echo "ERROR: FLY_APP_NAME must be set"
    exit 1
fi

echo "=== Pausing PgBouncer ==="
echo "App: ${FLY_APP_NAME}"
echo ""

# Pause all pools
echo "Executing PAUSE..."
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'PAUSE;'"

# Verify pause
echo ""
echo "Verifying pause status..."
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"

echo ""
echo "=== PgBouncer Paused ==="
echo "All pools are paused. Connections are queuing."
echo "Run resume_pgbouncer.sh when ready to resume."
