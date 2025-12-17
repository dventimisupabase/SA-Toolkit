# Failback Runbook

This runbook provides instructions for failing back to the original primary after a failover event.

## Overview

Failback is the process of returning operations to the original primary (Region A) after it has been recovered. This involves:

1. Rebuilding replication from new primary (Region B) to old primary (Region A)
2. Executing a controlled failover back to Region A

## When to Use This Runbook

- Original primary has been recovered and is stable
- You want to return to the original primary/standby configuration
- Scheduled maintenance window for failback

## Prerequisites

- [ ] Original primary (Region A) is accessible and healthy
- [ ] Current primary (Region B) is stable
- [ ] Maintenance window scheduled
- [ ] Stakeholders notified

## Decision: Rebuild vs. Resync

### Option A: Full Rebuild (Recommended)

Best when:
- Significant time has passed since failover
- Old primary had data corruption
- Schema changes occurred during outage

### Option B: Reverse Replication

Best when:
- Quick failback needed
- Minimal changes since failover
- Old primary data is intact

## Option A: Full Rebuild Failback

### Step 1: Prepare Old Primary

Clear the old primary to receive fresh data.

**WARNING: This deletes all data on the old primary.**

```sql
-- On old primary (Region A)
-- Drop old replication artifacts if they exist
DROP PUBLICATION IF EXISTS dr_publication CASCADE;
SELECT pg_drop_replication_slot('dr_slot') WHERE EXISTS (
    SELECT 1 FROM pg_replication_slots WHERE slot_name = 'dr_slot'
);
```

### Step 2: Schema Sync

Ensure schema matches on both sides:

```bash
# Export schema from current primary (Region B)
pg_dump --schema-only \
    "postgresql://postgres:$POSTGRES_PASSWORD@$CURRENT_PRIMARY_HOST:5432/postgres" \
    > schema.sql

# Review and apply to old primary if needed
psql "postgresql://postgres:$POSTGRES_PASSWORD@$OLD_PRIMARY_HOST:5432/postgres" < schema.sql
```

### Step 3: Set Up Reverse Replication

Create publication on current primary (Region B):

```sql
-- On current primary (Region B)
CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;
ALTER PUBLICATION dr_publication ADD TABLE auth.users, auth.identities;
SELECT pg_create_logical_replication_slot('dr_slot', 'pgoutput');
```

Create subscription on old primary (Region A):

```sql
-- On old primary (Region A)
CREATE SUBSCRIPTION dr_subscription
CONNECTION 'host=<CURRENT_PRIMARY_HOST> port=5432 user=postgres password=<PASSWORD> dbname=postgres'
PUBLICATION dr_publication
WITH (
    copy_data = true,
    create_slot = false,
    slot_name = 'dr_slot'
);
```

### Step 4: Wait for Sync

Monitor until old primary catches up:

```sql
-- On old primary (Region A)
SELECT
    srrelid::regclass AS table_name,
    srsubstate AS state
FROM pg_subscription_rel
WHERE srsubid = (SELECT oid FROM pg_subscription WHERE subname = 'dr_subscription');

-- All should show 'r' (ready)
```

### Step 5: Verify Data Consistency

Compare row counts:

```sql
-- Run on both and compare
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname IN ('public', 'auth')
ORDER BY schemaname, relname;
```

### Step 6: Execute Failover

Follow the [Failover Runbook](failover-runbook.md) with:
- PRIMARY_HOST = current primary (Region B)
- STANDBY_HOST = old primary (Region A)

```bash
# Update config
export PRIMARY_HOST=$CURRENT_PRIMARY_HOST  # Region B
export STANDBY_HOST=$OLD_PRIMARY_HOST       # Region A

# Execute failover
./scripts/failover/failover.sh
```

### Step 7: Post-Failback

After successful failback:

1. Original primary (Region A) is now the active primary
2. Region B becomes the new standby
3. Set up replication from A → B (reverse of current setup)

## Option B: Reverse Replication Failback

For quick failback when old primary data is mostly intact.

### Step 1: Assess Data Gap

Check what's different between regions:

```sql
-- Compare recent data on both
SELECT max(created_at) FROM public.orders;  -- Run on both
```

### Step 2: Disable Old Publication

On old primary (Region A):

```sql
-- Clean up old replication setup
DROP PUBLICATION IF EXISTS dr_publication;
SELECT pg_drop_replication_slot('dr_slot') WHERE EXISTS (
    SELECT 1 FROM pg_replication_slots WHERE slot_name = 'dr_slot'
);
```

### Step 3: Create Reverse Replication

Same as Option A, Steps 3-4.

### Step 4: Handle Conflicts

If subscription fails due to conflicts:

```sql
-- Skip conflicting transaction
ALTER SUBSCRIPTION dr_subscription SKIP (lsn = 'X/XXXXXXXX');

-- Or disable/re-enable with copy_data=false
ALTER SUBSCRIPTION dr_subscription DISABLE;
ALTER SUBSCRIPTION dr_subscription ENABLE;
```

### Step 5: Execute Failover

Follow [Failover Runbook](failover-runbook.md).

## Post-Failback Tasks

### Verify Operations

- [ ] Application connectivity verified
- [ ] Write operations working
- [ ] Read operations working
- [ ] Edge Functions operational
- [ ] Realtime connections established

### Update Configuration

- [ ] Update active-region flag
- [ ] Update monitoring dashboards
- [ ] Update documentation with new primary/standby roles

### Rebuild Standby Replication

Set up replication from new primary to new standby:

```sql
-- On new primary (Region A)
CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;
ALTER PUBLICATION dr_publication ADD TABLE auth.users, auth.identities;
SELECT pg_create_logical_replication_slot('dr_slot', 'pgoutput');

-- On new standby (Region B)
CREATE SUBSCRIPTION dr_subscription
CONNECTION 'host=<NEW_PRIMARY_HOST> port=5432 user=postgres password=<PASSWORD> dbname=postgres'
PUBLICATION dr_publication
WITH (
    copy_data = false,  -- Data already synced
    create_slot = false,
    slot_name = 'dr_slot'
);
```

## Troubleshooting

### Subscription Fails to Start

Check connection and permissions:

```bash
# Test connectivity
psql "postgresql://postgres:$PASSWORD@$HOST:5432/postgres" -c "SELECT 1"
```

### Replication Slot Growing

Monitor slot size:

```sql
SELECT
    slot_name,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
FROM pg_replication_slots;
```

### Data Conflicts

For duplicate key errors, either:
1. Delete conflicting rows on subscriber
2. Skip the transaction: `ALTER SUBSCRIPTION ... SKIP`
3. Recreate subscription with `copy_data = false`

## Timeline Example

| Time  | Action                           |
|-------|----------------------------------|
| T+0   | Announce maintenance window      |
| T+5m  | Verify old primary health        |
| T+10m | Begin reverse replication setup  |
| T+30m | Monitor replication catch-up     |
| T+60m | Verify data consistency          |
| T+70m | Execute failover                 |
| T+75m | Verify operations                |
| T+90m | Complete and notify stakeholders |

## Related Documents

- [Failover Runbook](failover-runbook.md)
- [Testing Runbook](testing-runbook.md)
- [Logical Replication Setup](../docs/logical-replication-setup.md)
