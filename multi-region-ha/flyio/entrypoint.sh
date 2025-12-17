#!/bin/sh
# PgBouncer entrypoint script
# Substitutes environment variables into configuration templates

set -e

CONFIG_DIR="/etc/pgbouncer"
TEMPLATE_SUFFIX=".template"

echo "=== PgBouncer Startup ==="
echo "Database host: ${DATABASE_HOST}"
echo "Pool mode: ${PGBOUNCER_POOL_MODE}"
echo "Max client connections: ${PGBOUNCER_MAX_CLIENT_CONN}"
echo ""

# Validate required environment variables
check_required_var() {
    eval value=\$$1
    if [ -z "$value" ]; then
        echo "ERROR: Required environment variable $1 is not set"
        exit 1
    fi
}

check_required_var "DATABASE_HOST"
check_required_var "DATABASE_NAME"
check_required_var "DATABASE_USER"
check_required_var "DATABASE_PASSWORD"
check_required_var "PGBOUNCER_ADMIN_PASSWORD"

# Process configuration templates
echo "Processing configuration templates..."

for template in ${CONFIG_DIR}/*${TEMPLATE_SUFFIX}; do
    if [ -f "$template" ]; then
        output="${template%${TEMPLATE_SUFFIX}}"
        echo "  ${template} -> ${output}"
        envsubst < "$template" > "$output"
    fi
done

# Set correct permissions
chmod 600 ${CONFIG_DIR}/userlist.txt
chmod 644 ${CONFIG_DIR}/pgbouncer.ini

echo ""
echo "Starting PgBouncer..."
echo "  Client port: 5432"
echo "  Admin port: 6432"
echo ""

# Start PgBouncer
exec pgbouncer /etc/pgbouncer/pgbouncer.ini
