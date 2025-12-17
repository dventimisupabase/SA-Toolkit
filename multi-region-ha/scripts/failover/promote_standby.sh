#!/bin/bash
# =============================================================================
# Promote Standby Database
# =============================================================================
# Promotes the standby to primary by dropping the subscription.
# This makes the standby writable.
#
# Usage:
#   ./promote_standby.sh
#
# Exit codes:
#   0 - Successfully promoted
#   1 - Error
# =============================================================================

set -e

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../../config/.env"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config file not found at $CONFIG_FILE"
    exit 1
fi

# Validate required variables
if [ -z "$STANDBY_HOST" ] || [ -z "$POSTGRES_PASSWORD" ]; then
    echo "ERROR: STANDBY_HOST and POSTGRES_PASSWORD must be set"
    exit 1
fi

DATABASE_NAME="${DATABASE_NAME:-postgres}"
DATABASE_USER="${DATABASE_USER:-postgres}"

# Connection string
STANDBY_CONN="postgresql://${DATABASE_USER}:${POSTGRES_PASSWORD}@${STANDBY_HOST}:5432/${DATABASE_NAME}"

echo "=== Promote Standby Database ==="
echo "Host: ${STANDBY_HOST}"
echo ""

# Check if subscription exists
SUB_EXISTS=$(psql "$STANDBY_CONN" -t -A -c "SELECT count(*) FROM pg_subscription WHERE subname = 'dr_subscription'")

if [ "$SUB_EXISTS" = "0" ]; then
    echo "Subscription 'dr_subscription' not found."
    echo "Standby may already be promoted or was never a subscriber."
    exit 0
fi

# Disable subscription first
echo "Disabling subscription..."
psql "$STANDBY_CONN" -c "ALTER SUBSCRIPTION dr_subscription DISABLE;"

# Wait for any pending operations
sleep 2

# Drop subscription
echo "Dropping subscription..."
psql "$STANDBY_CONN" -c "DROP SUBSCRIPTION dr_subscription;"

# Verify subscription is gone
echo ""
echo "Verifying promotion..."
SUB_COUNT=$(psql "$STANDBY_CONN" -t -A -c "SELECT count(*) FROM pg_subscription WHERE subname = 'dr_subscription'")

if [ "$SUB_COUNT" = "0" ]; then
    echo ""
    echo "=== Standby Promoted ==="
    echo "Database is now writable and can serve as primary."
    echo ""
    echo "Next steps:"
    echo "  1. Update PgBouncer to point to this host"
    echo "  2. Resume traffic"
    echo "  3. Plan to rebuild the old primary as new standby"
    exit 0
else
    echo ""
    echo "ERROR: Subscription still exists. Manual intervention required."
    exit 1
fi
