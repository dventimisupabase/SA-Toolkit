#!/usr/bin/env bash
set -euo pipefail

# -------------------------------------------------------------------
# batch_telemetry.sh  (PostgreSQL 15, 16, or 17)
#
# Client-side batch telemetry: NO database writes.
# Uses ONLY standard libpq environment variables / .pgpass / defaults:
#   PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD, etc.
#
# Requirements: bash, psql, jq
#
# Usage:
#   ./batch_telemetry.sh start  batch_1 "10M row import" | tee batch_1.log
#   ./batch_telemetry.sh sample batch_1                 | tee -a batch_1.log
#   ./batch_telemetry.sh end    batch_1                 | tee -a batch_1.log
#   ./batch_telemetry.sh report batch_1
#
#   ./batch_telemetry.sh --table my_table start batch_1 "10M row import"
#
# Options:
#   --table <name>     Track table-specific stats (optional)
#
# State written locally to: .telemetry/<batch_id>.json
#
# PostgreSQL version is auto-detected from the connected database.
# PG version differences:
#   PG 15: checkpoint stats in pg_stat_bgwriter, no pg_stat_io
#   PG 16: checkpoint stats in pg_stat_bgwriter, pg_stat_io available
#   PG 17: checkpoint stats in pg_stat_checkpointer, pg_stat_io available
# -------------------------------------------------------------------

# -----------------------------
# Arg parsing
# -----------------------------
TARGET_TABLE=""

usage() {
  cat <<'USAGE'
Usage:
  batch_telemetry.sh [--table <name>] <start|sample|end|report> <batch_id> [note]

Options:
  --table <name>     Track table-specific stats (optional)

PostgreSQL version is auto-detected from the connected database.

Examples:
  ./batch_telemetry.sh start  batch_1 "10M row import" | tee batch_1.log
  ./batch_telemetry.sh sample batch_1                 | tee -a batch_1.log
  ./batch_telemetry.sh end    batch_1                 | tee -a batch_1.log
  ./batch_telemetry.sh report batch_1

  ./batch_telemetry.sh --table orders start batch_7 "checkpoint test" | tee batch_7.log
USAGE
}

if [[ $# -lt 2 ]]; then
  usage
  exit 1
fi

# Accept: --table foo or --table=foo
while [[ $# -gt 0 ]]; do
  case "$1" in
    --table)
      TARGET_TABLE="${2:-}"
      shift 2
      ;;
    --table=*)
      TARGET_TABLE="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      break
      ;;
  esac
done

CMD="${1:-}"
BATCH_ID="${2:-}"
NOTE="${3:-}"

if [[ -z "${CMD}" || -z "${BATCH_ID}" ]]; then
  echo "ERROR: command and batch_id are required" >&2
  usage
  exit 1
fi

STATE_DIR=".telemetry"
STATE_FILE="${STATE_DIR}/${BATCH_ID}.json"
mkdir -p "${STATE_DIR}"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command '$1' not found" >&2
    exit 1
  }
}
require psql
require jq

# Auto-detect PostgreSQL major version
detect_pg_version() {
  local ver
  ver=$(psql -X -q -t -A -c "SHOW server_version_num" 2>/dev/null) || {
    echo "ERROR: Could not connect to database to detect PostgreSQL version" >&2
    echo "Ensure PGHOST, PGUSER, PGDATABASE etc. are set or .pgpass is configured" >&2
    exit 1
  }
  if [[ -z "$ver" ]]; then
    echo "ERROR: Could not determine PostgreSQL version" >&2
    exit 1
  fi
  # server_version_num is like 170004 (PG17), 160000 (PG16), 150005 (PG15)
  echo $(( ver / 10000 ))
}

PGVER=$(detect_pg_version)

if [[ "${PGVER}" -lt 15 || "${PGVER}" -gt 17 ]]; then
  echo "ERROR: PostgreSQL ${PGVER} is not supported (requires 15, 16, or 17)" >&2
  exit 1
fi

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

header() {
  echo
  echo "====================================================================="
  echo "Batch Telemetry | $1 | pg=${PGVER} | batch_id=${BATCH_ID}"
  [[ -n "${TARGET_TABLE}" ]] && echo "Target table: ${TARGET_TABLE}"
  echo "Timestamp: $(timestamp)"
  echo "====================================================================="
}

psql_json() { psql -X -q -t -A "$@"; }
psql_tbl()  { psql -X "$@"; }

capture_settings() {
  psql_json <<'SQL'
SELECT json_build_object(
  'server_version_num', current_setting('server_version_num', true),
  'server_version',     current_setting('server_version', true),

  'max_wal_size',       current_setting('max_wal_size', true),
  'checkpoint_timeout', current_setting('checkpoint_timeout', true),
  'checkpoint_completion_target', current_setting('checkpoint_completion_target', true),
  'synchronous_commit', current_setting('synchronous_commit', true),

  'wal_compression',    current_setting('wal_compression', true),
  'full_page_writes',   current_setting('full_page_writes', true)
);
SQL
}

capture_wal() {
  psql_json <<'SQL'
SELECT row_to_json(t)
FROM (
  SELECT
    wal_records,
    wal_fpi,
    wal_bytes,
    wal_write,
    wal_sync,
    wal_write_time,
    wal_sync_time
  FROM pg_stat_wal
) t;
SQL
}

capture_slots() {
  psql_json <<'SQL'
SELECT COALESCE(json_agg(t ORDER BY retained_wal_bytes DESC), '[]'::json)
FROM (
  SELECT
    slot_name,
    slot_type,
    active,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_wal_bytes
  FROM pg_replication_slots
) t;
SQL
}

# PG15/PG17 variants
capture_bgwriter_15() {
  psql_json <<'SQL'
SELECT row_to_json(t)
FROM (
  SELECT
    checkpoints_timed,
    checkpoints_req,
    checkpoint_write_time,
    checkpoint_sync_time,
    buffers_checkpoint,
    buffers_clean,
    maxwritten_clean,
    buffers_backend,
    buffers_backend_fsync,
    buffers_alloc,
    stats_reset
  FROM pg_stat_bgwriter
) t;
SQL
}

capture_bgwriter_17() {
  psql_json <<'SQL'
SELECT row_to_json(t)
FROM (
  SELECT
    buffers_clean,
    maxwritten_clean,
    buffers_alloc,
    stats_reset
  FROM pg_stat_bgwriter
) t;
SQL
}

capture_checkpointer_17() {
  psql_json <<'SQL'
SELECT row_to_json(t)
FROM (
  SELECT
    num_timed,
    num_requested,
    restartpoints_timed,
    restartpoints_req,
    restartpoints_done,
    write_time,
    sync_time,
    buffers_written,
    stats_reset
  FROM pg_stat_checkpointer
) t;
SQL
}

# pg_stat_io (PG16+) - I/O stats by backend type
capture_io_16() {
  psql_json <<'SQL'
SELECT COALESCE(json_agg(t), '[]'::json)
FROM (
  SELECT
    backend_type,
    object,
    context,
    reads,
    writes,
    extends,
    fsyncs,
    read_time,
    write_time,
    extend_time,
    fsync_time
  FROM pg_stat_io
  WHERE writes > 0 OR fsyncs > 0 OR reads > 0
  ORDER BY writes DESC, fsyncs DESC
) t;
SQL
}

# Checkpoint timing info
capture_checkpoint_info() {
  psql_json <<'SQL'
SELECT json_build_object(
  'current_wal_lsn',  pg_current_wal_lsn()::text,
  'checkpoint_lsn',   (pg_control_checkpoint()).redo_lsn::text,
  'checkpoint_time',  (pg_control_checkpoint()).checkpoint_time::text
);
SQL
}

# Autovacuum settings
capture_autovacuum_settings() {
  psql_json <<'SQL'
SELECT json_build_object(
  'autovacuum',                     current_setting('autovacuum', true),
  'autovacuum_naptime',             current_setting('autovacuum_naptime', true),
  'autovacuum_vacuum_cost_limit',   current_setting('autovacuum_vacuum_cost_limit', true),
  'autovacuum_vacuum_cost_delay',   current_setting('autovacuum_vacuum_cost_delay', true),
  'autovacuum_vacuum_threshold',    current_setting('autovacuum_vacuum_threshold', true),
  'autovacuum_vacuum_scale_factor', current_setting('autovacuum_vacuum_scale_factor', true),
  'autovacuum_analyze_threshold',   current_setting('autovacuum_analyze_threshold', true),
  'autovacuum_analyze_scale_factor',current_setting('autovacuum_analyze_scale_factor', true)
);
SQL
}

# Table-specific stats (when --table is provided)
capture_table_stats() {
  local tbl="$1"
  psql_json -v tbl="$tbl" <<'SQL'
SELECT json_build_object(
  'relname',              :'tbl',
  'pg_relation_size',     pg_relation_size(:'tbl'::regclass),
  'pg_total_relation_size', pg_total_relation_size(:'tbl'::regclass),
  'pg_indexes_size',      pg_indexes_size(:'tbl'::regclass),
  'n_live_tup',           s.n_live_tup,
  'n_dead_tup',           s.n_dead_tup,
  'n_tup_ins',            s.n_tup_ins,
  'n_tup_upd',            s.n_tup_upd,
  'n_tup_del',            s.n_tup_del,
  'n_tup_hot_upd',        s.n_tup_hot_upd,
  'last_vacuum',          s.last_vacuum,
  'last_autovacuum',      s.last_autovacuum,
  'last_analyze',         s.last_analyze,
  'last_autoanalyze',     s.last_autoanalyze,
  'vacuum_count',         s.vacuum_count,
  'autovacuum_count',     s.autovacuum_count,
  'analyze_count',        s.analyze_count,
  'autoanalyze_count',    s.autoanalyze_count
)
FROM pg_stat_user_tables s
WHERE s.relname = :'tbl';
SQL
}

# Sampling queries (common)
sample_waits() {
  psql_tbl <<'SQL'
\pset pager off
SELECT
  now() AS ts,
  backend_type,
  wait_event_type,
  wait_event,
  count(*) AS backends
FROM pg_stat_activity
WHERE state <> 'idle'
GROUP BY 1,2,3,4
ORDER BY backends DESC, backend_type;
SQL
}

sample_activity() {
  psql_tbl <<'SQL'
\pset pager off
SELECT
  now() AS ts,
  pid,
  usename,
  backend_type,
  state,
  wait_event_type,
  wait_event,
  now() - query_start AS running_for,
  left(query, 200) AS query_200
FROM pg_stat_activity
WHERE state <> 'idle'
ORDER BY running_for DESC
LIMIT 15;
SQL
}

sample_vacuum() {
  psql_tbl <<'SQL'
\pset pager off
SELECT
  now() AS ts,
  p.pid,
  p.relid::regclass AS rel,
  p.phase,
  p.heap_blks_total,
  p.heap_blks_scanned,
  p.heap_blks_vacuumed,
  p.index_vacuum_count,
  now() - a.query_start AS running_for
FROM pg_stat_progress_vacuum p
JOIN pg_stat_activity a ON a.pid = p.pid
ORDER BY running_for DESC;
SQL
}

sample_copy() {
  psql_tbl <<'SQL'
\pset pager off
SELECT
  now() AS ts,
  p.pid,
  p.relid::regclass AS rel,
  p.command,
  p.type,
  p.bytes_processed,
  p.bytes_total,
  p.tuples_processed,
  p.tuples_excluded,
  now() - a.query_start AS running_for
FROM pg_stat_progress_copy p
JOIN pg_stat_activity a ON a.pid = p.pid
ORDER BY running_for DESC;
SQL
}

# Sample pg_stat_io snapshot (for point-in-time I/O by backend type)
sample_io() {
  psql_tbl <<'SQL'
\pset pager off
SELECT
  now() AS ts,
  backend_type,
  object,
  context,
  reads,
  writes,
  fsyncs,
  round(read_time::numeric, 2) AS read_time_ms,
  round(write_time::numeric, 2) AS write_time_ms,
  round(fsync_time::numeric, 2) AS fsync_time_ms
FROM pg_stat_io
WHERE writes > 0 OR fsyncs > 0 OR reads > 1000
ORDER BY writes DESC, fsyncs DESC
LIMIT 20;
SQL
}

case "${CMD}" in
  start)
    header "START"

    # Common captures for all versions
    SETTINGS="$(capture_settings)"
    WAL="$(capture_wal)"
    SLOTS="$(capture_slots)"
    CKPT_INFO="$(capture_checkpoint_info)"
    AV_SETTINGS="$(capture_autovacuum_settings)"

    echo "$SETTINGS"    | jq -e . >/dev/null
    echo "$WAL"         | jq -e . >/dev/null
    echo "$SLOTS"       | jq -e . >/dev/null
    echo "$CKPT_INFO"   | jq -e . >/dev/null
    echo "$AV_SETTINGS" | jq -e . >/dev/null

    # Optional table stats
    if [[ -n "${TARGET_TABLE}" ]]; then
      TBL_STATS="$(capture_table_stats "${TARGET_TABLE}")"
      echo "$TBL_STATS" | jq -e . >/dev/null
    else
      TBL_STATS="null"
    fi

    # Version-specific captures
    if [[ "${PGVER}" == "15" ]]; then
      # PG15: bgwriter has checkpoint stats, no pg_stat_io
      BGW="$(capture_bgwriter_15)"
      echo "$BGW" | jq -e . >/dev/null

      jq -n \
        --arg pg "${PGVER}" \
        --arg batch_id "${BATCH_ID}" \
        --arg target_table "${TARGET_TABLE:-}" \
        --arg note "${NOTE:-}" \
        --arg started_at "$(timestamp)" \
        --argjson settings "$SETTINGS" \
        --argjson autovacuum_settings "$AV_SETTINGS" \
        --argjson checkpoint_info_start "$CKPT_INFO" \
        --argjson bgw "$BGW" \
        --argjson wal "$WAL" \
        --argjson slots "$SLOTS" \
        --argjson table_start "$TBL_STATS" \
        '{
          pg: $pg,
          batch_id: $batch_id,
          target_table: $target_table,
          note: $note,
          started_at: $started_at,
          settings: $settings,
          autovacuum_settings: $autovacuum_settings,
          checkpoint_info_start: $checkpoint_info_start,
          bgw_start: $bgw,
          wal_start: $wal,
          slots_start: $slots,
          table_start: $table_start
        }' | tee "$STATE_FILE"

    elif [[ "${PGVER}" == "16" ]]; then
      # PG16: bgwriter has checkpoint stats, pg_stat_io available
      BGW="$(capture_bgwriter_15)"
      IO="$(capture_io_16)"
      echo "$BGW" | jq -e . >/dev/null
      echo "$IO"  | jq -e . >/dev/null

      jq -n \
        --arg pg "${PGVER}" \
        --arg batch_id "${BATCH_ID}" \
        --arg target_table "${TARGET_TABLE:-}" \
        --arg note "${NOTE:-}" \
        --arg started_at "$(timestamp)" \
        --argjson settings "$SETTINGS" \
        --argjson autovacuum_settings "$AV_SETTINGS" \
        --argjson checkpoint_info_start "$CKPT_INFO" \
        --argjson bgw "$BGW" \
        --argjson io "$IO" \
        --argjson wal "$WAL" \
        --argjson slots "$SLOTS" \
        --argjson table_start "$TBL_STATS" \
        '{
          pg: $pg,
          batch_id: $batch_id,
          target_table: $target_table,
          note: $note,
          started_at: $started_at,
          settings: $settings,
          autovacuum_settings: $autovacuum_settings,
          checkpoint_info_start: $checkpoint_info_start,
          bgw_start: $bgw,
          io_start: $io,
          wal_start: $wal,
          slots_start: $slots,
          table_start: $table_start
        }' | tee "$STATE_FILE"

    else
      # PG17: checkpointer split out, pg_stat_io available
      BGW="$(capture_bgwriter_17)"
      CKP="$(capture_checkpointer_17)"
      IO="$(capture_io_16)"
      echo "$BGW" | jq -e . >/dev/null
      echo "$CKP" | jq -e . >/dev/null
      echo "$IO"  | jq -e . >/dev/null

      jq -n \
        --arg pg "${PGVER}" \
        --arg batch_id "${BATCH_ID}" \
        --arg target_table "${TARGET_TABLE:-}" \
        --arg note "${NOTE:-}" \
        --arg started_at "$(timestamp)" \
        --argjson settings "$SETTINGS" \
        --argjson autovacuum_settings "$AV_SETTINGS" \
        --argjson checkpoint_info_start "$CKPT_INFO" \
        --argjson bgw "$BGW" \
        --argjson ckp "$CKP" \
        --argjson io "$IO" \
        --argjson wal "$WAL" \
        --argjson slots "$SLOTS" \
        --argjson table_start "$TBL_STATS" \
        '{
          pg: $pg,
          batch_id: $batch_id,
          target_table: $target_table,
          note: $note,
          started_at: $started_at,
          settings: $settings,
          autovacuum_settings: $autovacuum_settings,
          checkpoint_info_start: $checkpoint_info_start,
          bgw_start: $bgw,
          ckp_start: $ckp,
          io_start: $io,
          wal_start: $wal,
          slots_start: $slots,
          table_start: $table_start
        }' | tee "$STATE_FILE"
    fi

    echo
    echo "State saved to: $STATE_FILE"
    ;;

  sample)
    header "SAMPLE"

    echo
    echo "-- Wait event summary --"
    sample_waits

    echo
    echo "-- Top active sessions --"
    sample_activity

    echo
    echo "-- Autovacuum progress --"
    sample_vacuum

    echo
    echo "-- COPY progress --"
    sample_copy

    # pg_stat_io only available on PG16+
    if [[ "${PGVER}" != "15" ]]; then
      echo
      echo "-- I/O by backend type (pg_stat_io) --"
      sample_io
    fi
    ;;

  end)
    [[ -f "$STATE_FILE" ]] || { echo "ERROR: no state file found: $STATE_FILE (did you run start?)" >&2; exit 1; }
    header "END"

    # Common captures for all versions
    WAL_END="$(capture_wal)"
    SLOTS_END="$(capture_slots)"
    CKPT_INFO_END="$(capture_checkpoint_info)"
    echo "$WAL_END"       | jq -e . >/dev/null
    echo "$SLOTS_END"     | jq -e . >/dev/null
    echo "$CKPT_INFO_END" | jq -e . >/dev/null

    # Optional table stats (get target_table from state file)
    STORED_TABLE="$(jq -r '.target_table // ""' "$STATE_FILE")"
    if [[ -n "${STORED_TABLE}" ]]; then
      TBL_STATS_END="$(capture_table_stats "${STORED_TABLE}")"
      echo "$TBL_STATS_END" | jq -e . >/dev/null
    else
      TBL_STATS_END="null"
    fi

    TMP="${STATE_FILE}.tmp"

    if [[ "${PGVER}" == "15" ]]; then
      # PG15: bgwriter has checkpoint stats, no pg_stat_io
      BGW_END="$(capture_bgwriter_15)"
      echo "$BGW_END" | jq -e . >/dev/null

      jq \
        --arg ended_at "$(timestamp)" \
        --argjson checkpoint_info_end "$CKPT_INFO_END" \
        --argjson bgw_end "$BGW_END" \
        --argjson wal_end "$WAL_END" \
        --argjson slots_end "$SLOTS_END" \
        --argjson table_end "$TBL_STATS_END" \
        '. + {
          ended_at: $ended_at,
          checkpoint_info_end: $checkpoint_info_end,
          bgw_end: $bgw_end,
          wal_end: $wal_end,
          slots_end: $slots_end,
          table_end: $table_end
        }' "$STATE_FILE" | tee "$TMP" && mv "$TMP" "$STATE_FILE"

    elif [[ "${PGVER}" == "16" ]]; then
      # PG16: bgwriter has checkpoint stats, pg_stat_io available
      BGW_END="$(capture_bgwriter_15)"
      IO_END="$(capture_io_16)"
      echo "$BGW_END" | jq -e . >/dev/null
      echo "$IO_END"  | jq -e . >/dev/null

      jq \
        --arg ended_at "$(timestamp)" \
        --argjson checkpoint_info_end "$CKPT_INFO_END" \
        --argjson bgw_end "$BGW_END" \
        --argjson io_end "$IO_END" \
        --argjson wal_end "$WAL_END" \
        --argjson slots_end "$SLOTS_END" \
        --argjson table_end "$TBL_STATS_END" \
        '. + {
          ended_at: $ended_at,
          checkpoint_info_end: $checkpoint_info_end,
          bgw_end: $bgw_end,
          io_end: $io_end,
          wal_end: $wal_end,
          slots_end: $slots_end,
          table_end: $table_end
        }' "$STATE_FILE" | tee "$TMP" && mv "$TMP" "$STATE_FILE"

    else
      # PG17: checkpointer split out, pg_stat_io available
      BGW_END="$(capture_bgwriter_17)"
      CKP_END="$(capture_checkpointer_17)"
      IO_END="$(capture_io_16)"
      echo "$BGW_END" | jq -e . >/dev/null
      echo "$CKP_END" | jq -e . >/dev/null
      echo "$IO_END"  | jq -e . >/dev/null

      jq \
        --arg ended_at "$(timestamp)" \
        --argjson checkpoint_info_end "$CKPT_INFO_END" \
        --argjson bgw_end "$BGW_END" \
        --argjson ckp_end "$CKP_END" \
        --argjson io_end "$IO_END" \
        --argjson wal_end "$WAL_END" \
        --argjson slots_end "$SLOTS_END" \
        --argjson table_end "$TBL_STATS_END" \
        '. + {
          ended_at: $ended_at,
          checkpoint_info_end: $checkpoint_info_end,
          bgw_end: $bgw_end,
          ckp_end: $ckp_end,
          io_end: $io_end,
          wal_end: $wal_end,
          slots_end: $slots_end,
          table_end: $table_end
        }' "$STATE_FILE" | tee "$TMP" && mv "$TMP" "$STATE_FILE"
    fi
    ;;

  report)
    [[ -f "$STATE_FILE" ]] || { echo "ERROR: no state file found: $STATE_FILE" >&2; exit 1; }
    header "REPORT (DELTAS)"

    if [[ "${PGVER}" == "15" ]]; then
      # PG15 report
      jq -r '
        def dur_s: ((.ended_at|fromdateiso8601) - (.started_at|fromdateiso8601));
        def fmt_bytes: . as $b |
          if $b >= 1073741824 then "\(($b/1073741824*100|floor)/100) GB"
          elif $b >= 1048576 then "\(($b/1048576*100|floor)/100) MB"
          elif $b >= 1024 then "\(($b/1024*100|floor)/100) KB"
          else "\($b) B" end;
        {
          "=== BATCH INFO ===": null,
          pg: .pg,
          batch_id: .batch_id,
          target_table: .target_table,
          note: .note,
          started_at: .started_at,
          ended_at: .ended_at,
          elapsed_seconds: dur_s,

          "=== CHECKPOINT INFO ===": null,
          checkpoint_occurred: (.checkpoint_info_start.checkpoint_time != .checkpoint_info_end.checkpoint_time),
          checkpoint_time_start: .checkpoint_info_start.checkpoint_time,
          checkpoint_time_end: .checkpoint_info_end.checkpoint_time,

          "=== CHECKPOINT STATS (bgwriter) ===": null,
          checkpoints_timed_delta:        (.bgw_end.checkpoints_timed - .bgw_start.checkpoints_timed),
          checkpoints_req_delta:          (.bgw_end.checkpoints_req - .bgw_start.checkpoints_req),
          buffers_checkpoint_delta:       (.bgw_end.buffers_checkpoint - .bgw_start.buffers_checkpoint),
          checkpoint_write_time_ms_delta: (.bgw_end.checkpoint_write_time - .bgw_start.checkpoint_write_time),
          checkpoint_sync_time_ms_delta:  (.bgw_end.checkpoint_sync_time - .bgw_start.checkpoint_sync_time),

          "=== BGWRITER STATS ===": null,
          buffers_clean_delta:            (.bgw_end.buffers_clean - .bgw_start.buffers_clean),
          maxwritten_clean_delta:         (.bgw_end.maxwritten_clean - .bgw_start.maxwritten_clean),
          buffers_backend_delta:          (.bgw_end.buffers_backend - .bgw_start.buffers_backend),
          buffers_backend_fsync_delta:    (.bgw_end.buffers_backend_fsync - .bgw_start.buffers_backend_fsync),
          buffers_alloc_delta:            (.bgw_end.buffers_alloc - .bgw_start.buffers_alloc),

          "=== WAL STATS ===": null,
          wal_bytes_delta:                (.wal_end.wal_bytes - .wal_start.wal_bytes),
          wal_bytes_delta_human:          ((.wal_end.wal_bytes - .wal_start.wal_bytes) | fmt_bytes),
          wal_write_time_ms_delta:        (.wal_end.wal_write_time - .wal_start.wal_write_time),
          wal_sync_time_ms_delta:         (.wal_end.wal_sync_time - .wal_start.wal_sync_time)
        }
        + if .table_start != null and .table_end != null then {
          "=== TABLE STATS ===": null,
          table_name: .table_start.relname,
          table_size_start: (.table_start.pg_relation_size | fmt_bytes),
          table_size_end: (.table_end.pg_relation_size | fmt_bytes),
          table_size_delta: ((.table_end.pg_relation_size - .table_start.pg_relation_size) | fmt_bytes),
          total_size_delta: ((.table_end.pg_total_relation_size - .table_start.pg_total_relation_size) | fmt_bytes),
          n_tup_ins_delta: (.table_end.n_tup_ins - .table_start.n_tup_ins),
          n_dead_tup_end: .table_end.n_dead_tup,
          autovacuum_count_delta: (.table_end.autovacuum_count - .table_start.autovacuum_count),
          autoanalyze_count_delta: (.table_end.autoanalyze_count - .table_start.autoanalyze_count)
        } else {} end
        + {
          "=== SETTINGS (reference) ===": null,
          settings: .settings,
          autovacuum_settings: .autovacuum_settings
        }' "$STATE_FILE"

    elif [[ "${PGVER}" == "16" ]]; then
      # PG16 report (bgwriter has checkpoint stats, pg_stat_io available)
      jq -r '
        def dur_s: ((.ended_at|fromdateiso8601) - (.started_at|fromdateiso8601));
        def fmt_bytes: . as $b |
          if $b >= 1073741824 then "\(($b/1073741824*100|floor)/100) GB"
          elif $b >= 1048576 then "\(($b/1048576*100|floor)/100) MB"
          elif $b >= 1024 then "\(($b/1024*100|floor)/100) KB"
          else "\($b) B" end;
        {
          "=== BATCH INFO ===": null,
          pg: .pg,
          batch_id: .batch_id,
          target_table: .target_table,
          note: .note,
          started_at: .started_at,
          ended_at: .ended_at,
          elapsed_seconds: dur_s,

          "=== CHECKPOINT INFO ===": null,
          checkpoint_occurred: (.checkpoint_info_start.checkpoint_time != .checkpoint_info_end.checkpoint_time),
          checkpoint_time_start: .checkpoint_info_start.checkpoint_time,
          checkpoint_time_end: .checkpoint_info_end.checkpoint_time,

          "=== CHECKPOINT STATS (bgwriter) ===": null,
          checkpoints_timed_delta:        (.bgw_end.checkpoints_timed - .bgw_start.checkpoints_timed),
          checkpoints_req_delta:          (.bgw_end.checkpoints_req - .bgw_start.checkpoints_req),
          buffers_checkpoint_delta:       (.bgw_end.buffers_checkpoint - .bgw_start.buffers_checkpoint),
          checkpoint_write_time_ms_delta: (.bgw_end.checkpoint_write_time - .bgw_start.checkpoint_write_time),
          checkpoint_sync_time_ms_delta:  (.bgw_end.checkpoint_sync_time - .bgw_start.checkpoint_sync_time),

          "=== BGWRITER STATS ===": null,
          buffers_clean_delta:            (.bgw_end.buffers_clean - .bgw_start.buffers_clean),
          maxwritten_clean_delta:         (.bgw_end.maxwritten_clean - .bgw_start.maxwritten_clean),
          buffers_backend_delta:          (.bgw_end.buffers_backend - .bgw_start.buffers_backend),
          buffers_backend_fsync_delta:    (.bgw_end.buffers_backend_fsync - .bgw_start.buffers_backend_fsync),
          buffers_alloc_delta:            (.bgw_end.buffers_alloc - .bgw_start.buffers_alloc),

          "=== WAL STATS ===": null,
          wal_bytes_delta:                (.wal_end.wal_bytes - .wal_start.wal_bytes),
          wal_bytes_delta_human:          ((.wal_end.wal_bytes - .wal_start.wal_bytes) | fmt_bytes),
          wal_write_time_ms_delta:        (.wal_end.wal_write_time - .wal_start.wal_write_time),
          wal_sync_time_ms_delta:         (.wal_end.wal_sync_time - .wal_start.wal_sync_time)
        }
        + if .table_start != null and .table_end != null then {
          "=== TABLE STATS ===": null,
          table_name: .table_start.relname,
          table_size_start: (.table_start.pg_relation_size | fmt_bytes),
          table_size_end: (.table_end.pg_relation_size | fmt_bytes),
          table_size_delta: ((.table_end.pg_relation_size - .table_start.pg_relation_size) | fmt_bytes),
          total_size_delta: ((.table_end.pg_total_relation_size - .table_start.pg_total_relation_size) | fmt_bytes),
          n_tup_ins_delta: (.table_end.n_tup_ins - .table_start.n_tup_ins),
          n_dead_tup_end: .table_end.n_dead_tup,
          autovacuum_count_delta: (.table_end.autovacuum_count - .table_start.autovacuum_count),
          autoanalyze_count_delta: (.table_end.autoanalyze_count - .table_start.autoanalyze_count)
        } else {} end
        + {
          "=== SETTINGS (reference) ===": null,
          settings: .settings,
          autovacuum_settings: .autovacuum_settings
        }' "$STATE_FILE"

      # pg_stat_io summary for PG16
      echo
      echo "=== I/O BY BACKEND TYPE (pg_stat_io end snapshot) ==="
      jq -r '
        .io_end | if . and length > 0 then
          .[] | select(.writes > 0 or .fsyncs > 0) |
          "  \(.backend_type)/\(.object)/\(.context): writes=\(.writes) fsyncs=\(.fsyncs) write_time=\(.write_time // 0)ms fsync_time=\(.fsync_time // 0)ms"
        else
          "  (no significant I/O recorded)"
        end
      ' "$STATE_FILE"

    else
      # PG17 report (checkpointer split out, pg_stat_io available)
      jq -r '
        def dur_s: ((.ended_at|fromdateiso8601) - (.started_at|fromdateiso8601));
        def fmt_bytes: . as $b |
          if $b >= 1073741824 then "\(($b/1073741824*100|floor)/100) GB"
          elif $b >= 1048576 then "\(($b/1048576*100|floor)/100) MB"
          elif $b >= 1024 then "\(($b/1024*100|floor)/100) KB"
          else "\($b) B" end;
        {
          "=== BATCH INFO ===": null,
          pg: .pg,
          batch_id: .batch_id,
          target_table: .target_table,
          note: .note,
          started_at: .started_at,
          ended_at: .ended_at,
          elapsed_seconds: dur_s,

          "=== CHECKPOINT INFO ===": null,
          checkpoint_occurred: (.checkpoint_info_start.checkpoint_time != .checkpoint_info_end.checkpoint_time),
          checkpoint_time_start: .checkpoint_info_start.checkpoint_time,
          checkpoint_time_end: .checkpoint_info_end.checkpoint_time,

          "=== CHECKPOINTER STATS ===": null,
          checkpointer_num_timed_delta:       (.ckp_end.num_timed - .ckp_start.num_timed),
          checkpointer_num_requested_delta:   (.ckp_end.num_requested - .ckp_start.num_requested),
          checkpointer_write_time_ms_delta:   (.ckp_end.write_time - .ckp_start.write_time),
          checkpointer_sync_time_ms_delta:    (.ckp_end.sync_time - .ckp_start.sync_time),
          checkpointer_buffers_written_delta: (.ckp_end.buffers_written - .ckp_start.buffers_written),

          "=== BGWRITER STATS ===": null,
          bgwriter_buffers_clean_delta:    (.bgw_end.buffers_clean - .bgw_start.buffers_clean),
          bgwriter_maxwritten_clean_delta: (.bgw_end.maxwritten_clean - .bgw_start.maxwritten_clean),
          bgwriter_buffers_alloc_delta:    (.bgw_end.buffers_alloc - .bgw_start.buffers_alloc),

          "=== WAL STATS ===": null,
          wal_bytes_delta:                 (.wal_end.wal_bytes - .wal_start.wal_bytes),
          wal_bytes_delta_human:           ((.wal_end.wal_bytes - .wal_start.wal_bytes) | fmt_bytes),
          wal_write_time_ms_delta:         (.wal_end.wal_write_time - .wal_start.wal_write_time),
          wal_sync_time_ms_delta:          (.wal_end.wal_sync_time - .wal_start.wal_sync_time)
        }
        + if .table_start != null and .table_end != null then {
          "=== TABLE STATS ===": null,
          table_name: .table_start.relname,
          table_size_start: (.table_start.pg_relation_size | fmt_bytes),
          table_size_end: (.table_end.pg_relation_size | fmt_bytes),
          table_size_delta: ((.table_end.pg_relation_size - .table_start.pg_relation_size) | fmt_bytes),
          total_size_delta: ((.table_end.pg_total_relation_size - .table_start.pg_total_relation_size) | fmt_bytes),
          n_tup_ins_delta: (.table_end.n_tup_ins - .table_start.n_tup_ins),
          n_dead_tup_end: .table_end.n_dead_tup,
          autovacuum_count_delta: (.table_end.autovacuum_count - .table_start.autovacuum_count),
          autoanalyze_count_delta: (.table_end.autoanalyze_count - .table_start.autoanalyze_count)
        } else {} end
        + {
          "=== SETTINGS (reference) ===": null,
          settings: .settings,
          autovacuum_settings: .autovacuum_settings
        }' "$STATE_FILE"

      # pg_stat_io summary for PG17
      echo
      echo "=== I/O BY BACKEND TYPE (pg_stat_io end snapshot) ==="
      jq -r '
        .io_end | if . and length > 0 then
          .[] | select(.writes > 0 or .fsyncs > 0) |
          "  \(.backend_type)/\(.object)/\(.context): writes=\(.writes) fsyncs=\(.fsyncs) write_time=\(.write_time // 0)ms fsync_time=\(.fsync_time // 0)ms"
        else
          "  (no significant I/O recorded)"
        end
      ' "$STATE_FILE"
    fi

    echo
    echo "====================================================================="
    echo "Interpretation Guide:"
    echo "====================================================================="
    echo "CHECKPOINT PRESSURE:"
    echo "  - checkpoint_occurred=true + large write/sync time deltas => checkpoint during batch"
    echo "  - checkpoints_req_delta > 0 => forced checkpoint (WAL volume exceeded max_wal_size)"
    echo
    echo "AUTOVACUUM INTERFERENCE:"
    echo "  - autovacuum_count_delta > 0 => autovacuum ran on target table during batch"
    echo "  - Check SAMPLE output for pg_stat_progress_vacuum entries"
    echo
    echo "WAL PRESSURE:"
    echo "  - large wal_sync_time_ms_delta => WAL fsync bottleneck"
    echo "  - Compare wal_bytes_delta to expected (row_count * avg_row_size)"
    echo
    echo "BACKEND I/O (PG15 only):"
    echo "  - buffers_backend_delta > 0 => backends writing directly (shared_buffers pressure)"
    echo "  - buffers_backend_fsync_delta > 0 => backends doing fsync (very bad)"
    echo
    echo "pg_stat_io (PG16+):"
    echo "  - High checkpointer writes/fsync_time => checkpoint I/O pressure"
    echo "  - High 'autovacuum worker' writes => vacuum competing for I/O"
    echo "  - High 'client backend' writes => shared_buffers exhaustion"
    ;;

  *)
    echo "ERROR: unknown command: ${CMD}" >&2
    usage
    exit 1
    ;;
esac
