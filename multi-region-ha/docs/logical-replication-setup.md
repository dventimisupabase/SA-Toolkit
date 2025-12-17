# Logical Replication Setup

This guide covers setting up PostgreSQL native logical replication between two Supabase projects.

## Overview

PostgreSQL logical replication uses a publish/subscribe model:
- **Publication**: Defined on the primary, specifies which tables to replicate
- **Subscription**: Defined on the standby, connects to the primary and receives changes

## Prerequisites

Before starting:
- [ ] Both Supabase projects accessible via direct connection (port 5432)
- [ ] `postgres` user credentials for both projects
- [ ] Schema deployed to both projects (migrations run on both)
- [ ] Tables have primary keys

## Step 1: Verify Connectivity

Test connections to both projects:

```bash
# Primary
psql "postgresql://postgres:${POSTGRES_PASSWORD}@db.${PRIMARY_REF}.supabase.co:5432/postgres" -c "SELECT 1"

# Standby
psql "postgresql://postgres:${POSTGRES_PASSWORD}@db.${STANDBY_REF}.supabase.co:5432/postgres" -c "SELECT 1"
```

## Step 2: Create Publication (Primary)

Connect to the **Primary** Supabase project and create the publication.

### Option A: All Tables (Simplest)

```sql
-- Replicate all tables in all schemas
CREATE PUBLICATION dr_publication FOR ALL TABLES;
```

### Option B: Specific Tables (Recommended)

```sql
-- Replicate specific tables
CREATE PUBLICATION dr_publication FOR TABLE
    public.users,
    public.orders,
    public.products,
    public.order_items,
    auth.users;  -- Include auth.users for user data continuity
```

### Option C: Schema-Based

```sql
-- Replicate all tables in specific schemas (PostgreSQL 15+)
CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;

-- Add specific tables from other schemas
ALTER PUBLICATION dr_publication ADD TABLE auth.users;
```

## Step 3: Create Replication Slot (Primary)

Still on the **Primary**, create a replication slot:

```sql
SELECT pg_create_logical_replication_slot('dr_slot', 'pgoutput');
```

Verify the slot:

```sql
SELECT slot_name, plugin, slot_type, active
FROM pg_replication_slots
WHERE slot_name = 'dr_slot';
```

## Step 4: Prepare Standby Schema

Ensure the **Standby** has identical schema:

```bash
# Export schema from primary
pg_dump --schema-only \
    "postgresql://postgres:${POSTGRES_PASSWORD}@db.${PRIMARY_REF}.supabase.co:5432/postgres" \
    > schema.sql

# Import to standby (if not using Supabase migrations)
psql "postgresql://postgres:${POSTGRES_PASSWORD}@db.${STANDBY_REF}.supabase.co:5432/postgres" \
    < schema.sql
```

**Note**: If using Supabase migrations, run the same migrations on both projects instead.

## Step 5: Create Subscription (Standby)

Connect to the **Standby** Supabase project and create the subscription:

```sql
CREATE SUBSCRIPTION dr_subscription
CONNECTION 'host=db.<PRIMARY_REF>.supabase.co port=5432 user=postgres password=<PASSWORD> dbname=postgres'
PUBLICATION dr_publication
WITH (
    copy_data = true,         -- Initial data sync
    create_slot = false,      -- We created slot manually
    slot_name = 'dr_slot',
    synchronous_commit = off  -- Async replication
);
```

**Important**: Replace `<PRIMARY_REF>` and `<PASSWORD>` with actual values.

## Step 6: Verify Replication

### On Primary

```sql
-- Check replication slot status
SELECT
    slot_name,
    active,
    restart_lsn,
    confirmed_flush_lsn
FROM pg_replication_slots
WHERE slot_name = 'dr_slot';

-- Check replication statistics
SELECT
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn,
    pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
```

### On Standby

```sql
-- Check subscription status
SELECT
    subname,
    subenabled,
    subconninfo
FROM pg_subscription
WHERE subname = 'dr_subscription';

-- Check subscription statistics
SELECT
    subname,
    received_lsn,
    latest_end_lsn,
    last_msg_send_time,
    last_msg_receipt_time
FROM pg_stat_subscription
WHERE subname = 'dr_subscription';
```

## Step 7: Test Replication

### On Primary

```sql
-- Create a test record
INSERT INTO public.users (email, name)
VALUES ('test@example.com', 'Test User');
```

### On Standby

```sql
-- Verify the record appears (may take a few seconds)
SELECT * FROM public.users WHERE email = 'test@example.com';
```

## Adding Tables to Publication

When you add new tables to the primary:

### On Primary

```sql
ALTER PUBLICATION dr_publication ADD TABLE public.new_table;
```

### On Standby

```sql
-- Refresh subscription to pick up new table
ALTER SUBSCRIPTION dr_subscription REFRESH PUBLICATION;
```

## Monitoring Replication Lag

Create a monitoring query (run on Primary):

```sql
SELECT
    slot_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS replication_lag,
    active
FROM pg_replication_slots
WHERE slot_name = 'dr_slot';
```

### Alerting Thresholds

| Lag | Status | Action |
|-----|--------|--------|
| < 1 MB | Healthy | None |
| 1-10 MB | Warning | Monitor |
| 10-100 MB | Critical | Investigate |
| > 100 MB | Emergency | May need to recreate subscription |

## Handling Schema Changes (DDL)

**Important**: Logical replication does NOT replicate DDL. Schema changes must be applied to both projects.

### Safe DDL Workflow

1. Apply DDL to **Standby** first (additive changes)
2. Apply DDL to **Primary**
3. Update publication if needed

### Example: Adding a Column

```sql
-- 1. On Standby
ALTER TABLE public.users ADD COLUMN phone TEXT;

-- 2. On Primary
ALTER TABLE public.users ADD COLUMN phone TEXT;
```

### Example: Adding a Table

```sql
-- 1. On Standby
CREATE TABLE public.new_table (...);

-- 2. On Primary
CREATE TABLE public.new_table (...);
ALTER PUBLICATION dr_publication ADD TABLE public.new_table;

-- 3. On Standby
ALTER SUBSCRIPTION dr_subscription REFRESH PUBLICATION;
```

## Pausing and Resuming Replication

### Pause (on Standby)

```sql
ALTER SUBSCRIPTION dr_subscription DISABLE;
```

### Resume (on Standby)

```sql
ALTER SUBSCRIPTION dr_subscription ENABLE;
```

## Troubleshooting

### Subscription Not Active

```sql
-- On Standby: Check for errors
SELECT * FROM pg_stat_subscription_stats WHERE subname = 'dr_subscription';

-- Check PostgreSQL logs in Supabase dashboard
```

### Replication Slot Growing

If the slot is accumulating WAL (standby not consuming):

```sql
-- On Primary: Check slot size
SELECT
    slot_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS slot_size
FROM pg_replication_slots;
```

Causes:
- Standby subscription disabled
- Network issues
- Standby overloaded

### Initial Sync Stuck

If `copy_data = true` sync is taking too long:

```sql
-- On Standby: Check sync status
SELECT * FROM pg_subscription_rel WHERE srsubstate != 'r';
-- States: i=init, d=data copy, f=finished table copy, s=sync, r=ready
```

## Cleanup (If Needed)

### Remove Subscription (Standby)

```sql
DROP SUBSCRIPTION dr_subscription;
```

### Remove Publication (Primary)

```sql
DROP PUBLICATION dr_publication;
SELECT pg_drop_replication_slot('dr_slot');
```

## Related Scripts

- [setup_publication.sql](../scripts/replication/setup_publication.sql)
- [setup_subscription.sql](../scripts/replication/setup_subscription.sql)
- [verify_replication.sql](../scripts/replication/verify_replication.sql)

## Next Steps

- [Supabase Schema Replication](supabase-schema-replication.md) - Handling auth, storage, realtime
- [Sequence Synchronization](sequence-synchronization.md) - Preparing for failover
