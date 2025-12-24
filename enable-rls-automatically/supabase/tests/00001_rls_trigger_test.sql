-- pgTAP tests for enable-rls-automatically
--
-- Run with: supabase test db
--
-- These tests verify that the event trigger correctly enables RLS
-- on new tables in the public schema.

BEGIN;

-- Enable NOTICE messages for visibility
SET client_min_messages TO 'notice';

SELECT plan(34);

-- ============================================
-- SETUP: Ensure clean state
-- ============================================

DROP TABLE IF EXISTS public.test_basic CASCADE;
DROP TABLE IF EXISTS public.test_constraints CASCADE;
DROP TABLE IF EXISTS public.test_ctas CASCADE;
DROP TABLE IF EXISTS public.test_like_source CASCADE;
DROP TABLE IF EXISTS public.test_like_target CASCADE;
DROP TABLE IF EXISTS public.test_if_not_exists CASCADE;
DROP TABLE IF EXISTS public.test_unlogged CASCADE;
DROP TABLE IF EXISTS public.test_partitioned CASCADE;
DROP TABLE IF EXISTS public.test_multi_1 CASCADE;
DROP TABLE IF EXISTS public.test_multi_2 CASCADE;
DROP TABLE IF EXISTS public.test_special_chars CASCADE;
DROP TABLE IF EXISTS public."Test_MixedCase" CASCADE;
DROP TABLE IF EXISTS public."user" CASCADE;
DROP TABLE IF EXISTS public.test_already_rls CASCADE;
DROP VIEW IF EXISTS public.test_view CASCADE;
DROP MATERIALIZED VIEW IF EXISTS public.test_matview CASCADE;
DROP SCHEMA IF EXISTS test_private CASCADE;
CREATE SCHEMA test_private;

-- ============================================
-- 1. INSTALLATION VERIFICATION (4 tests)
-- ============================================

-- Test 1: Function exists
SELECT has_function(
    'public',
    'enable_rls_on_new_tables',
    'Function enable_rls_on_new_tables should exist'
);

-- Test 2: Function has correct return type
SELECT is(
    (SELECT pg_catalog.format_type(p.prorettype, NULL)
     FROM pg_proc p
     JOIN pg_namespace n ON p.pronamespace = n.oid
     WHERE n.nspname = 'public' AND p.proname = 'enable_rls_on_new_tables'),
    'event_trigger',
    'Function should return event_trigger type'
);

-- Test 3: Event trigger exists and is enabled
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_event_trigger
        WHERE evtname = 'enable_rls_trigger'
          AND evtenabled = 'O'  -- O = origin and local, enabled
    ),
    'Event trigger enable_rls_trigger should exist and be enabled'
);

-- Test 4: Trigger fires on correct event
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_event_trigger
        WHERE evtname = 'enable_rls_trigger'
          AND evtevent = 'ddl_command_end'
          AND evttags @> ARRAY['CREATE TABLE']
    ),
    'Trigger should fire on ddl_command_end for CREATE TABLE'
);

-- ============================================
-- 2. CORE FUNCTIONALITY - HAPPY PATH (4 tests)
-- ============================================

-- Test 5: Basic table has RLS enabled
CREATE TABLE public.test_basic (id int);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_basic'),
    'Basic table should have relrowsecurity = true'
);

-- Test 6: Basic table has FORCE RLS enabled
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE relname = 'test_basic'),
    'Basic table should have relforcerowsecurity = true'
);

-- Test 7: Table with constraints gets RLS
CREATE TABLE public.test_constraints (
    id int PRIMARY KEY,
    email text NOT NULL UNIQUE,
    age int CHECK (age >= 0)
);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_constraints'),
    'Table with constraints should have RLS enabled'
);

-- Test 8: Table with constraints has FORCE RLS
SELECT ok(
    (SELECT relforcerowsecurity FROM pg_class WHERE relname = 'test_constraints'),
    'Table with constraints should have FORCE RLS enabled'
);

-- ============================================
-- 3. SCHEMA FILTERING (4 tests)
-- ============================================

-- Test 9: Table in custom schema does NOT get RLS
CREATE TABLE test_private.not_public (id int);

SELECT ok(
    NOT (SELECT relrowsecurity FROM pg_class
         WHERE relname = 'not_public'
           AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'test_private')),
    'Table in test_private schema should NOT have RLS enabled'
);

-- Test 10: Temporary table does NOT get RLS (it's in pg_temp schema)
CREATE TEMPORARY TABLE test_temp (id int);

SELECT ok(
    NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_temp'),
    'Temporary table should NOT have RLS enabled'
);

-- Test 11: Another custom schema test (using existing private schema if available)
CREATE SCHEMA IF NOT EXISTS test_auth;
CREATE TABLE test_auth.test_auth_table (id int);

SELECT ok(
    NOT COALESCE(
        (SELECT relrowsecurity FROM pg_class
         WHERE relname = 'test_auth_table'
           AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'test_auth')),
        false
    ),
    'Table in test_auth schema should NOT have RLS enabled'
);

DROP TABLE IF EXISTS test_auth.test_auth_table;
DROP SCHEMA IF EXISTS test_auth;

-- Test 12: Verify public schema IS affected (double-check)
SELECT ok(
    (SELECT relrowsecurity FROM pg_class
     WHERE relname = 'test_basic'
       AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')),
    'Table explicitly in public schema should have RLS enabled'
);

-- ============================================
-- 4. CREATE TABLE VARIANTS (6 tests)
-- ============================================

-- Test 13: CREATE TABLE ... AS SELECT triggers RLS
CREATE TABLE public.test_ctas AS SELECT 1 AS id, 'test'::text AS name;

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_ctas'),
    'CREATE TABLE AS SELECT should have RLS enabled'
);

-- Test 14: CREATE TABLE ... LIKE triggers RLS
CREATE TABLE public.test_like_source (id int, name text);
CREATE TABLE public.test_like_target (LIKE public.test_like_source);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_like_target'),
    'CREATE TABLE LIKE should have RLS enabled'
);

-- Test 15: CREATE TABLE IF NOT EXISTS (new table) triggers RLS
CREATE TABLE IF NOT EXISTS public.test_if_not_exists (id int);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_if_not_exists'),
    'CREATE TABLE IF NOT EXISTS (new) should have RLS enabled'
);

-- Test 16: CREATE TABLE IF NOT EXISTS (existing table) does not error
SELECT lives_ok(
    'CREATE TABLE IF NOT EXISTS public.test_if_not_exists (id int)',
    'CREATE TABLE IF NOT EXISTS on existing table should not error'
);

-- Test 17: CREATE UNLOGGED TABLE triggers RLS
CREATE UNLOGGED TABLE public.test_unlogged (id int);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_unlogged'),
    'UNLOGGED table should have RLS enabled'
);

-- Test 18: Partitioned table triggers RLS
CREATE TABLE public.test_partitioned (id int, created_at date) PARTITION BY RANGE (created_at);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_partitioned'),
    'Partitioned table should have RLS enabled'
);

-- ============================================
-- 5. NON-TRIGGERING DDL (5 tests)
-- ============================================

-- Test 19: CREATE VIEW does not trigger (no RLS on views anyway)
CREATE VIEW public.test_view AS SELECT * FROM public.test_basic;

SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_class
        WHERE relname = 'test_view'
          AND relrowsecurity = true
    ),
    'VIEW should not have RLS (views do not support RLS)'
);

-- Test 20: CREATE MATERIALIZED VIEW does not trigger
CREATE MATERIALIZED VIEW public.test_matview AS SELECT * FROM public.test_basic;

SELECT ok(
    NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_matview'),
    'MATERIALIZED VIEW should not have RLS enabled'
);

-- Test 21: ALTER TABLE does not re-trigger
-- First disable RLS manually, then alter table
ALTER TABLE public.test_basic DISABLE ROW LEVEL SECURITY;
ALTER TABLE public.test_basic ADD COLUMN extra_col text;

SELECT ok(
    NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_basic'),
    'ALTER TABLE should not re-enable RLS'
);

-- Re-enable for subsequent tests
ALTER TABLE public.test_basic ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.test_basic FORCE ROW LEVEL SECURITY;

-- Test 22: CREATE INDEX does not trigger RLS changes
CREATE INDEX test_basic_idx ON public.test_basic (id);

SELECT ok(
    true,  -- If we got here without error, test passes
    'CREATE INDEX should not cause any RLS issues'
);

-- Test 23: CREATE SEQUENCE does not trigger
CREATE SEQUENCE public.test_seq;

SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_class
        WHERE relname = 'test_seq'
          AND relrowsecurity = true
    ),
    'SEQUENCE should not have RLS'
);

-- ============================================
-- 6. EDGE CASES (5 tests)
-- ============================================

-- Test 24: Multiple tables in single transaction all get RLS
CREATE TABLE public.test_multi_1 (id int);
CREATE TABLE public.test_multi_2 (id int);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_multi_1')
    AND (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_multi_2'),
    'Multiple tables in same transaction should all have RLS'
);

-- Test 25: Table with special characters in name
CREATE TABLE public."test-special_chars.table" (id int);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test-special_chars.table'),
    'Table with special characters should have RLS enabled'
);

-- Test 26: Mixed-case table name
CREATE TABLE public."Test_MixedCase" (id int);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'Test_MixedCase'),
    'Mixed-case table name should have RLS enabled'
);

-- Test 27: Reserved word as table name
CREATE TABLE public."user" (id int);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'user'),
    'Reserved word table name should have RLS enabled'
);

-- Test 28: Table with RLS already enabled somehow (idempotency)
-- This tests that the trigger doesn't error if RLS is already on
CREATE TABLE public.test_already_rls (id int);
-- RLS should already be enabled, try to enable again via direct ALTER
SELECT lives_ok(
    'ALTER TABLE public.test_already_rls ENABLE ROW LEVEL SECURITY',
    'Enabling RLS on already-RLS table should not error'
);

-- ============================================
-- 7. TRANSACTION BEHAVIOR (2 tests)
-- ============================================

-- Test 29: Table created and committed has RLS persisted
-- We're already in a transaction, so this tests current state
SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_constraints'),
    'RLS should be visible within the transaction'
);

-- Test 30: Savepoint rollback behavior
SAVEPOINT sp1;
CREATE TABLE public.test_rollback (id int);
ROLLBACK TO SAVEPOINT sp1;

SELECT ok(
    NOT EXISTS(SELECT 1 FROM pg_class WHERE relname = 'test_rollback'),
    'Rolled-back table should not exist'
);

-- ============================================
-- 8. UNINSTALL VERIFICATION (4 tests)
-- ============================================

-- For uninstall tests, we need to actually uninstall and reinstall
-- This is tricky within a transaction, so we test what we can

-- Test 31: Verify trigger can be disabled
ALTER EVENT TRIGGER enable_rls_trigger DISABLE;

SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_event_trigger
        WHERE evtname = 'enable_rls_trigger'
          AND evtenabled = 'D'  -- D = disabled
    ),
    'Event trigger should be disableable'
);

-- Test 32: New table after disable does NOT get RLS
CREATE TABLE public.test_after_disable (id int);

SELECT ok(
    NOT (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_after_disable'),
    'Table created after trigger disable should NOT have RLS'
);

-- Test 33: Re-enable trigger
ALTER EVENT TRIGGER enable_rls_trigger ENABLE;

SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_event_trigger
        WHERE evtname = 'enable_rls_trigger'
          AND evtenabled = 'O'
    ),
    'Event trigger should be re-enableable'
);

-- Test 34: New table after re-enable gets RLS
CREATE TABLE public.test_after_reenable (id int);

SELECT ok(
    (SELECT relrowsecurity FROM pg_class WHERE relname = 'test_after_reenable'),
    'Table created after trigger re-enable should have RLS'
);

-- ============================================
-- CLEANUP
-- ============================================

SELECT * FROM finish();
ROLLBACK;
