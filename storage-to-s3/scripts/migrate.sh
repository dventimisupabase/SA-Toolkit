#!/bin/bash
# =====================================================================
# Supabase Storage to AWS S3 Migration Script
# =====================================================================
# Migrates objects from Supabase Storage buckets to AWS S3.
#
# Usage:
#   ./migrate.sh [options]
#
# Options:
#   --dry-run     Show what would be migrated without copying
#   --bucket NAME Migrate only the specified bucket
#   --help        Show this help message
#
# Exit codes:
#   0 - Success
#   1 - Error (missing dependencies, config, or migration failure)
# =====================================================================

set -e

# =====================================================================
# Configuration
# =====================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../config/.env"
LOG_FILE="${SCRIPT_DIR}/../migration.log"

DRY_RUN=false
SINGLE_BUCKET=""

# =====================================================================
# Helper Functions
# =====================================================================

log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

error() {
    log "ERROR: $1"
    exit 1
}

show_help() {
    head -24 "$0" | tail -20
    exit 0
}

# =====================================================================
# Parse Arguments
# =====================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
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
    error "Config file not found: $CONFIG_FILE
Copy config/env.example to config/.env and configure it."
fi

# Validate required variables
REQUIRED_VARS="AWS_S3_BUCKET AWS_REGION"
for var in $REQUIRED_VARS; do
    if [ -z "${!var}" ]; then
        error "$var must be set in $CONFIG_FILE"
    fi
done

# Set defaults
TEMP_DIR="${TEMP_DIR:-/tmp/supabase-migration}"
CLEANUP_TEMP="${CLEANUP_TEMP:-true}"
PARALLEL_JOBS="${PARALLEL_JOBS:-5}"
S3_PREFIX="${S3_PREFIX:-}"
SUPABASE_BUCKETS="${SUPABASE_BUCKETS:-all}"

# =====================================================================
# Check Prerequisites
# =====================================================================

log "=== Checking prerequisites ==="

# Check Supabase CLI
if ! command -v supabase &> /dev/null; then
    error "Supabase CLI not found. Install: https://supabase.com/docs/guides/cli"
fi
log "Supabase CLI: $(supabase --version)"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    error "AWS CLI not found. Install: https://aws.amazon.com/cli/"
fi
log "AWS CLI: $(aws --version | head -1)"

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    error "AWS credentials not configured. Run 'aws configure' or set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY"
fi
log "AWS credentials: OK"

# Check S3 bucket access
if ! aws s3 ls "s3://${AWS_S3_BUCKET}" &> /dev/null; then
    error "Cannot access S3 bucket: ${AWS_S3_BUCKET}"
fi
log "S3 bucket access: OK"

# =====================================================================
# Get Bucket List
# =====================================================================

log "=== Preparing migration ==="

if [ -n "$SINGLE_BUCKET" ]; then
    BUCKETS="$SINGLE_BUCKET"
    log "Single bucket mode: $SINGLE_BUCKET"
elif [ "$SUPABASE_BUCKETS" = "all" ]; then
    log "Fetching bucket list from Supabase..."
    BUCKETS=$(supabase storage ls --linked --experimental 2>/dev/null | grep -v "^$" || true)
    if [ -z "$BUCKETS" ]; then
        error "No buckets found or unable to list buckets. Ensure project is linked with 'supabase link'"
    fi
else
    BUCKETS="$SUPABASE_BUCKETS"
fi

BUCKET_COUNT=$(echo "$BUCKETS" | wc -w | tr -d ' ')
log "Buckets to migrate: $BUCKET_COUNT"

# =====================================================================
# Create Temp Directory
# =====================================================================

mkdir -p "$TEMP_DIR"
log "Temp directory: $TEMP_DIR"

# =====================================================================
# Migration
# =====================================================================

log "=== Starting migration ==="

if [ "$DRY_RUN" = true ]; then
    log "DRY RUN MODE - no files will be copied"
fi

TOTAL_BUCKETS=0
FAILED_BUCKETS=0
MIGRATED_FILES=0

for bucket in $BUCKETS; do
    TOTAL_BUCKETS=$((TOTAL_BUCKETS + 1))
    BUCKET_DIR="${TEMP_DIR}/${bucket}"
    S3_DEST="s3://${AWS_S3_BUCKET}/${S3_PREFIX}${bucket}/"

    log "--- Bucket $TOTAL_BUCKETS/$BUCKET_COUNT: $bucket ---"

    if [ "$DRY_RUN" = true ]; then
        log "[DRY RUN] Would download: ss://${bucket}/ -> ${BUCKET_DIR}/"
        log "[DRY RUN] Would upload: ${BUCKET_DIR}/ -> ${S3_DEST}"
        continue
    fi

    # Create bucket directory
    mkdir -p "$BUCKET_DIR"

    # Download from Supabase
    log "Downloading from Supabase Storage..."
    if ! supabase storage cp "ss://${bucket}/" "${BUCKET_DIR}/" \
        --recursive \
        --linked \
        --experimental \
        -j "$PARALLEL_JOBS" 2>&1 | tee -a "$LOG_FILE"; then
        log "WARNING: Failed to download bucket: $bucket"
        FAILED_BUCKETS=$((FAILED_BUCKETS + 1))
        continue
    fi

    # Count downloaded files
    FILE_COUNT=$(find "$BUCKET_DIR" -type f | wc -l | tr -d ' ')
    log "Downloaded $FILE_COUNT files"

    # Upload to S3
    log "Uploading to S3: ${S3_DEST}"
    if ! aws s3 sync "${BUCKET_DIR}/" "${S3_DEST}" \
        --region "$AWS_REGION" 2>&1 | tee -a "$LOG_FILE"; then
        log "WARNING: Failed to upload bucket: $bucket"
        FAILED_BUCKETS=$((FAILED_BUCKETS + 1))
        continue
    fi

    MIGRATED_FILES=$((MIGRATED_FILES + FILE_COUNT))
    log "Bucket $bucket: migration complete"
done

# =====================================================================
# Cleanup
# =====================================================================

if [ "$CLEANUP_TEMP" = true ] && [ "$DRY_RUN" = false ]; then
    log "=== Cleaning up temp directory ==="
    rm -rf "$TEMP_DIR"
    log "Temp directory removed"
fi

# =====================================================================
# Summary
# =====================================================================

log "=== Migration Summary ==="
log "Total buckets: $TOTAL_BUCKETS"
log "Failed buckets: $FAILED_BUCKETS"
log "Migrated files: $MIGRATED_FILES"
log "Log file: $LOG_FILE"

if [ "$FAILED_BUCKETS" -gt 0 ]; then
    log "WARNING: Some buckets failed to migrate. Check the log for details."
    exit 1
fi

log "Migration completed successfully!"
