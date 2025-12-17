#!/bin/bash
# =============================================================================
# Check Primary Supabase Health
# =============================================================================
# Verifies the primary Supabase project is healthy and accepting connections.
#
# Usage:
#   ./check_primary_health.sh
#
# Exit codes:
#   0 - Healthy
#   1 - Unhealthy or error
# =============================================================================

set -e

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

echo "=== Primary Health Check ==="
echo "Host: ${PRIMARY_HOST}"
echo ""

# Track failures
FAILURES=0

# Test 1: Basic connectivity
echo -n "1. Connection test... "
if psql "$PRIMARY_CONN" -c "SELECT 1" > /dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
    FAILURES=$((FAILURES + 1))
fi

# Test 2: Check if database is accepting writes
echo -n "2. Write capability... "
READONLY=$(psql "$PRIMARY_CONN" -t -A -c "SHOW default_transaction_read_only" 2>/dev/null || echo "error")
if [ "$READONLY" = "off" ]; then
    echo "PASS (read-write)"
elif [ "$READONLY" = "on" ]; then
    echo "FAIL (read-only)"
    FAILURES=$((FAILURES + 1))
else
    echo "FAIL (connection error)"
    FAILURES=$((FAILURES + 1))
fi

# Test 3: Check active connections
echo -n "3. Active connections... "
ACTIVE=$(psql "$PRIMARY_CONN" -t -A -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active'" 2>/dev/null || echo "error")
if [ "$ACTIVE" != "error" ]; then
    echo "PASS ($ACTIVE active)"
else
    echo "FAIL"
    FAILURES=$((FAILURES + 1))
fi

# Test 4: Check replication slot (if configured)
echo -n "4. Replication slot... "
SLOT_ACTIVE=$(psql "$PRIMARY_CONN" -t -A -c "SELECT active FROM pg_replication_slots WHERE slot_name = 'dr_slot'" 2>/dev/null || echo "not_found")
if [ "$SLOT_ACTIVE" = "t" ]; then
    echo "PASS (active)"
elif [ "$SLOT_ACTIVE" = "f" ]; then
    echo "WARNING (inactive)"
elif [ -z "$SLOT_ACTIVE" ] || [ "$SLOT_ACTIVE" = "not_found" ]; then
    echo "SKIP (no DR slot)"
else
    echo "FAIL"
    FAILURES=$((FAILURES + 1))
fi

# Test 5: Check replication lag (if slot exists)
echo -n "5. Replication lag... "
LAG=$(psql "$PRIMARY_CONN" -t -A -c "
    SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn))
    FROM pg_replication_slots
    WHERE slot_name = 'dr_slot'
" 2>/dev/null || echo "not_found")
if [ -n "$LAG" ] && [ "$LAG" != "not_found" ]; then
    echo "PASS ($LAG)"
else
    echo "SKIP (no DR slot)"
fi

# Summary
echo ""
echo "=== Summary ==="
if [ $FAILURES -eq 0 ]; then
    echo "Status: HEALTHY"
    exit 0
else
    echo "Status: UNHEALTHY ($FAILURES failures)"
    exit 1
fi
