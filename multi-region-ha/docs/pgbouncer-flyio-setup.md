# PgBouncer on Fly.io Setup

This guide walks through deploying PgBouncer on Fly.io as the stable connection endpoint for the multi-region Supabase HA architecture.

## Why PgBouncer?

PgBouncer serves as the stable endpoint between applications and Supabase:

1. **Endpoint stability**: Applications connect to one address; upstream can change
2. **Connection pooling**: Reduces connection overhead to Supabase
3. **Failover support**: PAUSE/RESUME enables zero-downtime upstream swap
4. **Multi-region**: Deploy close to users for lower latency

## Why Fly.io?

- Global edge network with 30+ regions
- Simple deployment and scaling
- Built-in secrets management
- Pay-per-use pricing
- Easy SSH access for administration

## Prerequisites

- [ ] Fly.io account created
- [ ] Credit card added to Fly.io account
- [ ] `flyctl` CLI installed
- [ ] Primary Supabase project connection details

```bash
# Install flyctl
curl -L https://fly.io/install.sh | sh

# Verify installation
flyctl version

# Authenticate
flyctl auth login
```

## Step 1: Prepare Deployment Files

The deployment files are in the `flyio/` directory:

```
flyio/
├── fly.toml              # Fly.io configuration
├── Dockerfile            # Container image
├── pgbouncer.ini.template # PgBouncer config template
├── userlist.txt.template # Authentication file template
├── entrypoint.sh         # Startup script
└── README.md             # Deployment instructions
```

## Step 2: Create Fly.io App

```bash
cd multi-region-ha/flyio/

# Create the app (don't deploy yet)
fly launch --name my-supabase-pgbouncer --region iad --no-deploy
```

Choose your primary region based on:
- Where your primary Supabase project is located
- Where most of your users are

Common regions:
- `iad` - Ashburn, Virginia (US East)
- `sjc` - San Jose, California (US West)
- `lhr` - London, UK
- `nrt` - Tokyo, Japan
- `syd` - Sydney, Australia

## Step 3: Create Volume

PgBouncer needs a volume for its Unix socket:

```bash
fly volumes create pgbouncer_data --region iad --size 1
```

## Step 4: Configure Secrets

Set the database connection details:

```bash
fly secrets set \
    DATABASE_HOST=db.your-primary-ref.supabase.co \
    DATABASE_NAME=postgres \
    DATABASE_USER=postgres \
    DATABASE_PASSWORD='your-supabase-postgres-password' \
    PGBOUNCER_ADMIN_PASSWORD='choose-a-strong-admin-password'
```

**Important**: Use the **direct connection** host (port 5432), not the pooler (port 6543).

Find your connection details in the Supabase dashboard:
1. Go to Project Settings → Database
2. Use the "Direct connection" string
3. Extract the host: `db.xxxxx.supabase.co`

## Step 5: Deploy

```bash
fly deploy
```

Watch the deployment:

```bash
fly logs -f
```

Expected output:
```
=== PgBouncer Startup ===
Database host: db.xxxxx.supabase.co
Pool mode: transaction
Max client connections: 1000

Processing configuration templates...
Starting PgBouncer...
```

## Step 6: Verify Deployment

### Check Status

```bash
fly status
```

### Test Connection

```bash
# Get your app's hostname
fly status | grep Hostname

# Test with psql
psql "postgresql://postgres:your-password@my-supabase-pgbouncer.fly.dev:5432/postgres" \
    -c "SELECT current_database(), current_user;"
```

### Check PgBouncer Stats

```bash
fly ssh console -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"
```

## Step 7: Multi-Region Deployment (Optional)

For lower latency globally, deploy to multiple regions:

```bash
# Scale to 2 machines across regions
fly scale count 2 --region iad,sjc
```

Or add specific machines:

```bash
# Add machine in US West
fly machine clone --region sjc

# Add machine in Europe
fly machine clone --region lhr
```

Fly.io automatically routes traffic to the nearest healthy instance.

## Connection String for Applications

Update your application to use PgBouncer:

```
# Before (direct to Supabase)
postgresql://postgres:password@db.xxxxx.supabase.co:5432/postgres

# After (via PgBouncer)
postgresql://postgres:password@my-supabase-pgbouncer.fly.dev:5432/postgres
```

### Environment Variable Example

```bash
# .env
DATABASE_URL=postgresql://postgres:password@my-supabase-pgbouncer.fly.dev:5432/postgres
```

## Pool Mode Configuration

The default pool mode is `transaction`, which is recommended for Supabase.

### Transaction Mode (Default)

- Connection returned to pool after each transaction
- Best for most web applications
- Compatible with Supabase

### Session Mode

- Connection held for entire client session
- Use for applications that need session-level features (prepared statements, temp tables)
- Less efficient but more compatible

To change:

```bash
fly secrets set PGBOUNCER_POOL_MODE=session
```

## Tuning for Production

### Connection Limits

```bash
# High-traffic applications
fly secrets set \
    PGBOUNCER_MAX_CLIENT_CONN=2000 \
    PGBOUNCER_DEFAULT_POOL_SIZE=50

# Redeploy or reload
fly ssh console -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RELOAD;'"
```

### Resource Scaling

```bash
# Increase VM size
fly scale vm shared-cpu-2x --memory 1024
```

## Administration

### Connecting to Admin Console

```bash
# SSH into the container
fly ssh console

# Connect to PgBouncer admin
psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer
```

### Useful Admin Commands

```sql
-- Pool status
SHOW POOLS;

-- Active connections
SHOW CLIENTS;
SHOW SERVERS;

-- Statistics
SHOW STATS;

-- Pause all pools (for failover)
PAUSE;

-- Resume
RESUME;

-- Reload config
RELOAD;
```

## Failover Operations

See [Failover Runbook](../runbooks/failover-runbook.md) for complete procedure.

### Quick Reference

```bash
# 1. Pause connections
fly ssh console -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'PAUSE;'"

# 2. Swap upstream to standby
fly secrets set DATABASE_HOST=db.your-standby-ref.supabase.co

# 3. Reload config
fly ssh console -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RELOAD;'"

# 4. Resume connections
fly ssh console -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'RESUME;'"
```

## Monitoring

### Fly.io Dashboard

- View metrics at https://fly.io/apps/your-app-name
- CPU, memory, network usage
- Request counts

### Logs

```bash
# Stream logs
fly logs -f

# Last 100 lines
fly logs --limit 100
```

### Health Checks

Fly.io performs automatic TCP health checks on port 5432. Unhealthy machines are automatically removed from rotation.

## Troubleshooting

### Connection Refused

```bash
# Check app is running
fly status

# Check logs for errors
fly logs --limit 50

# Verify secrets
fly secrets list
```

### Pool Exhausted (cl_waiting high)

```bash
# Check pool status
fly ssh console -C "psql -h /var/run/pgbouncer -p 6432 -U pgbouncer pgbouncer -c 'SHOW POOLS;'"

# Increase pool size
fly secrets set PGBOUNCER_DEFAULT_POOL_SIZE=50
```

### Slow Connections

1. Check if PgBouncer is in same region as users
2. Verify Supabase is responding quickly
3. Check pool utilization (may need larger pool)

### Admin Connection Fails

```bash
# Reset admin password
fly secrets set PGBOUNCER_ADMIN_PASSWORD=new-strong-password
```

## Security Considerations

1. **Secrets**: All passwords stored as encrypted Fly.io secrets
2. **Admin port**: Only accessible via `fly ssh`, not exposed externally
3. **Network**: Consider Fly.io private networking for internal apps
4. **TLS**: Enable client TLS for production (uncomment in pgbouncer.ini.template)

## Cost Estimation

Fly.io pricing (as of 2024):
- Shared CPU 1x, 256MB: ~$1.94/month
- Shared CPU 1x, 512MB: ~$3.88/month
- Volume storage: $0.15/GB/month

Multi-region (2 instances): ~$8/month

## Next Steps

1. [Configure logical replication](logical-replication-setup.md)
2. [Review failover runbook](../runbooks/failover-runbook.md)
3. [Set up monitoring alerts](#monitoring)
