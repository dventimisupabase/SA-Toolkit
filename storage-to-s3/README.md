# Supabase Storage to S3 Migration

One-time migration tool to move objects from Supabase Storage to AWS S3.

## Quick Start

```bash
# 1. Link your Supabase project
supabase link --project-ref <your-project-ref>

# 2. Configure
cp config/env.example config/.env
# Edit config/.env with your settings

# 3. Preview (dry run)
./scripts/migrate.sh --dry-run

# 4. Migrate
./scripts/migrate.sh

# 5. Verify
./scripts/verify.sh
```

## Prerequisites

- Supabase CLI (linked to your project)
- AWS CLI v2 (configured with credentials)
- S3 bucket with write access

See [docs/prerequisites.md](docs/prerequisites.md) for detailed setup.

## Configuration

| Variable | Description |
|----------|-------------|
| `SUPABASE_BUCKETS` | Buckets to migrate: `"all"` or space-separated list |
| `AWS_S3_BUCKET` | Target S3 bucket name |
| `AWS_REGION` | S3 bucket region |
| `S3_PREFIX` | Optional prefix for all objects |
| `TEMP_DIR` | Local temp directory for downloads |
| `CLEANUP_TEMP` | Remove temp files after migration |
| `PARALLEL_JOBS` | Parallel download threads |

## Scripts

### migrate.sh

```bash
./scripts/migrate.sh [options]

Options:
  --dry-run       Preview without copying
  --bucket NAME   Migrate single bucket
  --help          Show help
```

### verify.sh

```bash
./scripts/verify.sh [options]

Options:
  --bucket NAME   Verify single bucket
  --help          Show help
```

## Architecture

```
Supabase Storage
       |
       | supabase storage cp --recursive
       v
  Local Temp Dir
       |
       | aws s3 sync
       v
    AWS S3
```

## Directory Structure

```
storage-to-s3/
├── README.md
├── config/
│   └── env.example
├── scripts/
│   ├── migrate.sh
│   └── verify.sh
└── docs/
    └── prerequisites.md
```
