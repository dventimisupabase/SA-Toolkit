#!/bin/bash
# =====================================================================
# Supabase to S3 Migration Verification Script
# =====================================================================
# Compares object counts between Supabase Storage and AWS S3 to verify
# migration completeness.
#
# Usage:
#   ./verify.sh [options]
#
# Options:
#   --bucket NAME Verify only the specified bucket
#   --help        Show this help message
#
# Exit codes:
#   0 - Verification passed (counts match)
#   1 - Verification failed (counts mismatch or error)
# =====================================================================

set -e

# =====================================================================
# Configuration
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/.env"

SINGLE_BUCKET=""

# =====================================================================
# Helper Functions
# =====================================================================

log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1"
}

error() {
    log "ERROR: $1"
    exit 1
}

show_help() {
    head -20 "$0" | tail -16
    exit 0
}

# =====================================================================
# Parse Arguments
# =====================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --bucket)
            SINGLE_BUCKET="$2"
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# =====================================================================
# Load Configuration
# =====================================================================

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    error "Config file not found: $CONFIG_FILE"
fi

# Validate required variables
if [ -z "$AWS_S3_BUCKET" ]; then
    error "AWS_S3_BUCKET must be set in $CONFIG_FILE"
fi

AWS_REGION="${AWS_REGION:-us-east-1}"
S3_PREFIX="${S3_PREFIX:-}"
SUPABASE_BUCKETS="${SUPABASE_BUCKETS:-all}"

# =====================================================================
# Get Bucket List
# =====================================================================

log "=== Verification: Supabase Storage vs S3 ==="

if [ -n "$SINGLE_BUCKET" ]; then
    BUCKETS="$SINGLE_BUCKET"
elif [ "$SUPABASE_BUCKETS" = "all" ]; then
    BUCKETS=$(supabase storage ls --linked --experimental 2>/dev/null | grep -v "^$" || true)
    if [ -z "$BUCKETS" ]; then
        error "No buckets found. Ensure project is linked."
    fi
else
    BUCKETS="$SUPABASE_BUCKETS"
fi

# =====================================================================
# Verification
# =====================================================================

TOTAL_BUCKETS=0
PASSED_BUCKETS=0
FAILED_BUCKETS=0

printf "\n%-30s %15s %15s %10s\n" "BUCKET" "SUPABASE" "S3" "STATUS"
printf "%-30s %15s %15s %10s\n" "------------------------------" "---------------" "---------------" "----------"

for bucket in $BUCKETS; do
    TOTAL_BUCKETS=$((TOTAL_BUCKETS + 1))
    S3_PATH="${S3_PREFIX}${bucket}/"

    # Count objects in Supabase (recursive listing)
    SUPABASE_COUNT=$(supabase storage ls "ss://${bucket}/" --recursive --linked --experimental 2>/dev/null | wc -l | tr -d ' ') || SUPABASE_COUNT="ERR"

    # Count objects in S3
    S3_COUNT=$(aws s3 ls "s3://${AWS_S3_BUCKET}/${S3_PATH}" --recursive --region "$AWS_REGION" 2>/dev/null | wc -l | tr -d ' ') || S3_COUNT="ERR"

    # Compare
    if [ "$SUPABASE_COUNT" = "$S3_COUNT" ] && [ "$SUPABASE_COUNT" != "ERR" ]; then
        STATUS="PASS"
        PASSED_BUCKETS=$((PASSED_BUCKETS + 1))
    else
        STATUS="FAIL"
        FAILED_BUCKETS=$((FAILED_BUCKETS + 1))
    fi

    printf "%-30s %15s %15s %10s\n" "$bucket" "$SUPABASE_COUNT" "$S3_COUNT" "$STATUS"
done

# =====================================================================
# Summary
# =====================================================================

printf "\n"
log "=== Verification Summary ==="
log "Total buckets: $TOTAL_BUCKETS"
log "Passed: $PASSED_BUCKETS"
log "Failed: $FAILED_BUCKETS"

if [ "$FAILED_BUCKETS" -gt 0 ]; then
    log "Verification FAILED: Object counts do not match for some buckets."
    exit 1
fi

log "Verification PASSED: All object counts match."
