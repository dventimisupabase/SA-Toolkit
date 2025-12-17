# Tabletop Exercise Scenarios

This document provides detailed scenario scripts for DR tabletop exercises. Use these to train your team and validate your procedures without touching production systems.

## How to Run a Tabletop Exercise

### Format

1. **Facilitator**: Reads the scenario and injects complications
2. **Participants**: On-call engineers, DBAs, team leads
3. **Observer** (optional): Takes notes, tracks time, identifies gaps
4. **Duration**: 45-90 minutes per scenario

### Ground Rules

- No actual systems are touched
- Assume you have the access you normally would
- Think out loud - explain your reasoning
- It's okay to say "I don't know" - that's a learning opportunity
- Reference runbooks as you would in a real incident

### Debrief Questions

After each scenario:
1. What went well?
2. What was confusing or unclear?
3. What's missing from our runbooks?
4. Who else should have been involved?
5. What tools or access were we missing?

---

## Scenario 1: Primary Region Outage

**Difficulty**: Standard
**Estimated Time**: 45 minutes
**Focus**: Core failover procedure

### Setup

> *It's Tuesday at 2:47 PM. You receive a PagerDuty alert: "Primary database health check failed." You check the Supabase status page - there's an incident affecting your primary region.*

### Scene 1: Initial Detection

**Facilitator reads:**

> Your monitoring shows:
> - `check_primary_health.sh` - FAILED (connection timeout)
> - `check_standby_health.sh` - PASSED
> - `check_replication_lag.sh` - Cannot connect to primary
> - `check_pgbouncer_health.sh` - PASSED (but queries timing out)
>
> Customer support is reporting users can't log in. Your application error rate has spiked to 80%.

**Discussion prompts:**
- What's your first action?
- Who do you notify?
- How do you confirm this is a regional outage vs. a Supabase-specific issue?
- What's your decision threshold for initiating failover?

### Scene 2: Decision Point

**Facilitator reads:**

> It's now 2:55 PM. Supabase status page confirms: "We are investigating connectivity issues in [your region]. Some projects may experience degraded performance."
>
> You still cannot connect to the primary database. The standby is healthy with replication lag unknown (can't query primary).

**Discussion prompts:**
- Do you wait for Supabase to resolve, or initiate failover?
- What's the business impact of waiting vs. failing over?
- Who has authority to make this decision?
- What information do you need before proceeding?

### Scene 3: Failover Execution

**Facilitator reads:**

> Leadership approves failover at 3:02 PM. You begin the procedure.

**Walk through each step:**
1. How do you pause PgBouncer?
2. The primary is unreachable - can you freeze it? What do you do?
3. How do you handle sequence synchronization without primary access?
4. Walk through promoting the standby
5. How do you swap PgBouncer upstream?
6. How do you verify the failover worked?

**Inject complication** (optional):

> While promoting the standby, you get an error: "subscription 'dr_subscription' does not exist"

- What might have caused this?
- How do you proceed?

### Scene 4: Post-Failover

**Facilitator reads:**

> Failover completed at 3:15 PM. Applications are connecting to the new primary. Error rates are dropping.

**Discussion prompts:**
- What verification steps do you perform?
- How do you communicate status to stakeholders?
- What's your RPO estimate for this incident?
- When/how do you plan failback?
- What do you do when the original primary comes back online?

### Debrief

- Total "time" elapsed: ~28 minutes
- Was this within RTO target?
- What documentation was missing or unclear?
- Any access or tooling gaps?

---

## Scenario 2: Replication Lag Crisis

**Difficulty**: Intermediate
**Estimated Time**: 60 minutes
**Focus**: Monitoring, troubleshooting, preventive action

### Setup

> *It's Friday at 4:30 PM. You're about to leave for the weekend when you notice an alert: "Replication lag exceeds 500 MB".*

### Scene 1: Investigation

**Facilitator reads:**

> Your monitoring shows:
> - Primary: Healthy, high CPU (85%)
> - Standby: Healthy, subscription active
> - Replication lag: 523 MB and growing
> - PgBouncer: Healthy
>
> Checking `pg_stat_activity` on primary shows several long-running queries from a batch job.

**Discussion prompts:**
- Is this an emergency?
- What's the risk if lag continues to grow?
- How do you identify what's causing the lag?
- Should you intervene with the batch job?

### Scene 2: Escalation

**Facilitator reads:**

> It's now 5:15 PM. Lag has grown to 1.2 GB. The batch job is still running - it's a critical month-end report that takes 2-3 hours.
>
> You check disk space on primary: WAL retention is consuming 4 GB, with 20 GB free.

**Discussion prompts:**
- What's your concern with WAL retention?
- At what point does this become critical?
- Do you contact the team running the batch job?
- What are your options?

### Scene 3: Decision Time

**Facilitator reads:**

> At 6:00 PM, lag is at 2.8 GB. The batch job owner says it needs another hour.
>
> You calculate: at current rate, you'll hit disk pressure in ~3 hours.

**Options to discuss:**
1. Let it ride - batch job finishes, lag catches up
2. Kill the batch job
3. Temporarily increase primary disk (if possible)
4. Accept degraded DR posture until caught up

**Discussion prompts:**
- What's the business impact of each option?
- Who makes this call?
- How do you document this decision?

### Scene 4: Resolution

**Facilitator reads:**

> The batch job completes at 7:15 PM. Over the next 45 minutes, replication catches up. By 8:00 PM, lag is back to normal (< 1 MB).

**Discussion prompts:**
- What preventive measures should you implement?
- Should batch jobs be scheduled differently?
- Do you need better alerting thresholds?
- How do you prevent this from happening during an actual outage?

### Debrief

- Was the monitoring adequate?
- Were alert thresholds appropriate?
- What changes would prevent this scenario?

---

## Scenario 3: Partial Failure - PgBouncer Down

**Difficulty**: Standard
**Estimated Time**: 45 minutes
**Focus**: Component failure, fallback options

### Setup

> *It's Monday at 10:15 AM. Support tickets are flooding in: "Can't connect to database." Your application health checks are failing.*

### Scene 1: Diagnosis

**Facilitator reads:**

> Initial investigation:
> - Application logs: "Connection refused" to PgBouncer
> - `fly status` shows your PgBouncer app is in a crash loop
> - Direct connection to Supabase primary works fine
> - Standby is healthy, replication is current

**Discussion prompts:**
- What's your immediate action?
- Should you fail over to standby?
- What are your options for restoring service quickly?

### Scene 2: Immediate Response

**Options to discuss:**

1. **Fix PgBouncer** - Debug the crash, redeploy
2. **Bypass PgBouncer** - Point apps directly to Supabase (temporarily)
3. **Failover** - Not applicable (both DBs are fine)

**Discussion prompts:**
- What's the fastest path to restoring service?
- What's the risk of bypassing PgBouncer?
- How do you update application connection strings quickly?
- Do you have a runbook for this scenario?

### Scene 3: Recovery

**Facilitator reads:**

> You check PgBouncer logs via `fly logs`:
> ```
> FATAL: could not connect to server: connection refused
> Is the server running on host "db.xxxxx.supabase.co"
> ```
>
> It appears the DATABASE_HOST secret was accidentally changed during a config update this morning.

**Discussion prompts:**
- How do you fix the secret?
- How do you prevent this from happening again?
- Should config changes require review?

### Scene 4: Post-Mortem Items

**Facilitator reads:**

> Service restored at 10:45 AM. Total outage: 30 minutes.

**Discussion prompts:**
- What's the root cause?
- What process changes are needed?
- Should you have a "break glass" procedure for bypassing PgBouncer?
- How do you communicate this to customers?

---

## Scenario 4: Split-Brain Prevention

**Difficulty**: Advanced
**Estimated Time**: 75 minutes
**Focus**: Edge cases, data integrity, worst-case handling

### Setup

> *It's Saturday at 3:00 AM. You're woken by alerts. Both primary AND standby appear to be accepting writes.*

### Scene 1: The Horror

**Facilitator reads:**

> You investigate and find:
> - Primary: Online, accepting writes
> - Standby: Subscription was somehow dropped, also accepting writes
> - PgBouncer: Pointed at... you're not sure which one
> - Some application instances are hitting primary directly (legacy config)
>
> Both databases have new rows that don't exist in the other.

**Discussion prompts:**
- How did this happen? (Theorize)
- What's your immediate priority?
- How do you stop the bleeding?

### Scene 2: Stop the Bleeding

**Facilitator reads:**

> You need to choose ONE source of truth immediately.

**Discussion prompts:**
- How do you decide which database becomes authoritative?
- How do you prevent further writes to the other?
- What about in-flight transactions?

**Walk through:**
1. Pause PgBouncer (stop new connections)
2. Identify which DB has more/newer critical data
3. Freeze the non-authoritative database
4. Point everything to the authoritative one
5. Resume service

### Scene 3: Data Reconciliation

**Facilitator reads:**

> Service is restored with DB-A as authoritative. DB-B has ~15 minutes of writes that don't exist in DB-A, including:
> - 3 new user registrations
> - 47 orders
> - Various other records

**Discussion prompts:**
- How do you identify the orphaned data?
- Can you merge it? Should you?
- What do you tell affected customers?
- What's the business impact?

### Scene 4: Root Cause

**Facilitator reads:**

> Investigation reveals: During a maintenance window last week, someone manually dropped the subscription to "test something" and forgot to recreate it. No one noticed because health checks only verified connectivity, not replication status.

**Discussion prompts:**
- How do you prevent this in the future?
- What monitoring was missing?
- Should subscription status be a critical alert?
- What change management process failed?

### Debrief

- This is a worst-case scenario - how prepared were you?
- What safeguards should exist?
- Is your monitoring sufficient?

---

## Scenario 5: Cascading Failure During Failover

**Difficulty**: Advanced
**Estimated Time**: 90 minutes
**Focus**: Handling complications, decision-making under pressure

### Setup

> *Primary region has been degraded for 20 minutes. Leadership has approved failover. You begin the procedure...*

### Scene 1: Step 1 Fails

**Facilitator reads:**

> You attempt to pause PgBouncer:
> ```
> $ fly ssh console -a my-pgbouncer -C "psql ... -c 'PAUSE;'"
> Error: ssh: connect to host failed: connection timed out
> ```
>
> Fly.io appears to be having issues in your PgBouncer's region as well.

**Discussion prompts:**
- Can you proceed without pausing PgBouncer?
- What are the risks?
- Do you have SSH access another way?
- Should you wait for Fly.io to recover?

### Scene 2: Partial Progress

**Facilitator reads:**

> After 10 minutes, Fly.io recovers. You successfully pause PgBouncer and freeze the primary.
>
> You attempt sequence synchronization, but it fails - primary is now unreachable again.

**Discussion prompts:**
- You've already frozen the primary. What now?
- How do you estimate safe sequence values?
- Do you proceed with promotion?

### Scene 3: Promotion Complications

**Facilitator reads:**

> You promote the standby by dropping the subscription. It succeeds.
>
> You swap PgBouncer upstream to the new primary and resume.
>
> Applications start connecting, but you see errors:
> ```
> ERROR: duplicate key value violates unique constraint
> ```

**Discussion prompts:**
- What's happening?
- How do you diagnose which sequences are affected?
- Can you fix this without downtime?

### Scene 4: Stabilization

**Walk through resolution:**
1. Identify affected sequences
2. Set them to values beyond the conflicts
3. Retry failed transactions (if possible)
4. Communicate with affected users

### Scene 5: Post-Incident

**Facilitator reads:**

> After 90 minutes of total incident time, service is stable. You have:
> - 15 minutes of potential data loss (RPO)
> - 90 minutes of degraded service (RTO)
> - ~200 failed transactions due to sequence conflicts

**Discussion prompts:**
- Was this acceptable?
- What would have made this go smoother?
- What's the remediation for affected customers?
- How do you rebuild the standby?

---

## Scenario 6: The Non-Technical Stakeholder

**Difficulty**: Communication-focused
**Estimated Time**: 30 minutes
**Focus**: Incident communication, managing expectations

### Setup

> *You're 10 minutes into a failover. Your CEO joins the incident bridge call.*

### Scene 1: The Questions

**Facilitator (playing CEO) asks:**

1. "What's happening and why can't customers use the app?"
2. "How long until this is fixed?"
3. "Why didn't we prevent this?"
4. "Should we be posting on social media?"
5. "What do I tell the board?"

**Practice responding to each question:**
- Use non-technical language
- Be honest about uncertainty
- Provide clear timelines (or explain why you can't)
- Suggest specific actions they can take

### Scene 2: The Update Request

**Facilitator reads:**

> CEO: "I need to send an update to our investors in 15 minutes. Give me 2-3 sentences on what happened and what we're doing."

**Write a draft update together:**
- What information is essential?
- What should you NOT say?
- How do you convey confidence without overpromising?

### Scene 3: The Follow-Up

**Facilitator reads:**

> Incident is resolved. CEO asks: "I want a one-pager for the board explaining our DR capabilities and why we're confident this won't happen again."

**Discussion prompts:**
- What key points belong in this document?
- How do you explain RPO/RTO to non-technical readers?
- What improvements can you commit to?

---

## Quick Reference: Facilitation Tips

### Setting the Mood
- Treat it seriously but keep it educational
- It's okay to pause and reference documentation
- Encourage questions and "what ifs"

### Injecting Complications
- Don't make everything go wrong - pick 1-2 twists per scenario
- Complications should be realistic, not absurd
- Give participants time to think before adding more pressure

### Managing Time
- Keep scenes moving (10-15 min each)
- If stuck, offer hints or skip ahead
- Leave time for debrief - it's the most valuable part

### Following Up
- Document action items
- Update runbooks based on gaps found
- Schedule the next exercise

---

## Exercise Log Template

```markdown
## Tabletop Exercise Log

**Date:** YYYY-MM-DD
**Scenario:** [Name]
**Facilitator:** [Name]
**Participants:** [Names]
**Duration:** [X] minutes

### Key Decisions Made
1. [Decision and reasoning]
2. [Decision and reasoning]

### Gaps Identified
1. [Gap in documentation/process]
2. [Missing tool or access]

### Action Items
- [ ] [Action] - Owner: [Name] - Due: [Date]
- [ ] [Action] - Owner: [Name] - Due: [Date]

### Runbook Updates Needed
- [ ] [Runbook]: [Section to update]
- [ ] [Runbook]: [Section to add]

### Next Exercise
**Scenario:** [Name]
**Scheduled:** [Date]
```

---

## Related Documents

- [Testing Runbook](testing-runbook.md)
- [Failover Runbook](failover-runbook.md)
- [Emergency Runbook](emergency-runbook.md)
- [Failback Runbook](failback-runbook.md)
