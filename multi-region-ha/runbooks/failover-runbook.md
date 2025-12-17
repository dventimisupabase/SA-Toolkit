# Failover Runbook

This runbook provides step-by-step instructions for failing over from the primary Supabase project to the standby.

## When to Use This Runbook

- Primary region experiencing outage
- Planned maintenance requiring region switch
- DR test (use [Testing Runbook](testing-runbook.md) for scheduled tests)

## Prerequisites

Before starting:

- [ ] Access to both Supabase projects (dashboard and psql)
- [ ] Fly.io CLI authenticated (`flyctl auth login`)
- [ ] Configuration file ready (`config/.env`)
- [ ] Stakeholders notified of impending failover

## Pre-Failover Checklist

- [ ] Verify standby is healthy: `./scripts/health/check_standby_health.sh`
- [ ] Check replication lag: `./scripts/health/check_replication_lag.sh`
- [ ] Verify PgBouncer status: `./scripts/health/check_pgbouncer_health.sh`
- [ ] Note current time (for RPO calculation)

## Automated Failover

For standard failover, use the orchestration script:

```bash
cd multi-region-ha/

# Full failover
./scripts/failover/failover.sh

# Emergency failover (if primary unreachable)
./scripts/failover/failover.sh --skip-freeze
```

The script will:
1. Pause PgBouncer
2. Freeze primary (unless --skip-freeze)
3. Sync sequences
4. Promote standby
5. Swap PgBouncer upstream
6. Resume PgBouncer

## Manual Failover Steps

If the automated script fails or you need more control, follow these manual steps.

### Step 1: Pause PgBouncer

Pause all connections. They will queue (not disconnect).

```bash
./scripts/pgbouncer/pause_pgbouncer.sh
```

Or manually:

```bash
fly ssh console -a $FLY_APP_NAME -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'PAUSE;'"
```

**Verification:**
```bash
fly ssh console -a $FLY_APP_NAME -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"
```
- `cl_waiting` should show queued connections
- `sv_active` should be 0 after transactions complete

### Step 2: Freeze Primary (If Reachable)

Prevent any new writes to avoid split-brain.

```bash
./scripts/failover/freeze_primary.sh
```

Or manually:

```bash
psql "postgresql://postgres:$POSTGRES_PASSWORD@$PRIMARY_HOST:5432/postgres" \
    -c "ALTER DATABASE postgres SET default_transaction_read_only = on;"
```

**If primary is unreachable:** Skip this step. Acknowledge potential data loss.

### Step 3: Synchronize Sequences

Sequences are not replicated. Sync them with a buffer.

```bash
./scripts/failover/sync_sequences_for_failover.sh
```

Or manually:

```bash
# Get sequences from primary
psql "postgresql://postgres:$POSTGRES_PASSWORD@$PRIMARY_HOST:5432/postgres" -t -A -c "
    SELECT format('SELECT setval(%L, %s);', schemaname || '.' || sequencename, last_value + 10000)
    FROM pg_sequences
    WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
"

# Run output on standby
psql "postgresql://postgres:$POSTGRES_PASSWORD@$STANDBY_HOST:5432/postgres" <<< "
    -- Paste generated setval statements here
"
```

### Step 4: Promote Standby

Drop the subscription to make standby writable.

```bash
./scripts/failover/promote_standby.sh
```

Or manually:

```bash
psql "postgresql://postgres:$POSTGRES_PASSWORD@$STANDBY_HOST:5432/postgres" <<EOF
ALTER SUBSCRIPTION dr_subscription DISABLE;
DROP SUBSCRIPTION dr_subscription;
EOF
```

**Verification:**
```sql
-- Should return 0
SELECT count(*) FROM pg_subscription WHERE subname = 'dr_subscription';
```

### Step 5: Swap PgBouncer Upstream

Point PgBouncer to the new primary.

```bash
./scripts/pgbouncer/swap_upstream.sh $STANDBY_HOST
```

Or manually:

```bash
fly secrets set DATABASE_HOST=$STANDBY_HOST -a $FLY_APP_NAME
sleep 2
fly ssh console -a $FLY_APP_NAME -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RELOAD;'"
```

**Verification:**
```bash
fly ssh console -a $FLY_APP_NAME -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW DATABASES;'"
```

### Step 6: Resume PgBouncer

Allow queued connections to proceed.

```bash
./scripts/pgbouncer/resume_pgbouncer.sh
```

Or manually:

```bash
fly ssh console -a $FLY_APP_NAME -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RESUME;'"
```

**Verification:**
- Connections should begin flowing
- Application logs should show successful queries

## Post-Failover Verification

### Immediate Checks

- [ ] Test application connectivity
- [ ] Verify writes work on new primary
- [ ] Check for errors in application logs
- [ ] Verify Edge Functions work (if applicable)
- [ ] Test Realtime connections (clients should reconnect)

### Sample Verification Queries

```sql
-- On new primary: verify writable
INSERT INTO public.health_check (checked_at) VALUES (now());

-- Verify row count matches expectations
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY relname;
```

### Update External Systems

- [ ] Update active-region flag (DNS, feature flags, etc.)
- [ ] Update monitoring to point to new primary
- [ ] Update any direct database connections
- [ ] Notify stakeholders of completion

## Rollback Procedure

If failover fails partway through:

### If PgBouncer Still Paused

1. Swap upstream back to original primary:
   ```bash
   fly secrets set DATABASE_HOST=$PRIMARY_HOST -a $FLY_APP_NAME
   ```

2. Resume PgBouncer:
   ```bash
   fly ssh console -a $FLY_APP_NAME -C \
       "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RESUME;'"
   ```

3. Unfreeze primary (if frozen):
   ```bash
   psql "postgresql://postgres:$POSTGRES_PASSWORD@$PRIMARY_HOST:5432/postgres" \
       -c "ALTER DATABASE postgres RESET default_transaction_read_only;"
   ```

### If Standby Already Promoted

You cannot rollback to the original primary without data loss. Proceed with:
1. Complete the failover to standby
2. Plan to rebuild original primary as new standby
3. Schedule failback when stable (see [Failback Runbook](failback-runbook.md))

## Metrics to Record

Document these for post-incident review:

| Metric                      | Value |
|-----------------------------|-------|
| Failover start time         |       |
| PgBouncer pause time        |       |
| Failover complete time      |       |
| Total RTO                   |       |
| Replication lag at failover |       |
| Estimated RPO               |       |
| Errors encountered          |       |

## Troubleshooting

### PgBouncer Won't Pause

Check if it's already paused:
```bash
fly ssh console -a $FLY_APP_NAME -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"
```

### Can't Connect to Primary

Use `--skip-freeze` option. Accept potential data loss.

### Subscription Drop Fails

Check if already dropped:
```sql
SELECT * FROM pg_subscription WHERE subname = 'dr_subscription';
```

### Applications Still Connecting to Old Primary

Verify:
1. PgBouncer upstream was updated
2. Applications are using PgBouncer, not direct connection
3. DNS has propagated (if using DNS)

## Related Documents

- [Architecture Overview](../docs/architecture-overview.md)
- [Emergency Runbook](emergency-runbook.md) (if primary completely down)
- [Failback Runbook](failback-runbook.md) (to return to original primary)
- [Testing Runbook](testing-runbook.md) (for DR testing)
