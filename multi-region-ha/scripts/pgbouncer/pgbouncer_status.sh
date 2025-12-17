#!/bin/bash
# =============================================================================
# PgBouncer Status
# =============================================================================
# Shows comprehensive PgBouncer status including pools, clients, and servers.
#
# Usage:
#   ./pgbouncer_status.sh
#
# Exit codes:
#   0 - Success
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

echo "=== PgBouncer Status ==="
echo "App: ${FLY_APP_NAME}"
echo ""

# Databases
echo "--- Databases ---"
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW DATABASES;'"
echo ""

# Pools
echo "--- Pools ---"
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"
echo ""

# Stats
echo "--- Stats ---"
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW STATS;'"
echo ""

# Clients (summarized)
echo "--- Client Summary ---"
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW CLIENTS;'" | head -20
echo "(Showing first 20 rows)"
echo ""

# Servers
echo "--- Servers ---"
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW SERVERS;'"
echo ""

# Config
echo "--- Config Summary ---"
fly ssh console -a "$FLY_APP_NAME" -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -t -c \"
        SELECT 'pool_mode: ' || current_setting('pool_mode')
        UNION ALL
        SELECT 'max_client_conn: ' || current_setting('max_client_conn')
        UNION ALL
        SELECT 'default_pool_size: ' || current_setting('default_pool_size');
    \"" 2>/dev/null || echo "(Could not retrieve config)"

echo ""
echo "=== End Status ==="
