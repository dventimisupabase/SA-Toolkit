# pg-telemetry

**"What was happening in my database?"**

Server-side performance telemetry for PostgreSQL. Runs entirely inside your database using standard extensions.
Think of it as "Active Session History" (ASH) for Supabase and RDS.

## 🚀 Quick Start

### Supabase
```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

### Standard PostgreSQL (15+)
Requires `pg_cron`.
```bash
psql -d my_db -f install.sql
```

## 📊 Top Commands

Once installed, it runs automatically. Use these SQL queries to see what's happening:

| Goal                       | Query                                                                             |
|----------------------------|-----------------------------------------------------------------------------------|
| **See current activity**   | `SELECT * FROM telemetry.recent_activity;`                                        |
| **Diagnose a slow period** | `SELECT * FROM telemetry.compare('2024-01-01 10:00', '2024-01-01 11:00');`        |
| **Find what's waiting**    | `SELECT * FROM telemetry.wait_summary('2024-01-01 10:00', '2024-01-01 11:00');`   |
| **Auto-detect issues**     | `SELECT * FROM telemetry.anomaly_report('2024-01-01 10:00', '2024-01-01 11:00');` |

## ⚙️ Configuration

**System under load?** Switch to emergency mode to reduce overhead:
```sql
SELECT telemetry.set_mode('emergency'); -- Stops locks/progress tracking
SELECT telemetry.set_mode('normal');    -- Back to full detail
```

**Kill Switch:**
```sql
SELECT telemetry.disable(); -- Stops everything immediately
```

## 🛡️ Safety
Built for production.
*   **Circuit Breakers:** Auto-skips collection if the DB is stressed.
*   **Timeouts:** Queries kill themselves if they take >2s.
*   **Storage Limits:** Auto-disables if telemetry grows >10GB.

---
*For deep internals, schema details, and advanced configuration, see [REFERENCE.md](REFERENCE.md).*
