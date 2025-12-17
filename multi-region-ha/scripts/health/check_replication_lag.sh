#!/bin/bash
# =============================================================================
# Check Replication Lag
# =============================================================================
# Monitors replication lag between primary and standby.
#
# Usage:
#   ./check_replication_lag.sh [--alert-threshold-mb 100]
#
# Exit codes:
#   0 - Lag within threshold
#   1 - Lag exceeds threshold or error
# =============================================================================

set -e

# Default threshold (100 MB)
ALERT_THRESHOLD_MB=100

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --alert-threshold-mb)
            ALERT_THRESHOLD_MB="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Load configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../../config/.env"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    echo "Warning: Config file not found at $CONFIG_FILE"
    echo "Using environment variables..."
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

echo "=== Replication Lag Check ==="
echo "Primary: ${PRIMARY_HOST}"
echo "Alert threshold: ${ALERT_THRESHOLD_MB} MB"
echo ""

# Get replication lag from primary
LAG_INFO=$(psql "$PRIMARY_CONN" -t -A -F'|' -c "
    SELECT
        slot_name,
        active,
        pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes,
        pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag_pretty
    FROM pg_replication_slots
    WHERE slot_name = 'dr_slot'
" 2>/dev/null || echo "")

if [ -z "$LAG_INFO" ]; then
    echo "ERROR: Replication slot 'dr_slot' not found"
    exit 1
fi

# Parse the result
IFS='|' read -r SLOT_NAME ACTIVE LAG_BYTES LAG_PRETTY <<< "$LAG_INFO"

echo "Slot: ${SLOT_NAME}"
echo "Active: ${ACTIVE}"
echo "Lag: ${LAG_PRETTY} (${LAG_BYTES} bytes)"
echo ""

# Check if slot is active
if [ "$ACTIVE" != "t" ]; then
    echo "WARNING: Replication slot is not active"
fi

# Calculate threshold in bytes
THRESHOLD_BYTES=$((ALERT_THRESHOLD_MB * 1024 * 1024))

# Compare lag to threshold
if [ "$LAG_BYTES" -gt "$THRESHOLD_BYTES" ]; then
    echo "=== ALERT ==="
    echo "Replication lag (${LAG_PRETTY}) exceeds threshold (${ALERT_THRESHOLD_MB} MB)"
    exit 1
else
    echo "=== Status: OK ==="
    echo "Lag is within acceptable threshold"
    exit 0
fi
