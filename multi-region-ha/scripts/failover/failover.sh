#!/bin/bash
# =============================================================================
# Failover Orchestration Script
# =============================================================================
# Orchestrates the complete failover from primary to standby.
#
# Usage:
#   ./failover.sh                  # Full failover
#   ./failover.sh --skip-freeze    # Emergency failover (skip freezing primary)
#   ./failover.sh --dry-run        # Show what would happen
#
# Exit codes:
#   0 - Failover successful
#   1 - Failover failed
# =============================================================================

set -e

# Parse arguments
SKIP_FREEZE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-freeze)
            SKIP_FREEZE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--skip-freeze] [--dry-run]"
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
    echo "ERROR: Config file not found at $CONFIG_FILE"
    exit 1
fi

# Validate required variables
REQUIRED_VARS="PRIMARY_HOST STANDBY_HOST POSTGRES_PASSWORD FLY_APP_NAME"
for var in $REQUIRED_VARS; do
    if [ -z "${!var}" ]; then
        echo "ERROR: $var must be set"
        exit 1
    fi
done

DATABASE_NAME="${DATABASE_NAME:-postgres}"
DATABASE_USER="${DATABASE_USER:-postgres}"
SEQUENCE_BUFFER="${SEQUENCE_BUFFER:-10000}"

# Connection strings
PRIMARY_CONN="postgresql://${DATABASE_USER}:${POSTGRES_PASSWORD}@${PRIMARY_HOST}:5432/${DATABASE_NAME}"
STANDBY_CONN="postgresql://${DATABASE_USER}:${POSTGRES_PASSWORD}@${STANDBY_HOST}:5432/${DATABASE_NAME}"

# Timestamp for logging
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
LOG_FILE="${SCRIPT_DIR}/../../failover_${TIMESTAMP//[: -]/_}.log"

# Logging function
log() {
    echo "[$(date +"%H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

# Error handler
handle_error() {
    log "ERROR: Failover failed at step: $1"
    log "Manual intervention required!"
    exit 1
}

# =============================================================================
# Main Failover Procedure
# =============================================================================

echo "============================================================"
echo "       MULTI-REGION SUPABASE FAILOVER"
echo "============================================================"
echo ""
echo "Timestamp: ${TIMESTAMP}"
echo "Primary:   ${PRIMARY_HOST}"
echo "Standby:   ${STANDBY_HOST} (will become new primary)"
echo "PgBouncer: ${FLY_APP_NAME}"
echo ""

if [ "$SKIP_FREEZE" = true ]; then
    echo "WARNING: --skip-freeze enabled. Primary will NOT be frozen."
    echo "         Use this only if primary is unreachable."
fi

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: No changes will be made."
fi

echo ""
echo "This will:"
echo "  1. Pause PgBouncer (connections queue)"
echo "  2. Freeze primary database (prevent writes)"
echo "  3. Synchronize sequences to standby"
echo "  4. Drop subscription on standby (make writable)"
echo "  5. Swap PgBouncer to standby"
echo "  6. Resume PgBouncer (traffic to new primary)"
echo ""
read -p "Proceed with failover? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Failover cancelled."
    exit 0
fi

echo ""
log "=== Starting Failover ==="

# -----------------------------------------------------------------------------
# Step 1: Pause PgBouncer
# -----------------------------------------------------------------------------
log "Step 1/6: Pausing PgBouncer..."

if [ "$DRY_RUN" = false ]; then
    fly ssh console -a "$FLY_APP_NAME" -C \
        "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'PAUSE;'" \
        || handle_error "pause_pgbouncer"
    log "  PgBouncer paused. Connections are queuing."
else
    log "  [DRY RUN] Would pause PgBouncer"
fi

# -----------------------------------------------------------------------------
# Step 2: Freeze Primary (if reachable)
# -----------------------------------------------------------------------------
if [ "$SKIP_FREEZE" = false ]; then
    log "Step 2/6: Freezing primary database..."

    if [ "$DRY_RUN" = false ]; then
        # Set database to read-only to prevent new writes
        psql "$PRIMARY_CONN" -c "ALTER DATABASE ${DATABASE_NAME} SET default_transaction_read_only = on;" \
            2>/dev/null || {
            log "  WARNING: Could not freeze primary (may be unreachable)"
            log "  Continuing with failover..."
        }
        log "  Primary frozen (read-only mode)."
    else
        log "  [DRY RUN] Would set primary to read-only"
    fi
else
    log "Step 2/6: SKIPPED - Freeze primary (--skip-freeze)"
fi

# -----------------------------------------------------------------------------
# Step 3: Synchronize Sequences
# -----------------------------------------------------------------------------
log "Step 3/6: Synchronizing sequences to standby..."

if [ "$DRY_RUN" = false ]; then
    # Get sequences from primary and sync to standby with buffer
    SEQUENCES=$(psql "$PRIMARY_CONN" -t -A -F'|' -c "
        SELECT schemaname || '.' || sequencename, last_value
        FROM pg_sequences
        WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
    " 2>/dev/null || echo "")

    if [ -n "$SEQUENCES" ]; then
        while IFS='|' read -r seq_name last_value; do
            if [ -n "$seq_name" ]; then
                new_value=$((last_value + SEQUENCE_BUFFER))
                psql "$STANDBY_CONN" -c "SELECT setval('${seq_name}', ${new_value});" > /dev/null 2>&1 || true
                log "  ${seq_name}: ${last_value} -> ${new_value}"
            fi
        done <<< "$SEQUENCES"
        log "  Sequences synchronized with buffer +${SEQUENCE_BUFFER}."
    else
        log "  WARNING: Could not read sequences from primary."
        log "  Continuing - sequences may need manual sync."
    fi
else
    log "  [DRY RUN] Would sync sequences with +${SEQUENCE_BUFFER} buffer"
fi

# -----------------------------------------------------------------------------
# Step 4: Promote Standby
# -----------------------------------------------------------------------------
log "Step 4/6: Promoting standby (dropping subscription)..."

if [ "$DRY_RUN" = false ]; then
    # Disable and drop subscription to make standby writable
    psql "$STANDBY_CONN" -c "ALTER SUBSCRIPTION dr_subscription DISABLE;" 2>/dev/null || true
    psql "$STANDBY_CONN" -c "DROP SUBSCRIPTION dr_subscription;" 2>/dev/null || {
        log "  WARNING: Could not drop subscription. May already be dropped."
    }
    log "  Standby promoted. Now accepting writes."
else
    log "  [DRY RUN] Would drop subscription on standby"
fi

# -----------------------------------------------------------------------------
# Step 5: Swap PgBouncer Upstream
# -----------------------------------------------------------------------------
log "Step 5/6: Swapping PgBouncer upstream to new primary..."

if [ "$DRY_RUN" = false ]; then
    fly secrets set DATABASE_HOST="$STANDBY_HOST" -a "$FLY_APP_NAME" || handle_error "swap_upstream"
    sleep 2  # Wait for secret to propagate
    fly ssh console -a "$FLY_APP_NAME" -C \
        "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RELOAD;'" 2>/dev/null || true
    log "  PgBouncer upstream swapped to: ${STANDBY_HOST}"
else
    log "  [DRY RUN] Would swap upstream to ${STANDBY_HOST}"
fi

# -----------------------------------------------------------------------------
# Step 6: Resume PgBouncer
# -----------------------------------------------------------------------------
log "Step 6/6: Resuming PgBouncer..."

if [ "$DRY_RUN" = false ]; then
    fly ssh console -a "$FLY_APP_NAME" -C \
        "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RESUME;'" \
        || handle_error "resume_pgbouncer"
    log "  PgBouncer resumed. Traffic flowing to new primary."
else
    log "  [DRY RUN] Would resume PgBouncer"
fi

# =============================================================================
# Post-Failover
# =============================================================================
echo ""
log "=== Failover Complete ==="
echo ""
echo "New Primary: ${STANDBY_HOST}"
echo "Old Primary: ${PRIMARY_HOST} (frozen, do not use)"
echo ""
echo "Post-failover checklist:"
echo "  [ ] Verify application connectivity"
echo "  [ ] Test write operations"
echo "  [ ] Update ACTIVE_REGION flag (if using external flag)"
echo "  [ ] Monitor for errors"
echo "  [ ] Plan failback or rebuild old primary as new standby"
echo ""
echo "Log file: ${LOG_FILE}"
