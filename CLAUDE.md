# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Solutions Architect Toolkit - a collection of tools, scripts, and programs useful for Solutions Architects supporting PostgreSQL database products.

## Design Principles

- **Read-only database access**: Tools should collect diagnostics without writing to customer databases
- **Standard libpq authentication**: Use `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD` environment variables or `.pgpass`
- **Auto-detection over manual config**: Prefer querying the database for configuration (e.g., PG version) rather than requiring user input
- **Local state storage**: Store telemetry/state files locally in `.telemetry/` directory, not in the database

## Tools

### batch_telemetry.sh

A client-side batch telemetry script for PostgreSQL 15, 16, or 17 that collects database performance metrics without writing to the database. Uses standard libpq environment variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD`) or `.pgpass` for authentication.

**Requirements:** bash, psql, jq

**Usage:**
```bash
./batch_telemetry.sh start  batch_1 "10M row import" | tee batch_1.log
./batch_telemetry.sh sample batch_1                 | tee -a batch_1.log
./batch_telemetry.sh end    batch_1                 | tee -a batch_1.log
./batch_telemetry.sh report batch_1

# With table tracking:
./batch_telemetry.sh --table orders start batch_1 "import"
```

PostgreSQL version is auto-detected from the connected database.

**Commands:**
- `start` - Begin tracking, capture initial state (settings, WAL, bgwriter/checkpointer stats, replication slots, pg_stat_io)
- `sample` - Capture point-in-time snapshot (wait events, active sessions, vacuum progress, COPY progress, I/O by backend)
- `end` - Finalize tracking, capture end state
- `report` - Generate summary report with deltas and interpretation guide

**Options:**
- `--table <name>` - Track table-specific stats (size, tuple counts, autovacuum activity)

**State files:** Stored in `.telemetry/<batch_id>.json`

**PG version differences:**
- PG 15: Uses `pg_stat_bgwriter` for all checkpoint stats, no `pg_stat_io`
- PG 16: Uses `pg_stat_bgwriter` for checkpoint stats, `pg_stat_io` available
- PG 17: Checkpoint stats split into `pg_stat_checkpointer`, `pg_stat_io` available

**Testing:**
```bash
# Verify syntax
bash -n batch_telemetry.sh

# Test against a database (requires PG* env vars or .pgpass)
./batch_telemetry.sh start test_batch "test run"
./batch_telemetry.sh sample test_batch
./batch_telemetry.sh end test_batch
./batch_telemetry.sh report test_batch

# Clean up
rm .telemetry/test_batch.json
```
