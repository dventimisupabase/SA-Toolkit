# DR Testing Runbook

This runbook provides a structured approach for testing the disaster recovery procedure.

## Overview

Regular DR testing ensures:
- Procedures work as documented
- Team is familiar with failover process
- RTO/RPO objectives are achievable
- Issues are discovered before real emergencies

## Recommended Testing Cadence

| Test Type | Frequency | Duration |
|-----------|-----------|----------|
| Health check verification | Weekly | 15 min |
| Replication lag monitoring | Daily (automated) | - |
| Tabletop exercise | Monthly | 1 hour |
| Full failover test | Quarterly | 2-4 hours |

## Pre-Test Checklist

- [ ] Test scheduled during low-traffic period
- [ ] Stakeholders notified
- [ ] Rollback plan documented
- [ ] Team members assigned roles
- [ ] Monitoring dashboards ready
- [ ] Communication channel established

## Test Types

### 1. Health Check Verification (Weekly)

Run all health check scripts and verify output:

```bash
# Run all health checks
./scripts/health/check_primary_health.sh
./scripts/health/check_standby_health.sh
./scripts/health/check_replication_lag.sh
./scripts/health/check_pgbouncer_health.sh
```

**Pass criteria:**
- All checks return exit code 0
- Replication lag < 100 MB
- All components accessible

### 2. Tabletop Exercise (Monthly)

Walk through the failover procedure without executing:

1. Gather team members
2. Present a scenario (e.g., "Primary region is down")
3. Have team describe each step they would take
4. Discuss decision points and edge cases
5. Document improvements

**See [Tabletop Exercises](tabletop-exercises.md) for detailed scenario scripts including:**
- Scenario 1: Primary Region Outage (standard)
- Scenario 2: Replication Lag Crisis (intermediate)
- Scenario 3: Partial Failure - PgBouncer Down (standard)
- Scenario 4: Split-Brain Prevention (advanced)
- Scenario 5: Cascading Failure During Failover (advanced)
- Scenario 6: The Non-Technical Stakeholder (communication)

**Discussion topics:**
- Who initiates failover?
- What approvals are needed?
- How do we communicate status?
- What if step X fails?

### 3. Partial Test (Quarterly - Option A)

Test individual components without full failover:

#### PgBouncer Pause/Resume Test

```bash
# Test pause
./scripts/pgbouncer/pause_pgbouncer.sh

# Verify connections queue (don't disconnect)
fly ssh console -a $FLY_APP_NAME -C \
    "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"

# Resume within 30 seconds
./scripts/pgbouncer/resume_pgbouncer.sh

# Verify connections recovered
```

#### Sequence Sync Test

```bash
# Dry run sequence sync
./scripts/failover/sync_sequences_for_failover.sh

# Verify sequences updated on standby
psql "postgresql://postgres:$POSTGRES_PASSWORD@$STANDBY_HOST:5432/postgres" -c "
    SELECT schemaname || '.' || sequencename, last_value
    FROM pg_sequences
    WHERE schemaname = 'public'
    ORDER BY sequencename;
"
```

### 4. Full Failover Test (Quarterly - Option B)

Complete failover and failback during maintenance window.

#### Phase 1: Pre-Test

```bash
# Record baseline metrics
./scripts/health/check_primary_health.sh > pre_test_primary.log
./scripts/health/check_standby_health.sh > pre_test_standby.log
./scripts/health/check_replication_lag.sh > pre_test_lag.log

# Record row counts
psql "$PRIMARY_CONN" -c "
    SELECT schemaname, relname, n_live_tup
    FROM pg_stat_user_tables
    WHERE schemaname = 'public'
    ORDER BY relname;
" > pre_test_rowcounts.log
```

#### Phase 2: Failover to Standby

```bash
# Start timer
START_TIME=$(date +%s)

# Execute failover
./scripts/failover/failover.sh

# Record completion time
END_TIME=$(date +%s)
FAILOVER_DURATION=$((END_TIME - START_TIME))
echo "Failover completed in $FAILOVER_DURATION seconds"
```

#### Phase 3: Verify Operations

```bash
# Test write to new primary
psql "postgresql://postgres:$POSTGRES_PASSWORD@$FLY_APP_NAME.fly.dev:5432/postgres" -c "
    CREATE TABLE IF NOT EXISTS dr_test (
        id SERIAL PRIMARY KEY,
        tested_at TIMESTAMPTZ DEFAULT now(),
        test_type TEXT
    );
    INSERT INTO dr_test (test_type) VALUES ('quarterly_dr_test');
    SELECT * FROM dr_test ORDER BY tested_at DESC LIMIT 1;
"

# Verify application connectivity
curl -s https://your-app.com/health | jq .

# Check for errors in application logs
# (application-specific)
```

#### Phase 4: Stabilization Period

Wait 15-30 minutes and monitor:

- Application error rates
- Response times
- User reports
- Database metrics

#### Phase 5: Failback

Follow [Failback Runbook](failback-runbook.md) to return to original configuration.

```bash
# Set up reverse replication (see failback-runbook.md)
# Wait for sync
# Execute failover back to original primary
```

#### Phase 6: Post-Test

```bash
# Verify original configuration restored
./scripts/health/check_primary_health.sh
./scripts/health/check_standby_health.sh

# Compare row counts
psql "$PRIMARY_CONN" -c "
    SELECT schemaname, relname, n_live_tup
    FROM pg_stat_user_tables
    WHERE schemaname = 'public'
    ORDER BY relname;
"

# Clean up test data
psql "$PRIMARY_CONN" -c "DROP TABLE IF EXISTS dr_test;"
```

## Test Report Template

```markdown
# DR Test Report

**Date:** YYYY-MM-DD
**Test Type:** [Full Failover / Partial / Tabletop]
**Participants:** [Names]

## Summary

| Metric | Target | Actual | Pass/Fail |
|--------|--------|--------|-----------|
| RTO | < 5 min | | |
| RPO | < 1 min lag | | |
| Data integrity | 100% | | |
| Rollback success | Yes | | |

## Timeline

| Time | Action | Result |
|------|--------|--------|
| HH:MM | Test started | |
| HH:MM | Failover initiated | |
| HH:MM | Failover completed | |
| HH:MM | Verification completed | |
| HH:MM | Failback initiated | |
| HH:MM | Failback completed | |
| HH:MM | Test ended | |

## Issues Encountered

1. [Issue description]
   - Impact: [Low/Medium/High]
   - Resolution: [How it was resolved]
   - Action item: [Follow-up needed]

## Lessons Learned

- [What worked well]
- [What needs improvement]

## Action Items

- [ ] [Action item 1] - Owner: [Name] - Due: [Date]
- [ ] [Action item 2] - Owner: [Name] - Due: [Date]

## Approval

Test conducted by: _______________
Test approved by: _______________
```

## Common Test Issues

### PgBouncer Pause Takes Too Long

Long-running transactions prevent pause completion.

**Solution:** Set reasonable timeouts or terminate long queries:
```sql
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'active' AND query_start < now() - interval '5 minutes';
```

### Replication Lag Too High

Large amount of data to sync before failover.

**Solution:**
- Test during low-traffic periods
- Investigate why lag is high
- Consider more frequent DR tests

### Application Errors After Failover

Connections not properly re-established.

**Solution:**
- Verify connection retry logic
- Check connection pooling settings
- Ensure applications use PgBouncer, not direct connections

### Sequence Conflicts After Failover

Primary key violations on new primary.

**Solution:**
- Increase sequence buffer
- Verify sync script ran successfully
- Consider UUIDs for new tables

## Automation Opportunities

Consider automating:

1. **Health checks**: Run via cron, alert on failure
2. **Replication lag monitoring**: Integrate with monitoring system
3. **Test scheduling**: Calendar reminders for quarterly tests
4. **Report generation**: Script to collect metrics

Example monitoring integration:

```bash
# Add to crontab for hourly lag check
0 * * * * /path/to/check_replication_lag.sh --alert-threshold-mb 100 || \
    curl -X POST $SLACK_WEBHOOK -d '{"text":"Replication lag alert!"}'
```

## Related Documents

- [Tabletop Exercises](tabletop-exercises.md) - Detailed scenario scripts for discussion-based training
- [Game Day Guide](game-day-guide.md) - Hands-on practice in sandbox environment
- [Failover Runbook](failover-runbook.md)
- [Failback Runbook](failback-runbook.md)
- [Emergency Runbook](emergency-runbook.md)
- [Architecture Overview](../docs/architecture-overview.md)
