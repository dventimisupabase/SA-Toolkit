# Migration Guide for Existing Projects

This guide walks through adding multi-region HA to an existing Supabase project with minimal disruption.

## Overview

The good news: **this solution layers onto existing projects with minimal changes to the primary**. The primary database requires only two SQL statements. No downtime, no schema changes, no application code changes on the database side.

The main work involves:
1. Setting up new infrastructure (standby project, PgBouncer)
2. Waiting for initial data sync
3. Updating application connection strings

## Impact Summary

| Component                | Change Required          | Downtime              |
|--------------------------|--------------------------|-----------------------|
| Primary Database         | 2 SQL statements         | None                  |
| Primary Application Code | None                     | None                  |
| Standby Database         | New Supabase project     | N/A                   |
| PgBouncer                | New Fly.io deployment    | N/A                   |
| Application Config       | Connection string update | Brief (during deploy) |

## Prerequisites

Before starting:

- [ ] Existing Supabase project (Pro plan or higher for direct connections)
- [ ] Fly.io account with CLI installed
- [ ] Access to application deployment pipeline
- [ ] Maintenance window identified for connection string cutover

## Phase 1: Preparation (No User Impact)

### Step 1.1: Assess Your Database

Check database size to estimate initial sync time:

```sql
-- On primary: Get database size
SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;

-- Get table sizes
SELECT
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS size
FROM pg_tables
WHERE schemaname IN ('public', 'auth', 'storage')
ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
LIMIT 20;
```

| Database Size | Expected Initial Sync |
|---------------|-----------------------|
| < 1 GB        | 5-15 minutes          |
| 1-10 GB       | 15-60 minutes         |
| 10-50 GB      | 1-4 hours             |
| 50-200 GB     | 4-12 hours            |
| 200 GB - 1 TB | 12-48 hours           |
| > 1 TB        | Multiple days         |

### Step 1.2: Verify Table Requirements

Logical replication requires primary keys:

```sql
-- Find tables without primary keys
SELECT
    schemaname,
    tablename
FROM pg_tables t
WHERE schemaname IN ('public', 'auth', 'storage')
AND NOT EXISTS (
    SELECT 1 FROM pg_constraint c
    WHERE c.conrelid = (schemaname || '.' || tablename)::regclass
    AND c.contype = 'p'
);
```

If any tables lack primary keys, add them before proceeding:

```sql
-- Example: Add primary key to table
ALTER TABLE public.some_table ADD PRIMARY KEY (id);
```

### Step 1.3: Create Standby Supabase Project

1. Go to [Supabase Dashboard](https://supabase.com/dashboard)
2. Create new project in a **different region** than primary
3. Note the project reference and database password
4. **Important**: Use the same database password as primary for simplicity

### Step 1.4: Sync Schema to Standby

The standby must have identical schema before replication starts.

**Option A: Using Supabase Migrations (Recommended)**

If you use Supabase migrations:

```bash
# Link to standby project
supabase link --project-ref <STANDBY_REF>

# Push migrations
supabase db push
```

**Option B: Manual Schema Export**

```bash
# Export schema from primary (no data)
pg_dump \
    "postgresql://postgres:${PASSWORD}@db.${PRIMARY_REF}.supabase.co:5432/postgres" \
    --schema-only \
    --no-owner \
    --no-privileges \
    -n public \
    > schema.sql

# Import to standby
psql "postgresql://postgres:${PASSWORD}@db.${STANDBY_REF}.supabase.co:5432/postgres" < schema.sql
```

**Note**: Auth and storage schemas are already present in new Supabase projects.

## Phase 2: Setup Replication (No User Impact)

### Step 2.1: Create Publication on Primary

Connect to your **primary** Supabase database:

```sql
-- Create publication for public schema tables
CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;

-- Add auth tables (user data, not sessions)
ALTER PUBLICATION dr_publication ADD TABLE auth.users;
ALTER PUBLICATION dr_publication ADD TABLE auth.identities;

-- Verify publication
SELECT * FROM pg_publication_tables WHERE pubname = 'dr_publication';
```

### Step 2.2: Create Replication Slot on Primary

```sql
-- Create slot (starts retaining WAL from this point)
SELECT pg_create_logical_replication_slot('dr_slot', 'pgoutput');

-- Verify slot
SELECT slot_name, plugin, slot_type FROM pg_replication_slots;
```

**⚠️ Important**: From this point, WAL is retained. If the standby doesn't connect soon, disk usage will grow. Monitor with:

```sql
SELECT
    slot_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
FROM pg_replication_slots;
```

### Step 2.3: Create Subscription on Standby

Connect to your **standby** Supabase database:

```sql
CREATE SUBSCRIPTION dr_subscription
CONNECTION 'host=db.<PRIMARY_REF>.supabase.co port=5432 user=postgres password=<PASSWORD> dbname=postgres'
PUBLICATION dr_publication
WITH (
    copy_data = true,
    create_slot = false,
    slot_name = 'dr_slot'
);
```

### Step 2.4: Monitor Initial Sync

The initial sync begins immediately. Monitor progress:

```sql
-- On standby: Check sync status
SELECT
    srrelid::regclass AS table_name,
    CASE srsubstate
        WHEN 'i' THEN 'initializing'
        WHEN 'd' THEN 'copying data'
        WHEN 'f' THEN 'finished copy'
        WHEN 's' THEN 'syncing'
        WHEN 'r' THEN 'ready'
    END AS status
FROM pg_subscription_rel
WHERE srsubid = (SELECT oid FROM pg_subscription WHERE subname = 'dr_subscription')
ORDER BY srrelid::regclass::text;
```

**Wait until all tables show 'ready' before proceeding.**

For large tables, you can estimate progress:

```sql
-- Compare row counts between primary and standby
-- Run on both and compare
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY relname;
```

## Phase 3: Deploy PgBouncer (No User Impact)

While initial sync is running, deploy PgBouncer.

### Step 3.1: Deploy to Fly.io

```bash
cd multi-region-ha/flyio/

# Create app
fly launch --name my-supabase-pgbouncer --region iad --no-deploy

# Create volume
fly volumes create pgbouncer_data --region iad --size 1

# Set secrets (point to PRIMARY initially)
fly secrets set \
    DATABASE_HOST=db.<PRIMARY_REF>.supabase.co \
    DATABASE_NAME=postgres \
    DATABASE_USER=postgres \
    DATABASE_PASSWORD=<PASSWORD> \
    PGBOUNCER_ADMIN_PASSWORD=<CHOOSE_ADMIN_PASSWORD>

# Deploy
fly deploy
```

### Step 3.2: Verify PgBouncer

```bash
# Test connection through PgBouncer
psql "postgresql://postgres:<PASSWORD>@my-supabase-pgbouncer.fly.dev:5432/postgres" \
    -c "SELECT current_database(), inet_server_addr();"
```

### Step 3.3: Test Application Compatibility

Before cutover, test your application with PgBouncer:

1. Deploy a staging/test instance pointing to PgBouncer
2. Run your test suite
3. Verify all queries work (especially if using session-level features)

**Common issues:**
- Prepared statements: May need `pool_mode = session`
- Advisory locks: Require `pool_mode = session`
- Temp tables: Work with `pool_mode = transaction` but cleared per transaction

## Phase 4: Application Cutover

### Step 4.1: Verify Replication is Caught Up

Before cutover, ensure standby is fully synced:

```sql
-- On primary: Check replication lag
SELECT
    slot_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag
FROM pg_replication_slots
WHERE slot_name = 'dr_slot';
```

Lag should be minimal (< 1 MB for quiet databases).

### Step 4.2: Update Application Connection String

Change your application's database connection from:

```
postgresql://postgres:<PASSWORD>@db.<PRIMARY_REF>.supabase.co:5432/postgres
```

To:

```
postgresql://postgres:<PASSWORD>@my-supabase-pgbouncer.fly.dev:5432/postgres
```

**Deployment options:**

**Option A: Environment Variable Update**
```bash
# Update environment variable and redeploy
DATABASE_URL=postgresql://postgres:xxx@my-supabase-pgbouncer.fly.dev:5432/postgres
```

**Option B: Gradual Rollout**
1. Deploy new version to canary instances
2. Monitor for errors
3. Roll out to remaining instances

**Option C: DNS-Based (Zero-Downtime)**
If you control a DNS name for your database:
1. Point `db.myapp.com` to Supabase initially
2. Update DNS to point to PgBouncer
3. Wait for TTL to expire
4. No application deployment needed

### Step 4.3: Verify Traffic Flow

After cutover:

```bash
# Check PgBouncer is receiving connections
fly ssh console -a my-supabase-pgbouncer -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"
```

You should see active client and server connections.

## Phase 5: Operational Setup

### Step 5.1: Configure Monitoring

Set up alerts for:

```bash
# Add to cron or monitoring system
# Alert if replication lag > 100 MB
./scripts/health/check_replication_lag.sh --alert-threshold-mb 100
```

### Step 5.2: Test Failover (Recommended)

Schedule a maintenance window to test the failover procedure:

1. Follow [Testing Runbook](../runbooks/testing-runbook.md)
2. Execute failover to standby
3. Verify application works
4. Execute failback
5. Document results

### Step 5.3: Document Your Configuration

Update your team's runbooks with:

- Primary project reference
- Standby project reference
- PgBouncer Fly.io app name
- Failover procedure location
- On-call contacts

## Rollback Plan

If issues arise during cutover:

### Immediate Rollback (During Cutover)

Simply revert the connection string change:

```bash
# Point back to Supabase directly
DATABASE_URL=postgresql://postgres:xxx@db.<PRIMARY_REF>.supabase.co:5432/postgres
```

### Rollback After Extended PgBouncer Usage

If PgBouncer has been in use but you need to remove it:

1. Update connection strings to point directly to Supabase
2. Deploy application changes
3. (Optional) Keep PgBouncer running until all old connections drain
4. Shut down PgBouncer

**Replication can remain active** even if you roll back PgBouncer. You can re-introduce PgBouncer later.

## Cleanup (If Abandoning HA Setup)

If you decide not to proceed with HA:

```sql
-- On standby: Remove subscription
DROP SUBSCRIPTION dr_subscription;

-- On primary: Remove publication and slot
DROP PUBLICATION dr_publication;
SELECT pg_drop_replication_slot('dr_slot');
```

Then delete the standby Supabase project and Fly.io app.

## Troubleshooting

### Initial Sync Taking Too Long

For very large databases (> 500 GB):

1. Consider syncing during off-peak hours
2. Monitor WAL retention on primary
3. If WAL grows too large, you may need to:
   - Drop subscription
   - Drop and recreate slot
   - Use `pg_dump`/`pg_restore` instead
   - Create subscription with `copy_data = false`

### Replication Slot Growing

If standby disconnects, WAL accumulates:

```sql
-- Check slot size
SELECT slot_name, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
FROM pg_replication_slots;
```

If too large:
1. Fix standby connection
2. Or drop and recreate slot (requires re-sync)

### Application Errors After PgBouncer

Common issues:

| Error                        | Cause            | Solution                                                 |
|------------------------------|------------------|----------------------------------------------------------|
| Prepared statement not found | Transaction mode | Use `pool_mode = session` or disable prepared statements |
| Temp table doesn't exist     | Transaction mode | Expected behavior; redesign if needed                    |
| Advisory lock released       | Transaction mode | Use `pool_mode = session`                                |

## Timeline Example

| Day | Activity                               | Duration      |
|-----|----------------------------------------|---------------|
| 1   | Create standby project, sync schema    | 1-2 hours     |
| 1   | Create publication, slot, subscription | 30 minutes    |
| 1-3 | Initial data sync (depends on size)    | Hours to days |
| 3   | Deploy PgBouncer, test                 | 2-3 hours     |
| 4   | Application cutover (staging)          | 1 hour        |
| 5   | Application cutover (production)       | 1 hour        |
| 5+  | Monitor, test failover                 | Ongoing       |

## Checklist

### Pre-Migration
- [ ] Database size assessed
- [ ] All tables have primary keys
- [ ] Standby project created
- [ ] Schema synced to standby

### Replication Setup
- [ ] Publication created on primary
- [ ] Replication slot created on primary
- [ ] Subscription created on standby
- [ ] Initial sync completed (all tables 'ready')

### PgBouncer
- [ ] Fly.io app deployed
- [ ] Connection tested
- [ ] Application compatibility verified

### Cutover
- [ ] Replication lag minimal
- [ ] Connection string updated
- [ ] Traffic flowing through PgBouncer
- [ ] Application health verified

### Post-Migration
- [ ] Monitoring configured
- [ ] Failover tested
- [ ] Runbooks documented
- [ ] Team trained

## Related Documents

- [Architecture Overview](architecture-overview.md)
- [Logical Replication Setup](logical-replication-setup.md)
- [PgBouncer on Fly.io Setup](pgbouncer-flyio-setup.md)
- [Failover Runbook](../runbooks/failover-runbook.md)
- [Testing Runbook](../runbooks/testing-runbook.md)
