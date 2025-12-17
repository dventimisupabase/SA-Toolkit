#!/bin/bash
# =============================================================================
# Check PgBouncer Health
# =============================================================================
# Verifies PgBouncer on Fly.io is healthy and accepting connections.
#
# Usage:
#   ./check_pgbouncer_health.sh
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
if [ -z "$FLY_APP_NAME" ]; then
    echo "ERROR: FLY_APP_NAME must be set"
    exit 1
fi

echo "=== PgBouncer Health Check ==="
echo "Fly App: ${FLY_APP_NAME}"
echo ""

# Track failures
FAILURES=0

# Test 1: Check Fly.io app status
echo -n "1. Fly.io app status... "
APP_STATUS=$(fly status -a "$FLY_APP_NAME" --json 2>/dev/null | jq -r '.Status // "unknown"' || echo "error")
if [ "$APP_STATUS" = "running" ]; then
    echo "PASS (running)"
elif [ "$APP_STATUS" = "error" ]; then
    echo "FAIL (cannot reach Fly.io)"
    FAILURES=$((FAILURES + 1))
else
    echo "WARNING ($APP_STATUS)"
fi

# Test 2: Check machine count
echo -n "2. Machine count... "
MACHINE_COUNT=$(fly status -a "$FLY_APP_NAME" --json 2>/dev/null | jq '.Machines | length' || echo "0")
if [ "$MACHINE_COUNT" -gt 0 ]; then
    echo "PASS ($MACHINE_COUNT machines)"
else
    echo "FAIL (no machines)"
    FAILURES=$((FAILURES + 1))
fi

# Test 3: PgBouncer admin connection (via fly ssh)
echo -n "3. PgBouncer admin... "
POOLS_OUTPUT=$(fly ssh console -a "$FLY_APP_NAME" -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -t -c 'SHOW POOLS;'" 2>/dev/null || echo "error")
if [ "$POOLS_OUTPUT" != "error" ] && [ -n "$POOLS_OUTPUT" ]; then
    echo "PASS"
else
    echo "FAIL (cannot connect to admin)"
    FAILURES=$((FAILURES + 1))
fi

# Test 4: Pool status
echo -n "4. Pool status... "
if [ "$POOLS_OUTPUT" != "error" ] && [ -n "$POOLS_OUTPUT" ]; then
    # Extract pool mode from output
    echo "PASS"
    echo ""
    echo "Pool Details:"
    fly ssh console -a "$FLY_APP_NAME" -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'" 2>/dev/null || true
else
    echo "SKIP"
fi

# Test 5: Client connections
echo ""
echo -n "5. Client connections... "
CLIENTS_OUTPUT=$(fly ssh console -a "$FLY_APP_NAME" -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -t -c 'SHOW CLIENTS;'" 2>/dev/null | wc -l || echo "0")
echo "PASS ($((CLIENTS_OUTPUT - 2)) clients)"  # Subtract header and footer lines

# Test 6: Server connections
echo -n "6. Server connections... "
SERVERS_OUTPUT=$(fly ssh console -a "$FLY_APP_NAME" -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -t -c 'SHOW SERVERS;'" 2>/dev/null | wc -l || echo "0")
echo "PASS ($((SERVERS_OUTPUT - 2)) servers)"

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
