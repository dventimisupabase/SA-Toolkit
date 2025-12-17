# Emergency Runbook

This runbook is for emergency failover when the primary is completely unreachable.

## When to Use This Runbook

- Primary region is completely down
- Cannot connect to primary database
- Need to restore service immediately
- Willing to accept data loss for faster recovery

## Key Differences from Standard Failover

| Step | Standard | Emergency |
|------|----------|-----------|
| Freeze primary | Yes | **Skip** (unreachable) |
| Sequence sync | From primary | **Skip or estimate** |
| Data loss | Minimal | **Possible** |
| Recovery time | Longer | **Faster** |

## Immediate Actions

### 1. Confirm Primary is Unreachable

```bash
# Try to connect
psql "postgresql://postgres:$POSTGRES_PASSWORD@$PRIMARY_HOST:5432/postgres" -c "SELECT 1"

# Check from multiple locations
curl -I https://db.$PRIMARY_REF.supabase.co:5432 || echo "Unreachable"
```

### 2. Check Standby Health

```bash
./scripts/health/check_standby_health.sh
```

If standby is also unhealthy, this is a multi-region outage. Contact Supabase support.

### 3. Assess Replication Lag

Check what was the last replicated data:

```sql
-- On standby
SELECT
    subname,
    last_msg_receipt_time,
    age(now(), last_msg_receipt_time) AS time_since_last_msg
FROM pg_stat_subscription
WHERE subname = 'dr_subscription';
```

**Document this for RPO calculation.**

## Emergency Failover Procedure

### Step 1: Pause PgBouncer

```bash
./scripts/pgbouncer/pause_pgbouncer.sh
```

### Step 2: Skip Primary Freeze

Primary is unreachable. Acknowledge:
- Any in-flight transactions on primary are lost
- Data written after last replication sync is lost

**Document the decision and timestamp.**

### Step 3: Estimate Sequence Values

Since we can't read sequences from primary, estimate them:

```sql
-- On standby: Get current max IDs and add large buffer
SELECT
    'public.users' AS table_name,
    COALESCE(MAX(id), 0) + 100000 AS safe_sequence_value
FROM public.users
UNION ALL
SELECT
    'public.orders',
    COALESCE(MAX(id), 0) + 100000
FROM public.orders;
-- Add all tables with sequences
```

Set sequences on standby:

```sql
-- Set each sequence with large buffer
SELECT setval('public.users_id_seq', (SELECT COALESCE(MAX(id), 0) + 100000 FROM public.users));
SELECT setval('public.orders_id_seq', (SELECT COALESCE(MAX(id), 0) + 100000 FROM public.orders));
-- Repeat for all sequences
```

### Step 4: Promote Standby

```bash
./scripts/failover/promote_standby.sh
```

Or manually:

```sql
-- On standby
ALTER SUBSCRIPTION dr_subscription DISABLE;
DROP SUBSCRIPTION dr_subscription;
```

### Step 5: Swap PgBouncer

```bash
./scripts/pgbouncer/swap_upstream.sh $STANDBY_HOST
```

### Step 6: Resume PgBouncer

```bash
./scripts/pgbouncer/resume_pgbouncer.sh
```

## Quick Emergency Commands

If you need to execute quickly, here's the minimal command set:

```bash
# 1. Pause
fly ssh console -a $FLY_APP_NAME -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'PAUSE;'"

# 2. Promote standby
psql "postgresql://postgres:$POSTGRES_PASSWORD@$STANDBY_HOST:5432/postgres" \
    -c "ALTER SUBSCRIPTION dr_subscription DISABLE; DROP SUBSCRIPTION dr_subscription;"

# 3. Swap upstream
fly secrets set DATABASE_HOST=$STANDBY_HOST -a $FLY_APP_NAME

# 4. Resume
fly ssh console -a $FLY_APP_NAME -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RESUME;'"
```

## Post-Emergency Actions

### Immediate

- [ ] Verify application connectivity
- [ ] Test write operations
- [ ] Monitor for errors
- [ ] Notify stakeholders

### Document Data Loss

```sql
-- Query for potentially lost data
-- Records created/modified after last replication sync

-- Check user registrations
SELECT COUNT(*) AS potential_lost_users
FROM auth.users
WHERE created_at > '<last_replication_time>';

-- Check orders
SELECT COUNT(*) AS potential_lost_orders
FROM public.orders
WHERE created_at > '<last_replication_time>';
```

### Prevent Split-Brain

When primary becomes reachable again:

1. **DO NOT** allow applications to connect to old primary
2. **DO NOT** re-enable old replication
3. Freeze or isolate the old primary immediately:

```sql
-- When old primary becomes reachable
-- IMMEDIATELY freeze it
ALTER DATABASE postgres SET default_transaction_read_only = on;

-- Revoke all connections except yours
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE datname = 'postgres' AND pid != pg_backend_pid();
```

### Recovery Planning

After emergency failover:

1. Assess old primary data
2. Identify any data that was on primary but not replicated
3. Plan manual data recovery if needed
4. Rebuild old primary as new standby (see [Failback Runbook](failback-runbook.md))

## Communication Template

### Initial Notification

```
INCIDENT: Database Failover in Progress

Status: Emergency failover initiated
Reason: Primary database region unreachable
Impact: Brief service interruption, possible data loss for very recent transactions
ETA: [X] minutes

Updates will follow.
```

### Completion Notification

```
INCIDENT RESOLVED: Database Failover Complete

Status: Service restored
Duration: [X] minutes
Data Impact: Transactions after [timestamp] may be lost
New Primary: [Region B]

Post-incident review scheduled for [date].
```

## Metrics to Record

| Metric | Value |
|--------|-------|
| Incident start time | |
| Primary declared unreachable | |
| Failover initiated | |
| Failover completed | |
| Total RTO | |
| Last replication timestamp | |
| Estimated data loss window | |

## When to Escalate

Contact Supabase support if:
- Both primary and standby are unreachable
- Standby promotion fails
- Data corruption suspected
- Extended outage (>1 hour)

## Related Documents

- [Failover Runbook](failover-runbook.md) (standard procedure)
- [Failback Runbook](failback-runbook.md) (after recovery)
- [Architecture Overview](../docs/architecture-overview.md)
