#!/bin/bash
# =============================================================================
# Sync Sequences for Failover
# =============================================================================
# Synchronizes sequence values from primary to standby with a buffer.
# Must run BEFORE promoting standby to prevent primary key conflicts.
#
# Usage:
#   ./sync_sequences_for_failover.sh [buffer]
#   ./sync_sequences_for_failover.sh         # Uses default buffer (10000)
#   ./sync_sequences_for_failover.sh 100000  # Custom buffer
#
# Exit codes:
#   0 - Successfully synced
#   1 - Error
# =============================================================================

set -e

# Parse arguments
BUFFER="${1:-}"

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../../config/.env"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "ERROR: Config file not found at $CONFIG_FILE"
    exit 1
fi

# Use config buffer if not specified as argument
BUFFER="${BUFFER:-${SEQUENCE_BUFFER:-10000}}"

# Validate required variables
if [ -z "$PRIMARY_HOST" ] || [ -z "$STANDBY_HOST" ] || [ -z "$POSTGRES_PASSWORD" ]; then
    echo "ERROR: PRIMARY_HOST, STANDBY_HOST, and POSTGRES_PASSWORD must be set"
    exit 1
fi

DATABASE_NAME="${DATABASE_NAME:-postgres}"
DATABASE_USER="${DATABASE_USER:-postgres}"

# Connection strings
PRIMARY_CONN="postgresql://${DATABASE_USER}:${POSTGRES_PASSWORD}@${PRIMARY_HOST}:5432/${DATABASE_NAME}"
STANDBY_CONN="postgresql://${DATABASE_USER}:${POSTGRES_PASSWORD}@${STANDBY_HOST}:5432/${DATABASE_NAME}"

echo "=== Sequence Synchronization ==="
echo "Primary: ${PRIMARY_HOST}"
echo "Standby: ${STANDBY_HOST}"
echo "Buffer:  ${BUFFER}"
echo ""

# Get sequences from primary
echo "Fetching sequences from primary..."
SEQUENCES=$(psql "$PRIMARY_CONN" -t -A -F'|' -c "
    SELECT
        schemaname || '.' || sequencename,
        last_value
    FROM pg_sequences
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    ORDER BY schemaname, sequencename
")

if [ -z "$SEQUENCES" ]; then
    echo "No sequences found or could not connect to primary."
    exit 1
fi

# Count sequences
SEQ_COUNT=$(echo "$SEQUENCES" | wc -l | tr -d ' ')
echo "Found ${SEQ_COUNT} sequences."
echo ""

# Sync each sequence
echo "Synchronizing sequences to standby..."
echo "-----------------------------------------------------------"
printf "%-40s %12s %12s\n" "SEQUENCE" "PRIMARY" "NEW VALUE"
echo "-----------------------------------------------------------"

SYNCED=0
ERRORS=0

while IFS='|' read -r seq_name last_value; do
    if [ -n "$seq_name" ] && [ -n "$last_value" ]; then
        new_value=$((last_value + BUFFER))

        # Set the sequence on standby
        if psql "$STANDBY_CONN" -c "SELECT setval('${seq_name}', ${new_value});" > /dev/null 2>&1; then
            printf "%-40s %12d %12d\n" "$seq_name" "$last_value" "$new_value"
            SYNCED=$((SYNCED + 1))
        else
            printf "%-40s %12s %12s (ERROR)\n" "$seq_name" "$last_value" "-"
            ERRORS=$((ERRORS + 1))
        fi
    fi
done <<< "$SEQUENCES"

echo "-----------------------------------------------------------"
echo ""
echo "=== Summary ==="
echo "Sequences synced: ${SYNCED}"
echo "Errors: ${ERRORS}"
echo "Buffer applied: +${BUFFER}"
echo ""

if [ $ERRORS -gt 0 ]; then
    echo "WARNING: Some sequences failed to sync. Check manually."
    exit 1
else
    echo "All sequences synchronized successfully."
    exit 0
fi
