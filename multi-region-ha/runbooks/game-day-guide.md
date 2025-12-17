# Game Day Guide

A Game Day is a scheduled, hands-on exercise where your team practices DR procedures in a realistic environment. Unlike tabletop exercises (discussion only) or production DR tests (real systems), Game Days use a dedicated sandbox environment to build muscle memory without risk.

## What is a Game Day?

| Aspect          | Tabletop  | Game Day        | Production DR Test |
|-----------------|-----------|-----------------|--------------------|
| Systems touched | None      | Sandbox/Staging | Production         |
| Risk level      | Zero      | Low             | Medium-High        |
| Realism         | Moderate  | High            | Highest            |
| Frequency       | Monthly   | Quarterly       | Quarterly          |
| Duration        | 1-2 hours | Half day        | 2-4 hours          |
| Team size       | 3-6       | 5-15            | 3-6                |

**Game Day philosophy**: Make it real enough to learn, safe enough to fail.

## Prerequisites

### Sandbox Environment

You need a parallel environment that mirrors production:

```
Production                          Sandbox
──────────────────                  ──────────────────
Supabase Project A (Primary)   →    Sandbox Project A
Supabase Project B (Standby)   →    Sandbox Project B
PgBouncer (Fly.io)             →    Sandbox PgBouncer
Your Application               →    Sandbox App Instance
```

**Setup checklist:**
- [ ] Two Supabase projects (can be free tier for sandbox)
- [ ] Separate Fly.io PgBouncer deployment
- [ ] Application instance pointing to sandbox
- [ ] Synthetic data (no real customer data!)
- [ ] Monitoring dashboards for sandbox
- [ ] Separate Slack channel or war room

### Team Roles

| Role                       | Responsibility                                       | Who                         |
|----------------------------|------------------------------------------------------|-----------------------------|
| **Game Master**            | Runs the exercise, injects failures, keeps time      | Senior engineer or SRE lead |
| **Incident Commander**     | Makes decisions, coordinates response                | On-call rotation member     |
| **Primary Responder**      | Executes procedures, runs commands                   | Engineer being trained      |
| **Secondary Responder**    | Assists, provides backup, watches for errors         | Buddy/shadow                |
| **Observer(s)**            | Takes notes, tracks metrics, no direct participation | Anyone learning             |
| **Stakeholder** (optional) | Practices communication, asks questions              | Manager or product person   |

### Materials

- [ ] This guide printed or on shared screen
- [ ] Runbooks accessible to all participants
- [ ] Credentials for sandbox environment
- [ ] Timer/stopwatch
- [ ] Shared document for notes
- [ ] Communication channel (Slack, video call)
- [ ] Coffee ☕

---

## Game Day Scenarios

### Scenario A: Standard Failover (Beginner)

**Duration**: 2 hours
**Objective**: Execute a complete failover and failback
**Success criteria**: Complete within target RTO, no data loss

#### Phase 1: Setup (30 min before)

**Game Master tasks:**
```bash
# Verify sandbox environment is ready
./scripts/health/check_primary_health.sh
./scripts/health/check_standby_health.sh
./scripts/health/check_replication_lag.sh
./scripts/health/check_pgbouncer_health.sh

# Seed some test data
psql $SANDBOX_PRIMARY -c "
  CREATE TABLE IF NOT EXISTS game_day_data (
    id SERIAL PRIMARY KEY,
    value TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
  );
  INSERT INTO game_day_data (value)
  SELECT 'record_' || generate_series(1, 1000);
"

# Record baseline
psql $SANDBOX_PRIMARY -c "SELECT count(*) FROM game_day_data;"
```

#### Phase 2: The Incident (15 min)

**Game Master announces:**

> "Alert! We've received reports that our primary database region is experiencing an outage. Supabase status page shows degraded performance. Our application is returning errors. This is a GAME DAY exercise - please treat it as a real incident."

**Game Master simulates outage:**
```bash
# Option 1: Block access to primary (if you control network)
# Option 2: Simply tell the team "primary is unreachable"
# Option 3: Change primary password temporarily (creates real auth failures)
```

**Team tasks:**
1. Incident Commander acknowledges and opens incident channel
2. Primary Responder begins diagnosis
3. Secondary Responder prepares runbooks

#### Phase 3: Failover Execution (30 min)

**Team executes failover following runbook:**

1. **Verify standby health**
   ```bash
   ./scripts/health/check_standby_health.sh
   ```

2. **Pause PgBouncer**
   ```bash
   ./scripts/pgbouncer/pause_pgbouncer.sh
   ```

3. **Attempt to freeze primary** (will fail - simulated outage)
   - Document decision to proceed without freeze

4. **Sync sequences** (estimate if primary unreachable)
   ```bash
   # If primary reachable:
   ./scripts/failover/sync_sequences_for_failover.sh

   # If not, estimate from standby:
   psql $SANDBOX_STANDBY -c "
     SELECT setval(schemaname || '.' || sequencename, last_value + 100000)
     FROM pg_sequences
     WHERE schemaname = 'public';
   "
   ```

5. **Promote standby**
   ```bash
   ./scripts/failover/promote_standby.sh
   ```

6. **Swap PgBouncer upstream**
   ```bash
   ./scripts/pgbouncer/swap_upstream.sh $SANDBOX_STANDBY_HOST
   ```

7. **Resume PgBouncer**
   ```bash
   ./scripts/pgbouncer/resume_pgbouncer.sh
   ```

**Game Master tracks:**
- Time for each step
- Any errors or confusion
- Deviations from runbook

#### Phase 4: Verification (15 min)

**Team verifies failover:**

```bash
# Test writes to new primary
psql "postgresql://postgres:xxx@sandbox-pgbouncer.fly.dev:5432/postgres" -c "
  INSERT INTO game_day_data (value) VALUES ('post_failover_test');
  SELECT * FROM game_day_data ORDER BY created_at DESC LIMIT 5;
"

# Verify application connectivity
curl https://sandbox-app.example.com/health

# Check for errors
./scripts/health/check_primary_health.sh  # Now points to former standby
```

#### Phase 5: Failback (30 min)

**Game Master announces:**

> "Original primary region has recovered. Let's fail back to restore normal configuration."

**Team executes failback:**

1. Restore original primary
2. Set up reverse replication
3. Wait for sync
4. Execute failover back

(Follow failback runbook)

#### Phase 6: Debrief (30 min)

**Metrics to review:**
- Total failover time (target: < 5 min)
- Total failback time
- Any data loss?
- Errors encountered

**Discussion:**
- What went well?
- What was confusing?
- Runbook gaps?
- Tool/access issues?

---

### Scenario B: Chaos Engineering (Intermediate)

**Duration**: 3 hours
**Objective**: Handle unexpected complications during failover
**Success criteria**: Recover from injected failures, maintain composure

#### Chaos Injections

The Game Master secretly plans 2-3 "chaos events" to inject during the exercise:

| Chaos Event               | When to Inject      | How to Simulate                            |
|---------------------------|---------------------|--------------------------------------------|
| PgBouncer unresponsive    | During pause step   | `fly scale count 0`                        |
| Wrong password in runbook | During promotion    | Change password, don't tell team           |
| Standby also "failing"    | After primary fails | Tell team "standby showing errors"         |
| Slack goes down           | Mid-incident        | "Slack is unreachable, use backup channel" |
| Key person "unavailable"  | During execution    | Primary responder must hand off            |
| Rollback required         | After failover      | "Critical bug found, roll back!"           |
| Executive joins call      | During recovery     | Have stakeholder start asking questions    |

#### Running Chaos Scenario

**Phase 1**: Start with standard failover scenario

**Phase 2**: Inject first chaos event when team is mid-procedure

**Phase 3**: Observe response - do they panic? Adapt? Follow procedures?

**Phase 4**: Inject second chaos event during recovery

**Phase 5**: Extended debrief focusing on adaptability

---

### Scenario C: Full Team Rotation (Advanced)

**Duration**: Half day (4 hours)
**Objective**: Every team member practices as Primary Responder
**Success criteria**: All participants complete at least one failover

#### Schedule

| Time | Activity                     | Primary Responder |
|------|------------------------------|-------------------|
| 0:00 | Setup, briefing              | -                 |
| 0:30 | Round 1: Standard failover   | Person A          |
| 1:15 | Round 1 debrief              | -                 |
| 1:30 | Round 2: Failover with chaos | Person B          |
| 2:15 | Round 2 debrief              | -                 |
| 2:30 | Break                        | -                 |
| 2:45 | Round 3: Emergency failover  | Person C          |
| 3:15 | Round 3 debrief              | -                 |
| 3:30 | Round 4: Communication focus | Person D          |
| 4:00 | Final debrief, action items  | -                 |

#### Between Rounds

Game Master resets environment:
```bash
# Reset to initial state
# - Restore original primary/standby roles
# - Recreate replication
# - Clear test data
# - Reset PgBouncer config
```

---

### Scenario D: New Hire Certification (Training)

**Duration**: 2 hours
**Objective**: Certify a new team member on DR procedures
**Success criteria**: New hire completes failover with minimal assistance

#### Structure

1. **Observation Round** (30 min)
   - Experienced engineer performs failover
   - New hire watches and asks questions
   - Explain each step and why

2. **Guided Round** (45 min)
   - New hire executes with experienced engineer coaching
   - Coach provides hints but doesn't touch keyboard
   - Note areas of confusion

3. **Solo Round** (30 min)
   - New hire executes independently
   - Coach observes but doesn't help unless stuck
   - Time the execution

4. **Certification** (15 min)
   - Review performance
   - Sign off on certification (or schedule retry)
   - Add to on-call rotation

#### Certification Checklist

```markdown
## DR Certification: [Name]

Date: ____________________
Evaluator: ____________________

### Skills Demonstrated

- [ ] Can locate and interpret runbooks
- [ ] Can execute health check scripts
- [ ] Can pause/resume PgBouncer
- [ ] Can promote standby database
- [ ] Can swap PgBouncer upstream
- [ ] Understands sequence synchronization
- [ ] Can verify successful failover
- [ ] Knows when to escalate
- [ ] Can communicate status clearly

### Failover Execution

| Metric | Target | Actual |
|--------|--------|--------|
| Total time | < 10 min | _____ |
| Errors made | < 3 | _____ |
| Help requested | < 5 | _____ |

### Result

- [ ] CERTIFIED - Ready for on-call
- [ ] RETRY - Schedule follow-up session

Notes:
_________________________________
_________________________________

Signatures:
Candidate: ____________________
Evaluator: ____________________
```

---

## Game Day Logistics

### Scheduling

**Best practices:**
- Schedule during business hours (not Friday afternoon)
- Block calendars 30 min before and after
- Send calendar invite with prep instructions
- Remind participants 24 hours before

**Sample invite:**

```
Subject: 🎮 DR Game Day - [Date] [Time]

Team,

We're running a DR Game Day to practice our failover procedures.

**When**: [Date], [Time] (2-3 hours)
**Where**: [Video link] + #game-day-[date] Slack channel
**Environment**: Sandbox (no production impact)

**Your role**: [Role assignment]

**Before the Game Day**:
- [ ] Review failover runbook
- [ ] Ensure you have sandbox credentials
- [ ] Test VPN/SSH access to sandbox

**What to bring**:
- Laptop with terminal access
- Runbooks (digital or printed)
- Questions!

This is a learning exercise. Mistakes are expected and valuable.

See you there!
```

### Communication Template

**Game Day start:**
```
🎮 GAME DAY STARTING

Environment: Sandbox
Scenario: [Name]
Duration: [X] hours

Roles:
- Game Master: @name
- Incident Commander: @name
- Primary Responder: @name
- Secondary: @name
- Observers: @name, @name

Remember: This is practice. Ask questions. Make mistakes. Learn.

Starting in 5 minutes...
```

**During exercise:**
```
⏱️ GAME DAY UPDATE

Status: [Phase]
Elapsed: [Time]
Current step: [Step]

[Brief status]
```

**Game Day end:**
```
🏁 GAME DAY COMPLETE

Total time: [X] minutes
Failover time: [X] minutes
Issues encountered: [X]

Debrief starting now in [channel/room].

Great work everyone!
```

### Environment Reset Script

```bash
#!/bin/bash
# reset_game_day_environment.sh
# Run between game day rounds to restore initial state

set -e

echo "=== Resetting Game Day Environment ==="

# 1. Ensure original primary is accessible
echo "Step 1: Verifying original primary..."
psql $SANDBOX_PRIMARY_ORIGINAL -c "SELECT 1" || {
    echo "ERROR: Cannot reach original primary"
    exit 1
}

# 2. Drop subscription on current standby (if exists)
echo "Step 2: Cleaning up replication..."
psql $SANDBOX_STANDBY -c "DROP SUBSCRIPTION IF EXISTS dr_subscription;" 2>/dev/null || true

# 3. Drop publication and slot on primary (if exists)
psql $SANDBOX_PRIMARY_ORIGINAL -c "DROP PUBLICATION IF EXISTS dr_publication;" 2>/dev/null || true
psql $SANDBOX_PRIMARY_ORIGINAL -c "SELECT pg_drop_replication_slot('dr_slot');" 2>/dev/null || true

# 4. Recreate publication and slot
echo "Step 3: Setting up fresh replication..."
psql $SANDBOX_PRIMARY_ORIGINAL -c "
    CREATE PUBLICATION dr_publication FOR TABLES IN SCHEMA public;
    SELECT pg_create_logical_replication_slot('dr_slot', 'pgoutput');
"

# 5. Truncate and resync standby (for speed in sandbox)
echo "Step 4: Resyncing standby..."
psql $SANDBOX_STANDBY -c "TRUNCATE game_day_data;"
psql $SANDBOX_STANDBY -c "
    CREATE SUBSCRIPTION dr_subscription
    CONNECTION 'host=$SANDBOX_PRIMARY_HOST ...'
    PUBLICATION dr_publication
    WITH (copy_data = true, create_slot = false, slot_name = 'dr_slot');
"

# 6. Reset PgBouncer to point to original primary
echo "Step 5: Resetting PgBouncer..."
fly secrets set DATABASE_HOST=$SANDBOX_PRIMARY_HOST -a sandbox-pgbouncer
fly ssh console -a sandbox-pgbouncer -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RELOAD;'"

# 7. Wait for replication to catch up
echo "Step 6: Waiting for replication sync..."
sleep 10
psql $SANDBOX_PRIMARY_ORIGINAL -c "
    SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn))
    FROM pg_replication_slots WHERE slot_name = 'dr_slot';
"

echo "=== Environment Reset Complete ==="
```

---

## Metrics and Scoring

### Individual Metrics

Track for each participant:

| Metric                     | Target             | Scoring                                   |
|----------------------------|--------------------|-------------------------------------------|
| Failover time              | < 5 min            | 3 pts if < 5, 2 pts if < 10, 1 pt if < 15 |
| Commands correct first try | > 80%              | 1 pt per 10% above 80                     |
| Runbook references         | Used appropriately | 2 pts if referenced, 0 if guessed         |
| Communication clarity      | Clear updates      | Subjective 1-3 pts                        |
| Error recovery             | Handled gracefully | 2 pts if recovered without help           |

### Team Metrics

Track across all Game Days:

```markdown
## Game Day Metrics Dashboard

### Failover Times (minutes)
| Date | Scenario | Time | Target | Met? |
|------|----------|------|--------|------|
| 2024-01-15 | Standard | 4:32 | 5:00 | ✅ |
| 2024-02-20 | Chaos | 8:15 | 10:00 | ✅ |
| 2024-03-18 | Standard | 3:58 | 5:00 | ✅ |

### Trend
[Chart showing improvement over time]

### Common Issues
1. Sequence sync confusion (3 occurrences)
2. PgBouncer password in wrong place (2 occurrences)
3. Forgot to verify after failover (2 occurrences)

### Certifications
- Total team members: 8
- Certified: 6
- Pending: 2 (scheduled for Q2)
```

---

## After the Game Day

### Immediate (Same Day)

1. Send debrief notes to team
2. File action items as tickets
3. Thank participants

### Within One Week

1. Update runbooks based on findings
2. Fix any tooling issues discovered
3. Schedule next Game Day

### Quarterly Review

1. Review Game Day metrics trend
2. Assess team readiness
3. Plan next quarter's scenarios
4. Update certification requirements if needed

---

## Sample Annual Game Day Calendar

| Quarter | Month     | Scenario            | Focus         |
|---------|-----------|---------------------|---------------|
| Q1      | January   | Standard Failover   | Baseline      |
| Q1      | February  | New Hire Cert       | [Name]        |
| Q1      | March     | Chaos Engineering   | Adaptability  |
| Q2      | April     | Full Team Rotation  | Coverage      |
| Q2      | May       | New Hire Cert       | [Name]        |
| Q2      | June      | Communication Focus | Stakeholders  |
| Q3      | July      | Standard Failover   | Refresh       |
| Q3      | August    | Production DR Test  | Real systems  |
| Q3      | September | Chaos Engineering   | Advanced      |
| Q4      | October   | Full Team Rotation  | Coverage      |
| Q4      | November  | Emergency Scenario  | Speed         |
| Q4      | December  | Annual Review       | Retrospective |

---

## Related Documents

- [Tabletop Exercises](tabletop-exercises.md) - Discussion-based scenarios
- [Testing Runbook](testing-runbook.md) - Production DR test procedures
- [Failover Runbook](failover-runbook.md) - The actual procedure
- [Emergency Runbook](emergency-runbook.md) - When things go wrong
