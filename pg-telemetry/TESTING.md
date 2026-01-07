# pg-flight-recorder Testing Report

## Test Environment
- **PostgreSQL Version:** 17.6
- **Platform:** Supabase
- **Test Date:** 2026-01-06
- **Extensions:** pg_cron 1.6.4, pg_stat_statements 1.11

## Installation Test Results

### ✅ Successful
- Schema and all 11 tables created
- All 19 functions created
- All 7 views created
- pg_cron jobs scheduled correctly:
  - `flight_recorder_snapshot`: every 5 minutes
  - `flight_recorder_sample`: every 30 seconds
  - `flight_recorder_cleanup`: daily at 3 AM

### ⚠️  PostgreSQL 17 Compatibility Issue Found and Fixed

**Issue:** The initial `sample()` function failed with:
```
ERROR: column p.max_dead_tuples does not exist
```

**Root Cause:** PostgreSQL 17 changed `pg_stat_progress_vacuum` columns:
- `max_dead_tuples` → `max_dead_tuple_bytes`
- `num_dead_tuples` → `dead_tuple_bytes`

**Fix Applied:** Updated `sample()` function to detect PG version and use appropriate column names:
- PG15/16: Uses `max_dead_tuples`, `num_dead_tuples`
- PG17: Uses `max_dead_tuple_bytes`, `dead_tuple_bytes`, `num_dead_item_ids`

**Fix Location:** `/pg-flight-recorder/sql/fix_pg17_sample.sql`

## Functionality Tests

### ✅ Data Collection
- Snapshots collected every 5 minutes
- Samples collected every 30 seconds
- Wait events captured successfully
- Activity samples captured
- Lock samples working
- Progress samples working

### ✅ Analysis Functions Tested

1. **`compare(start, end)`** - ✅ Working
   - Correctly compares system stats between time points
   - Shows checkpoint occurrence, WAL generation, buffer stats
   - Handles PG17's pg_stat_bgwriter changes (NULL for removed columns)

2. **`wait_summary(start, end)`** - ✅ Working
   - Aggregates wait events over time periods
   - Shows backend types and wait event distribution

3. **`activity_at(timestamp)`** - ✅ Working
   - Shows system state at specific moment
   - Includes active sessions, wait events, operations in progress
   - Identifies nearby checkpoints

4. **`summary_report(start, end)`** - ✅ Working
   - Comprehensive diagnostic output
   - Detects anomalies automatically
   - Clear interpretation of metrics

5. **`anomaly_report(start, end)`** - ✅ Working
   - Detects 6 types of performance issues
   - Provides severity levels and recommendations

### ✅ Views Tested
- `deltas` - Shows snapshot-to-snapshot changes
- `recent_waits` - Rolling 2-hour wait events
- `recent_activity` - Active sessions
- All other views created and queryable

### ✅ Configuration Functions
- `get_mode()` - Shows current collection mode
- `set_mode(mode)` - Allows switching between normal/light/emergency modes

## Sample Output

### System Comparison (165 second window)
```
checkpoint_occurred: true
ckpt_write_time_ms: 22979
wal_bytes_delta: 451887 (441.30 KB)
bgw_buffers_alloc_delta: 28
temp_files_delta: 0
```

### Summary Report
```
OVERVIEW:
  - Time Window: 165.6 seconds elapsed
  - Data Coverage: OK
  - Anomalies Detected: 1 (Checkpoint occurred)

CHECKPOINT & WAL:
  - Checkpoint Occurred: true (write: 22979 ms)
  - WAL Generated: 441.30 KB

BUFFERS & I/O:
  - Buffers Allocated: 28
  - Backend Buffer Writes: OK (no pressure)
  - Temp File Spills: 0 files

LOCK CONTENTION:
  - Blocked Sessions: 0
```

## Recommendations

1. **Apply PG17 Fix:** The `fix_pg17_sample.sql` should be merged into `install.sql` to make it PG17-compatible out of the box.

2. **Update Install Script:** Add version detection in the `sample()` function within `install.sql` (lines 753-773) to match the fix in `fix_pg17_sample.sql`.

3. **Consider NULL Handling:** The PG17 snapshot() function correctly sets `bgw_buffers_backend` and `bgw_buffers_backend_fsync` to NULL since these columns don't exist in PG17. This is working as expected.

## Conclusion

✅ **pg-flight-recorder is fully functional on PostgreSQL 17.6** after applying the PG17 compatibility fix. All core features work as documented:
- Automatic data collection via pg_cron
- Comprehensive system metrics
- Analysis functions for performance diagnostics
- Anomaly detection
- Flexible configuration modes

The tool successfully provides ASH-like functionality on managed PostgreSQL platforms without requiring custom extensions.
