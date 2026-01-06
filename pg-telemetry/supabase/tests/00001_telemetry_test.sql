-- =============================================================================
-- pg-telemetry pgTAP Tests
-- =============================================================================
-- Comprehensive test suite for pg-telemetry functionality
-- Run with: supabase test db
-- =============================================================================

BEGIN;
SELECT plan(67);  -- Total number of tests

-- =============================================================================
-- 1. INSTALLATION VERIFICATION (15 tests)
-- =============================================================================

-- Test schema exists
SELECT has_schema('telemetry', 'Schema telemetry should exist');

-- Test all 11 tables exist
SELECT has_table('telemetry', 'snapshots', 'Table telemetry.snapshots should exist');
SELECT has_table('telemetry', 'tracked_tables', 'Table telemetry.tracked_tables should exist');
SELECT has_table('telemetry', 'table_snapshots', 'Table telemetry.table_snapshots should exist');
SELECT has_table('telemetry', 'replication_snapshots', 'Table telemetry.replication_snapshots should exist');
SELECT has_table('telemetry', 'statement_snapshots', 'Table telemetry.statement_snapshots should exist');
SELECT has_table('telemetry', 'samples', 'Table telemetry.samples should exist');
SELECT has_table('telemetry', 'wait_samples', 'Table telemetry.wait_samples should exist');
SELECT has_table('telemetry', 'activity_samples', 'Table telemetry.activity_samples should exist');
SELECT has_table('telemetry', 'progress_samples', 'Table telemetry.progress_samples should exist');
SELECT has_table('telemetry', 'lock_samples', 'Table telemetry.lock_samples should exist');
SELECT has_table('telemetry', 'config', 'Table telemetry.config should exist');

-- Test all 7 views exist
SELECT has_view('telemetry', 'deltas', 'View telemetry.deltas should exist');
SELECT has_view('telemetry', 'table_deltas', 'View telemetry.table_deltas should exist');
SELECT has_view('telemetry', 'recent_waits', 'View telemetry.recent_waits should exist');

-- =============================================================================
-- 2. FUNCTION EXISTENCE (19 tests)
-- =============================================================================

SELECT has_function('telemetry', '_pg_version', 'Function telemetry._pg_version should exist');
SELECT has_function('telemetry', '_get_config', 'Function telemetry._get_config should exist');
SELECT has_function('telemetry', '_has_pg_stat_statements', 'Function telemetry._has_pg_stat_statements should exist');
SELECT has_function('telemetry', '_pretty_bytes', 'Function telemetry._pretty_bytes should exist');
SELECT has_function('telemetry', 'snapshot', 'Function telemetry.snapshot should exist');
SELECT has_function('telemetry', 'sample', 'Function telemetry.sample should exist');
SELECT has_function('telemetry', 'track_table', 'Function telemetry.track_table should exist');
SELECT has_function('telemetry', 'untrack_table', 'Function telemetry.untrack_table should exist');
SELECT has_function('telemetry', 'list_tracked_tables', 'Function telemetry.list_tracked_tables should exist');
SELECT has_function('telemetry', 'compare', 'Function telemetry.compare should exist');
SELECT has_function('telemetry', 'table_compare', 'Function telemetry.table_compare should exist');
SELECT has_function('telemetry', 'wait_summary', 'Function telemetry.wait_summary should exist');
SELECT has_function('telemetry', 'statement_compare', 'Function telemetry.statement_compare should exist');
SELECT has_function('telemetry', 'activity_at', 'Function telemetry.activity_at should exist');
SELECT has_function('telemetry', 'anomaly_report', 'Function telemetry.anomaly_report should exist');
SELECT has_function('telemetry', 'summary_report', 'Function telemetry.summary_report should exist');
SELECT has_function('telemetry', 'get_mode', 'Function telemetry.get_mode should exist');
SELECT has_function('telemetry', 'set_mode', 'Function telemetry.set_mode should exist');
SELECT has_function('telemetry', 'cleanup', 'Function telemetry.cleanup should exist');

-- =============================================================================
-- 3. CORE FUNCTIONALITY (10 tests)
-- =============================================================================

-- Test snapshot() function works
SELECT lives_ok(
    $$SELECT telemetry.snapshot()$$,
    'snapshot() function should execute without error'
);

-- Verify snapshot was captured
SELECT ok(
    (SELECT count(*) FROM telemetry.snapshots) >= 1,
    'At least one snapshot should be captured'
);

-- Test sample() function works
SELECT lives_ok(
    $$SELECT telemetry.sample()$$,
    'sample() function should execute without error'
);

-- Verify sample was captured
SELECT ok(
    (SELECT count(*) FROM telemetry.samples) >= 1,
    'At least one sample should be captured'
);

-- Test wait_samples captured
SELECT ok(
    (SELECT count(*) FROM telemetry.wait_samples) >= 1,
    'Wait samples should be captured'
);

-- Test activity_samples captured
SELECT ok(
    (SELECT count(*) FROM telemetry.activity_samples) >= 0,
    'Activity samples table should be queryable (may be empty)'
);

-- Test version detection works
SELECT ok(
    telemetry._pg_version() >= 15,
    'PostgreSQL version should be 15 or higher'
);

-- Test pg_stat_statements detection
SELECT ok(
    telemetry._has_pg_stat_statements() IS NOT NULL,
    'pg_stat_statements detection should work'
);

-- Test pretty bytes formatting
SELECT is(
    telemetry._pretty_bytes(1024),
    '1.00 KB',
    'Pretty bytes should format correctly'
);

-- Test config retrieval
SELECT is(
    telemetry._get_config('mode', 'normal'),
    'normal',
    'Config retrieval should work with defaults'
);

-- =============================================================================
-- 4. TABLE TRACKING (5 tests)
-- =============================================================================

-- Create a test table
CREATE TABLE public.telemetry_test_table (
    id serial PRIMARY KEY,
    data text
);

-- Test track_table()
SELECT lives_ok(
    $$SELECT telemetry.track_table('telemetry_test_table')$$,
    'track_table() should work'
);

-- Verify table is tracked
SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.tracked_tables WHERE relname = 'telemetry_test_table'),
    'Table should be in tracked_tables'
);

-- Test list_tracked_tables()
SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.list_tracked_tables() WHERE relname = 'telemetry_test_table'),
    'list_tracked_tables() should show tracked table'
);

-- Test untrack_table()
SELECT lives_ok(
    $$SELECT telemetry.untrack_table('telemetry_test_table')$$,
    'untrack_table() should work'
);

-- Verify table is untracked
SELECT ok(
    NOT EXISTS (SELECT 1 FROM telemetry.tracked_tables WHERE relname = 'telemetry_test_table'),
    'Table should be removed from tracked_tables'
);

-- Cleanup test table
DROP TABLE public.telemetry_test_table;

-- =============================================================================
-- 5. ANALYSIS FUNCTIONS (8 tests)
-- =============================================================================

-- Capture a second snapshot and sample for time-based queries
SELECT pg_sleep(1);
SELECT telemetry.snapshot();
SELECT telemetry.sample();

-- Get time range for queries
DO $$
DECLARE
    v_start_time TIMESTAMPTZ;
    v_end_time TIMESTAMPTZ;
BEGIN
    SELECT min(captured_at) INTO v_start_time FROM telemetry.samples;
    SELECT max(captured_at) INTO v_end_time FROM telemetry.samples;

    -- Store for later tests
    CREATE TEMP TABLE test_times (start_time TIMESTAMPTZ, end_time TIMESTAMPTZ);
    INSERT INTO test_times VALUES (v_start_time, v_end_time);
END;
$$;

-- Test compare() function
SELECT lives_ok(
    $$SELECT * FROM telemetry.compare(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'compare() should execute without error'
);

-- Test wait_summary() function
SELECT lives_ok(
    $$SELECT * FROM telemetry.wait_summary(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'wait_summary() should execute without error'
);

-- Test activity_at() function
SELECT lives_ok(
    $$SELECT * FROM telemetry.activity_at(now())$$,
    'activity_at() should execute without error'
);

-- Test anomaly_report() function
SELECT lives_ok(
    $$SELECT * FROM telemetry.anomaly_report(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'anomaly_report() should execute without error'
);

-- Test summary_report() function
SELECT lives_ok(
    $$SELECT * FROM telemetry.summary_report(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'summary_report() should execute without error'
);

-- Test statement_compare() function
SELECT lives_ok(
    $$SELECT * FROM telemetry.statement_compare(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )$$,
    'statement_compare() should execute without error'
);

-- Test table_compare() (need a tracked table with activity)
CREATE TABLE public.telemetry_compare_test (id serial, data text);
SELECT telemetry.track_table('telemetry_compare_test');
SELECT telemetry.snapshot();
INSERT INTO public.telemetry_compare_test (data) VALUES ('test');
SELECT telemetry.snapshot();

SELECT lives_ok(
    $$SELECT * FROM telemetry.table_compare(
        'telemetry_compare_test',
        (SELECT start_time FROM test_times),
        now()
    )$$,
    'table_compare() should execute without error'
);

DROP TABLE public.telemetry_compare_test;

-- Test wait_summary returns data
SELECT ok(
    (SELECT count(*) FROM telemetry.wait_summary(
        (SELECT start_time FROM test_times),
        (SELECT end_time FROM test_times)
    )) > 0,
    'wait_summary() should return data'
);

-- =============================================================================
-- 6. CONFIGURATION FUNCTIONS (5 tests)
-- =============================================================================

-- Test get_mode()
SELECT lives_ok(
    $$SELECT * FROM telemetry.get_mode()$$,
    'get_mode() should execute without error'
);

-- Test default mode is normal
SELECT is(
    (SELECT mode FROM telemetry.get_mode()),
    'normal',
    'Default mode should be normal'
);

-- Test set_mode() to light
SELECT lives_ok(
    $$SELECT telemetry.set_mode('light')$$,
    'set_mode() should work'
);

-- Verify mode changed
SELECT is(
    (SELECT mode FROM telemetry.get_mode()),
    'light',
    'Mode should be changed to light'
);

-- Reset to normal
SELECT telemetry.set_mode('normal');

-- Test invalid mode throws error
SELECT throws_ok(
    $$SELECT telemetry.set_mode('invalid')$$,
    'Invalid mode: invalid. Must be normal, light, or emergency.',
    'set_mode() should reject invalid modes'
);

-- =============================================================================
-- 7. VIEWS FUNCTIONALITY (5 tests)
-- =============================================================================

-- Test deltas view
SELECT lives_ok(
    $$SELECT * FROM telemetry.deltas LIMIT 1$$,
    'deltas view should be queryable'
);

-- Test recent_waits view
SELECT lives_ok(
    $$SELECT * FROM telemetry.recent_waits LIMIT 1$$,
    'recent_waits view should be queryable'
);

-- Test recent_activity view
SELECT lives_ok(
    $$SELECT * FROM telemetry.recent_activity LIMIT 1$$,
    'recent_activity view should be queryable'
);

-- Test recent_locks view
SELECT lives_ok(
    $$SELECT * FROM telemetry.recent_locks LIMIT 1$$,
    'recent_locks view should be queryable'
);

-- Test recent_progress view
SELECT lives_ok(
    $$SELECT * FROM telemetry.recent_progress LIMIT 1$$,
    'recent_progress view should be queryable'
);

SELECT * FROM finish();
ROLLBACK;
