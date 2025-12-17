#!/bin/bash
# =============================================================================
# Freeze Primary Database
# =============================================================================
# Sets the primary database to read-only to prevent new writes.
# Used during failover to ensure no split-brain.
#
# Usage:
#   ./freeze_primary.sh
#
# Exit codes:
#   0 - Successfully frozen
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
if [ -z "$PRIMARY_HOST" ] || [ -z "$POSTGRES_PASSWORD" ]; then
    echo "ERROR: PRIMARY_HOST and POSTGRES_PASSWORD must be set"
    exit 1
fi

DATABASE_NAME="${DATABASE_NAME:-postgres}"
DATABASE_USER="${DATABASE_USER:-postgres}"

# Connection string
PRIMARY_CONN="postgresql://${DATABASE_USER}:${POSTGRES_PASSWORD}@${PRIMARY_HOST}:5432/${DATABASE_NAME}"

echo "=== Freeze Primary Database ==="
echo "Host: ${PRIMARY_HOST}"
echo ""

# Method 1: Set default_transaction_read_only on the database
echo "Setting database to read-only mode..."
psql "$PRIMARY_CONN" -c "ALTER DATABASE ${DATABASE_NAME} SET default_transaction_read_only = on;"

# Verify
echo ""
echo "Verifying read-only mode..."
READONLY=$(psql "$PRIMARY_CONN" -t -A -c "SHOW default_transaction_read_only")
echo "default_transaction_read_only = $READONLY"

if [ "$READONLY" = "on" ]; then
    echo ""
    echo "=== Primary Frozen ==="
    echo "Database is now in read-only mode."
    echo "New connections will not be able to write."
    echo ""
    echo "To unfreeze (if needed):"
    echo "  psql \"\$PRIMARY_CONN\" -c \"ALTER DATABASE ${DATABASE_NAME} RESET default_transaction_read_only;\""
    exit 0
else
    echo ""
    echo "WARNING: Database may not be fully frozen."
    echo "Check the setting manually."
    exit 1
fi
