-- =============================================================================
-- pg-telemetry pgTAP Tests
-- =============================================================================
-- Comprehensive test suite for pg-telemetry functionality
-- Run with: supabase test db
-- =============================================================================

BEGIN;
SELECT plan(127);  -- Total number of tests (73 + 15 P0 + 8 P1 + 12 P2 + 9 P3 + 10 P4 = 127)

-- =============================================================================
-- 1. INSTALLATION VERIFICATION (16 tests)
-- =============================================================================

-- Test schema exists
SELECT has_schema('telemetry', 'Schema telemetry should exist');

-- Test all 12 tables exist (11 original + 1 collection_stats)
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
SELECT has_table('telemetry', 'collection_stats', 'P0 Safety: Table telemetry.collection_stats should exist');

-- Test all 7 views exist
SELECT has_view('telemetry', 'deltas', 'View telemetry.deltas should exist');
SELECT has_view('telemetry', 'table_deltas', 'View telemetry.table_deltas should exist');
SELECT has_view('telemetry', 'recent_waits', 'View telemetry.recent_waits should exist');

-- =============================================================================
-- 2. FUNCTION EXISTENCE (24 tests)
-- =============================================================================

SELECT has_function('telemetry', '_pg_version', 'Function telemetry._pg_version should exist');
SELECT has_function('telemetry', '_get_config', 'Function telemetry._get_config should exist');
SELECT has_function('telemetry', '_has_pg_stat_statements', 'Function telemetry._has_pg_stat_statements should exist');
SELECT has_function('telemetry', '_pretty_bytes', 'Function telemetry._pretty_bytes should exist');
SELECT has_function('telemetry', '_check_circuit_breaker', 'P0 Safety: Function telemetry._check_circuit_breaker should exist');
SELECT has_function('telemetry', '_record_collection_start', 'P0 Safety: Function telemetry._record_collection_start should exist');
SELECT has_function('telemetry', '_record_collection_end', 'P0 Safety: Function telemetry._record_collection_end should exist');
SELECT has_function('telemetry', '_record_collection_skip', 'P0 Safety: Function telemetry._record_collection_skip should exist');
SELECT has_function('telemetry', '_check_schema_size', 'P1 Safety: Function telemetry._check_schema_size should exist');
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

-- =============================================================================
-- 8. KILL SWITCH (6 tests)
-- =============================================================================

-- Test disable() function exists
SELECT has_function('telemetry', 'disable', 'Function telemetry.disable should exist');

-- Test enable() function exists
SELECT has_function('telemetry', 'enable', 'Function telemetry.enable should exist');

-- Test disable() stops collection
SELECT lives_ok(
    $$SELECT telemetry.disable()$$,
    'disable() should execute without error'
);

-- Verify jobs are unscheduled
SELECT ok(
    NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname LIKE 'telemetry%'),
    'All telemetry cron jobs should be unscheduled after disable()'
);

-- Test enable() restarts collection
SELECT lives_ok(
    $$SELECT telemetry.enable()$$,
    'enable() should execute without error'
);

-- Verify jobs are rescheduled
SELECT ok(
    (SELECT count(*) FROM cron.job WHERE jobname LIKE 'telemetry%') = 3,
    'All 3 telemetry cron jobs should be rescheduled after enable()'
);

-- =============================================================================
-- 9. P0 SAFETY FEATURES (10 tests)
-- =============================================================================

-- Test circuit breaker configuration exists
SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'circuit_breaker_enabled'),
    'P0 Safety: Circuit breaker config should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'circuit_breaker_threshold_ms'),
    'P0 Safety: Circuit breaker threshold config should exist'
);

-- Test collection stats are recorded for sample()
SELECT lives_ok(
    $$SELECT telemetry.sample()$$,
    'P0 Safety: sample() with stats tracking should execute without error'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.collection_stats WHERE collection_type = 'sample'),
    'P0 Safety: Collection stats should be recorded for sample()'
);

SELECT ok(
    (SELECT success FROM telemetry.collection_stats WHERE collection_type = 'sample' ORDER BY started_at DESC LIMIT 1) = true,
    'P0 Safety: Last sample collection should be marked as successful'
);

-- Test collection stats are recorded for snapshot()
SELECT lives_ok(
    $$SELECT telemetry.snapshot()$$,
    'P0 Safety: snapshot() with stats tracking should execute without error'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.collection_stats WHERE collection_type = 'snapshot'),
    'P0 Safety: Collection stats should be recorded for snapshot()'
);

SELECT ok(
    (SELECT success FROM telemetry.collection_stats WHERE collection_type = 'snapshot' ORDER BY started_at DESC LIMIT 1) = true,
    'P0 Safety: Last snapshot collection should be marked as successful'
);

-- Test circuit breaker can be triggered
UPDATE telemetry.config SET value = '100' WHERE key = 'circuit_breaker_threshold_ms';

-- Clear existing sample collections to ensure our fake one is the most recent
DELETE FROM telemetry.collection_stats WHERE collection_type = 'sample';

-- Insert a fake long-running collection (most recent)
INSERT INTO telemetry.collection_stats (collection_type, started_at, completed_at, duration_ms, success)
VALUES ('sample', now(), now(), 10000, true);

-- Circuit breaker should now skip
SELECT ok(
    telemetry._check_circuit_breaker('sample') = true,
    'P0 Safety: Circuit breaker should trip after threshold exceeded'
);

-- Reset threshold
UPDATE telemetry.config SET value = '5000' WHERE key = 'circuit_breaker_threshold_ms';

-- Test circuit breaker can be disabled
UPDATE telemetry.config SET value = 'false' WHERE key = 'circuit_breaker_enabled';

SELECT ok(
    telemetry._check_circuit_breaker('sample') = false,
    'P0 Safety: Circuit breaker should not trip when disabled'
);

-- Re-enable
UPDATE telemetry.config SET value = 'true' WHERE key = 'circuit_breaker_enabled';

-- =============================================================================
-- 10. P1 SAFETY FEATURES (7 tests)
-- =============================================================================

-- Test schema size monitoring function exists
SELECT has_function('telemetry', '_check_schema_size', 'P1 Safety: Function telemetry._check_schema_size should exist');

-- Test schema size monitoring config exists
SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'schema_size_warning_mb'),
    'P1 Safety: Schema size warning config should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'schema_size_critical_mb'),
    'P1 Safety: Schema size critical config should exist'
);

-- Test schema size monitoring returns results
SELECT ok(
    (SELECT count(*) FROM telemetry._check_schema_size()) = 1,
    'P1 Safety: Schema size check should return results'
);

-- Test schema size is below warning threshold (should be for fresh install)
SELECT ok(
    (SELECT status FROM telemetry._check_schema_size()) = 'OK',
    'P1 Safety: Fresh install should have OK schema size status'
);

-- Test cleanup() function now returns 3 columns including vacuumed_tables
SELECT lives_ok(
    $$SELECT * FROM telemetry.cleanup('1 day')$$,
    'P1 Safety: cleanup() with VACUUM should execute without error'
);

-- Verify cleanup returns vacuumed_tables column
SELECT ok(
    (SELECT vacuumed_tables FROM telemetry.cleanup('1 day')) >= 0,
    'P1 Safety: cleanup() should return vacuum count'
);

-- =============================================================================
-- 10. P2 SAFETY FEATURES (12 tests)
-- =============================================================================

-- Test P2: Automatic mode switching function exists
SELECT has_function(
    'telemetry', '_check_and_adjust_mode',
    'P2: Function telemetry._check_and_adjust_mode should exist'
);

-- Test P2: Auto mode config entries exist
SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'auto_mode_enabled'),
    'P2: Auto mode enabled config should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'auto_mode_connections_threshold'),
    'P2: Auto mode connections threshold config should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'auto_mode_trips_threshold'),
    'P2: Auto mode trips threshold config should exist'
);

-- Test P2: Auto mode defaults to disabled
SELECT ok(
    (SELECT value FROM telemetry.config WHERE key = 'auto_mode_enabled') = 'false',
    'P2: Auto mode should be disabled by default'
);

-- Test P2: Configurable retention config entries exist
SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'retention_samples_days'),
    'P2: Samples retention config should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'retention_snapshots_days'),
    'P2: Snapshots retention config should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'retention_statements_days'),
    'P2: Statements retention config should exist'
);

-- Test P2: cleanup() now returns 4 columns (added deleted_statements)
SELECT lives_ok(
    $$SELECT deleted_snapshots, deleted_samples, deleted_statements, vacuumed_tables FROM telemetry.cleanup()$$,
    'P2: cleanup() should return 4 columns with configurable retention'
);

-- Test P2: Partition management functions exist
SELECT has_function(
    'telemetry', 'create_next_partition',
    'P2: Function telemetry.create_next_partition should exist'
);

SELECT has_function(
    'telemetry', 'drop_old_partitions',
    'P2: Function telemetry.drop_old_partitions should exist'
);

SELECT has_function(
    'telemetry', 'partition_status',
    'P2: Function telemetry.partition_status should exist'
);

-- =============================================================================
-- 11. P3 FEATURES - Self-Monitoring and Health Checks (9 tests)
-- =============================================================================

-- Test P3: Config entries exist
SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'self_monitoring_enabled'),
    'P3: Self-monitoring enabled config should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'health_check_enabled'),
    'P3: Health check enabled config should exist'
);

-- Test P3: Health check function exists
SELECT has_function(
    'telemetry', 'health_check',
    'P3: Function telemetry.health_check should exist'
);

-- Test P3: Health check returns results
SELECT ok(
    (SELECT count(*) FROM telemetry.health_check()) >= 5,
    'P3: health_check() should return at least 5 components'
);

-- Test P3: Health check shows enabled status
SELECT ok(
    EXISTS (
        SELECT 1 FROM telemetry.health_check()
        WHERE component = 'Telemetry System'
          AND status = 'ENABLED'
    ),
    'P3: health_check() should show system as enabled'
);

-- Test P3: Performance report function exists
SELECT has_function(
    'telemetry', 'performance_report',
    'P3: Function telemetry.performance_report should exist'
);

-- Test P3: Performance report returns results
SELECT ok(
    (SELECT count(*) FROM telemetry.performance_report('24 hours')) >= 5,
    'P3: performance_report() should return at least 5 metrics'
);

-- Test P3: Performance report includes key metrics
SELECT ok(
    EXISTS (
        SELECT 1 FROM telemetry.performance_report('24 hours')
        WHERE metric = 'Schema Size'
    ),
    'P3: performance_report() should include schema size metric'
);

-- Test P3: Performance report includes assessment
SELECT ok(
    (
        SELECT count(*) FROM telemetry.performance_report('24 hours')
        WHERE assessment IS NOT NULL
    ) >= 5,
    'P3: performance_report() should include assessments for all metrics'
);

-- =============================================================================
-- 12. P4 FEATURES - Advanced Features (10 tests)
-- =============================================================================

-- Test P4: Alert config entries exist
SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'alert_enabled'),
    'P4: Alert enabled config should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'alert_circuit_breaker_count'),
    'P4: Alert circuit breaker count config should exist'
);

SELECT ok(
    EXISTS (SELECT 1 FROM telemetry.config WHERE key = 'alert_schema_size_mb'),
    'P4: Alert schema size config should exist'
);

-- Test P4: Alert function exists
SELECT has_function(
    'telemetry', 'check_alerts',
    'P4: Function telemetry.check_alerts should exist'
);

-- Test P4: Alerts disabled by default
SELECT ok(
    (SELECT value FROM telemetry.config WHERE key = 'alert_enabled') = 'false',
    'P4: Alerts should be disabled by default'
);

-- Test P4: Export function exists
SELECT has_function(
    'telemetry', 'export_json',
    'P4: Function telemetry.export_json should exist'
);

-- Test P4: Export returns valid JSON
SELECT lives_ok(
    $$SELECT telemetry.export_json(now() - interval '1 hour', now())$$,
    'P4: export_json() should execute without error'
);

-- Test P4: Export includes metadata
SELECT ok(
    (SELECT telemetry.export_json(now() - interval '1 hour', now()) ? 'export_time'),
    'P4: export_json() should include export_time in result'
);

-- Test P4: Config recommendations function exists
SELECT has_function(
    'telemetry', 'config_recommendations',
    'P4: Function telemetry.config_recommendations should exist'
);

-- Test P4: Config recommendations returns results
SELECT ok(
    (SELECT count(*) FROM telemetry.config_recommendations()) >= 1,
    'P4: config_recommendations() should return at least one row'
);

SELECT * FROM finish();
ROLLBACK;
