#!/bin/bash
# =============================================================================
# Check Standby Supabase Health
# =============================================================================
# Verifies the standby Supabase project is healthy and receiving replication.
#
# Usage:
#   ./check_standby_health.sh
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
if [ -z "$STANDBY_HOST" ] || [ -z "$POSTGRES_PASSWORD" ]; then
    echo "ERROR: STANDBY_HOST and POSTGRES_PASSWORD must be set"
    exit 1
fi

DATABASE_NAME="${DATABASE_NAME:-postgres}"
DATABASE_USER="${DATABASE_USER:-postgres}"

# Connection string
STANDBY_CONN="postgresql://${DATABASE_USER}:${POSTGRES_PASSWORD}@${STANDBY_HOST}:5432/${DATABASE_NAME}"

echo "=== Standby Health Check ==="
echo "Host: ${STANDBY_HOST}"
echo ""

# Track failures
FAILURES=0

# Test 1: Basic connectivity
echo -n "1. Connection test... "
if psql "$STANDBY_CONN" -c "SELECT 1" > /dev/null 2>&1; then
    echo "PASS"
else
    echo "FAIL"
    FAILURES=$((FAILURES + 1))
fi

# Test 2: Check subscription exists
echo -n "2. Subscription exists... "
SUB_EXISTS=$(psql "$STANDBY_CONN" -t -A -c "SELECT count(*) FROM pg_subscription WHERE subname = 'dr_subscription'" 2>/dev/null || echo "0")
if [ "$SUB_EXISTS" = "1" ]; then
    echo "PASS"
else
    echo "FAIL (subscription not found)"
    FAILURES=$((FAILURES + 1))
fi

# Test 3: Check subscription is enabled
echo -n "3. Subscription enabled... "
SUB_ENABLED=$(psql "$STANDBY_CONN" -t -A -c "SELECT subenabled FROM pg_subscription WHERE subname = 'dr_subscription'" 2>/dev/null || echo "error")
if [ "$SUB_ENABLED" = "t" ]; then
    echo "PASS"
elif [ "$SUB_ENABLED" = "f" ]; then
    echo "WARNING (disabled)"
else
    echo "SKIP (no subscription)"
fi

# Test 4: Check last message received
echo -n "4. Replication activity... "
LAST_MSG=$(psql "$STANDBY_CONN" -t -A -c "
    SELECT CASE
        WHEN last_msg_receipt_time IS NULL THEN 'never'
        WHEN age(now(), last_msg_receipt_time) > interval '5 minutes' THEN 'stale'
        ELSE 'recent'
    END
    FROM pg_stat_subscription
    WHERE subname = 'dr_subscription'
" 2>/dev/null || echo "unknown")
if [ "$LAST_MSG" = "recent" ]; then
    echo "PASS (receiving messages)"
elif [ "$LAST_MSG" = "stale" ]; then
    echo "WARNING (no message in 5+ minutes)"
elif [ "$LAST_MSG" = "never" ]; then
    echo "WARNING (never received messages)"
else
    echo "SKIP"
fi

# Test 5: Check table sync status
echo -n "5. Table sync status... "
TABLES_READY=$(psql "$STANDBY_CONN" -t -A -c "
    SELECT count(*)
    FROM pg_subscription_rel
    WHERE srsubid = (SELECT oid FROM pg_subscription WHERE subname = 'dr_subscription')
    AND srsubstate = 'r'
" 2>/dev/null || echo "0")
TABLES_TOTAL=$(psql "$STANDBY_CONN" -t -A -c "
    SELECT count(*)
    FROM pg_subscription_rel
    WHERE srsubid = (SELECT oid FROM pg_subscription WHERE subname = 'dr_subscription')
" 2>/dev/null || echo "0")
if [ "$TABLES_TOTAL" = "0" ]; then
    echo "SKIP (no tables)"
elif [ "$TABLES_READY" = "$TABLES_TOTAL" ]; then
    echo "PASS ($TABLES_READY/$TABLES_TOTAL ready)"
else
    echo "WARNING ($TABLES_READY/$TABLES_TOTAL ready)"
fi

# Test 6: Connection count
echo -n "6. Active connections... "
ACTIVE=$(psql "$STANDBY_CONN" -t -A -c "SELECT count(*) FROM pg_stat_activity WHERE state = 'active'" 2>/dev/null || echo "error")
if [ "$ACTIVE" != "error" ]; then
    echo "PASS ($ACTIVE active)"
else
    echo "FAIL"
    FAILURES=$((FAILURES + 1))
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
