#!/bin/bash
# =============================================================================
# Swap PgBouncer Upstream
# =============================================================================
# Changes the upstream database host that PgBouncer connects to.
# Used during failover to point to the new primary.
#
# Usage:
#   ./swap_upstream.sh <new_host>
#   ./swap_upstream.sh db.new-primary-ref.supabase.co
#
# Exit codes:
#   0 - Successfully swapped
#   1 - Error
# =============================================================================

set -e

# Check argument
if [ -z "$1" ]; then
    echo "Usage: $0 <new_host>"
    echo "Example: $0 db.your-standby-ref.supabase.co"
    exit 1
fi

NEW_HOST="$1"

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

echo "=== Swap PgBouncer Upstream ==="
echo "App: ${FLY_APP_NAME}"
echo "New upstream: ${NEW_HOST}"
echo ""

# Update the DATABASE_HOST secret
echo "Updating DATABASE_HOST secret..."
fly secrets set DATABASE_HOST="$NEW_HOST" -a "$FLY_APP_NAME"

# The secret update triggers a config reload, but let's also explicitly reload
echo ""
echo "Reloading PgBouncer configuration..."
sleep 2  # Wait for secret to propagate
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RELOAD;'" || true

# Verify the change
echo ""
echo "Verifying configuration..."
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW DATABASES;'"

echo ""
echo "=== Upstream Swapped ==="
echo "PgBouncer is now configured to connect to: ${NEW_HOST}"
echo ""
echo "Note: If PgBouncer was paused, run resume_pgbouncer.sh to resume connections."
