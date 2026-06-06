#!/bin/bash
# ========================================
# Vaultwarden -> Cloudflare R2 Restore Script
# ========================================
set -euo pipefail

# Settings
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTIC_OPTS=(-o s3.bucket-lookup=dns -o s3.region=auto)
DUMP_FILE="$PROJECT_DIR/vw-pgdb.dump"

# Environment: Loading variables to connect to Cloudflare R2 and DB
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
else
    echo "ERROR: Missing .env file at $PROJECT_DIR/.env" >&2; exit 1
fi

# Validate crucial Restic variables
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}" "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}"
# Validate PostgreSQL variables
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set in .env}"

echo ">>> Starting Vaultwarden Recovery Process..."

# ----------------------------------------------------
# Step 1: Restore Files Directly from Cloudflare R2
# ----------------------------------------------------
echo "[1/4] Restoring files (vw-data, compose.yaml, db dump) from R2..."
cd "$PROJECT_DIR"

# This restores the LATEST snapshot targeting this specific host definition
restic "${RESTIC_OPTS[@]}" restore latest \
    --host "anemone-pi-server" \
    --target "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------
# Step 2: Restart Containers
# ----------------------------------------------------
echo "[2/4] Starting Docker containers..."
# Ensure the infrastructure is pulled and running so we have a DB to restore into
docker compose pull
docker compose up -d

echo "Waiting 10 seconds for PostgreSQL to fully initialize..."
sleep 10

# ----------------------------------------------------
# Step 3: Restore PostgreSQL Database
# ----------------------------------------------------
echo "[3/4] Restoring PostgreSQL database from dump file..."

if [[ ! -f "$DUMP_FILE" ]]; then
    echo "ERROR: Restored dump file '$DUMP_FILE' not found!" >&2
    exit 1
fi

# Clean up existing public schema data to prevent unique constraint conflicts during overwrite
echo "-> Dropping and re-creating database schema to clean existing data..."
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" vault-db \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"

# Stream the restored dump file back into the container
echo "-> Executing pg_restore..."
docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" vault-db \
    pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c < "$DUMP_FILE"

# ----------------------------------------------------
# Step 4: Cleanup Local Dump & Restart App
# ----------------------------------------------------
echo "[4/4] Cleaning up local temporary files and finalizing..."
rm -f "$DUMP_FILE"

# Restart Vaultwarden to ensure it establishes fresh connections to the restored DB
echo "-> Restarting Vaultwarden app container..."
docker compose restart

echo ">>> Success! Vaultwarden has been completely restored to its latest state."
