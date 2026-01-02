#!/bin/bash
set -euo pipefail

# Minimal PostgreSQL startup script with full paths
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

# Platform readiness expects the DB container to respond on PORT (commonly 5001)
# using HEALTHCHECK_PATH (commonly /healthz). We satisfy this by running the
# db_visualizer HTTP server on PORT, while Postgres continues running on DB_PORT.
CONTAINER_PORT="${PORT:-5001}"
HEALTHCHECK_PATH="${HEALTHCHECK_PATH:-/healthz}"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION="$(ls /usr/lib/postgresql/ | head -1)"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
echo "Found PostgreSQL version: ${PG_VERSION}"

start_db_visualizer() {
  # Start DB viewer on container readiness port (PORT), not on 3000, to satisfy probe.
  # Bind to 0.0.0.0 to be reachable from outside container network namespace.
  if [ ! -d "db_visualizer" ]; then
    echo "db_visualizer directory not found; skipping viewer startup"
    return 0
  fi

  echo "Starting db_visualizer on 0.0.0.0:${CONTAINER_PORT} (health: ${HEALTHCHECK_PATH}) ..."
  (
    cd db_visualizer

    export HOST="0.0.0.0"
    export DB_VIEWER_PORT="${CONTAINER_PORT}"
    export HEALTHCHECK_PATH="${HEALTHCHECK_PATH}"

    # The canonical connection string is written into ../db_connection.txt.
    # We propagate it for the viewer as POSTGRES_URL.
    if [ -f "../db_connection.txt" ]; then
      POSTGRES_URL_EXTRACTED="$(sed -E 's/^psql[[:space:]]+//' ../db_connection.txt | tr -d '\r\n')"
      export POSTGRES_URL="${POSTGRES_URL_EXTRACTED}"
    else
      # Fallback (should rarely happen): construct URL from known values.
      export POSTGRES_URL="postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}"
    fi

    export POSTGRES_USER="${DB_USER}"
    export POSTGRES_PASSWORD="${DB_PASSWORD}"
    export POSTGRES_DB="${DB_NAME}"
    export POSTGRES_PORT="${DB_PORT}"

    # Run via npm so local dependencies are used.
    npm start >/tmp/db_visualizer.log 2>&1 &
    echo $! > /tmp/db_visualizer.pid
  ) || true
}

wait_for_health() {
  local tries=30
  local i=1

  while [ $i -le $tries ]; do
    if curl -fsS "http://127.0.0.1:${CONTAINER_PORT}${HEALTHCHECK_PATH}" >/dev/null 2>&1; then
      echo "Readiness endpoint is responding on ${CONTAINER_PORT}${HEALTHCHECK_PATH}"
      return 0
    fi
    echo "Waiting for readiness endpoint... (${i}/${tries})"
    sleep 1
    i=$((i + 1))
  done

  echo "WARNING: readiness endpoint did not become available on ${CONTAINER_PORT}${HEALTHCHECK_PATH}"
  if [ -f /tmp/db_visualizer.log ]; then
    echo "---- db_visualizer last 200 lines ----"
    tail -n 200 /tmp/db_visualizer.log || true
    echo "-------------------------------------"
  fi
  return 1
}

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
  echo "Initializing PostgreSQL..."
  sudo -u postgres "${PG_BIN}/initdb" -D /var/lib/postgresql/data
fi

# Start PostgreSQL server in background if not already running
if sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" > /dev/null 2>&1; then
  echo "PostgreSQL is already running on port ${DB_PORT}!"
else
  echo "Starting PostgreSQL server..."
  sudo -u postgres "${PG_BIN}/postgres" -D /var/lib/postgresql/data -p "${DB_PORT}" &
fi

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
for i in {1..15}; do
  if sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" > /dev/null 2>&1; then
    echo "PostgreSQL is ready!"
    break
  fi
  echo "Waiting... ($i/15)"
  sleep 2
done

# Create database and user (idempotent)
echo "Setting up database and user..."
sudo -u postgres "${PG_BIN}/createdb" -p "${DB_PORT}" "${DB_NAME}" 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\c ${DB_NAME}

GRANT USAGE ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Save connection command to a file (source of truth)
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file for the viewer (convenience)
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""
echo "To connect to the database:"
echo "$(cat db_connection.txt)"

# Start viewer on readiness port and wait briefly for health endpoint
start_db_visualizer
wait_for_health || true

# Keep script alive if it's PID 1 so background services don't exit.
wait
