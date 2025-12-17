# PgBouncer Docker image for Fly.io deployment
# Based on official edoburu/pgbouncer image

FROM edoburu/pgbouncer:1.22.1

# Install envsubst for template processing
USER root
RUN apk add --no-cache gettext

# Copy configuration templates
COPY pgbouncer.ini.template /etc/pgbouncer/pgbouncer.ini.template
COPY userlist.txt.template /etc/pgbouncer/userlist.txt.template

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create runtime directory
RUN mkdir -p /var/run/pgbouncer && \
    chown -R pgbouncer:pgbouncer /var/run/pgbouncer

# Switch back to pgbouncer user
USER pgbouncer

# Expose ports
# 5432: Client connections (PostgreSQL protocol)
# 6432: Admin connections (PgBouncer admin console)
EXPOSE 5432 6432

ENTRYPOINT ["/entrypoint.sh"]
