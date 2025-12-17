#!/bin/bash
# =============================================================================
# Resume PgBouncer
# =============================================================================
# Resumes all PgBouncer pools. Queued connections proceed.
#
# Usage:
#   ./resume_pgbouncer.sh
#
# Exit codes:
#   0 - Successfully resumed
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

echo "=== Resuming PgBouncer ==="
echo "App: ${FLY_APP_NAME}"
echo ""

# Resume all pools
echo "Executing RESUME..."
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RESUME;'"

# Verify resume
echo ""
echo "Verifying pool status..."
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"

echo ""
echo "=== PgBouncer Resumed ==="
echo "All pools are active. Connections flowing normally."
