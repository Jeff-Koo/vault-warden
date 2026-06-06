#!/bin/bash
# ========================================
# Vaultwarden -> Cloudflare R2 Backup Script
# ========================================

# Ensure cron can locate docker, docker-compose, and restic binaries
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

set -euo pipefail

### Settings
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
### Cloudflare R2 requires the region to be explicitly set to 'auto' or 'us-east-1'
RESTIC_OPTS=(-o s3.bucket-lookup=dns -o s3.region=auto)
DUMP_FILE="$PROJECT_DIR/vw-pgdb.dump"

### Cleanup: Ensure the dump file is removed on exit
trap 'rm -f "$DUMP_FILE" 2>/dev/null' EXIT INT TERM

### Environment: Loading variables and validating required fields
if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
else
    echo "ERROR: Missing .env file at $PROJECT_DIR/.env" >&2; exit 1
fi

### Validate crucial Restic variables
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}" "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}"
### Validate PostgreSQL variables
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is not set in .env}"

echo ">>> Start Cloudflare R2 backup task..."

### Check and initialize repository if it doesn't exist in R2 yet
if ! restic "${RESTIC_OPTS[@]}" snapshots > /dev/null 2>&1; then
    echo "Initializing remote R2 repository..."
    restic "${RESTIC_OPTS[@]}" init
fi

### Database backup
echo "[1/5] Dumping database..."
### Pass password via container env to ensure zero interactive prompting
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" vault-db \
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -F c > "$DUMP_FILE"

### Verify the dump file actually contains data and isn't a 0-byte failure
if [[ ! -s "$DUMP_FILE" ]]; then
    echo "ERROR: Database dump is empty or failed!" >&2
    exit 1
fi

### Execute Restic incremental backup
echo "[2/5] Uploading to Cloudflare R2..."
restic "${RESTIC_OPTS[@]}" unlock 2>/dev/null || true

cd "$PROJECT_DIR"

### Capture exit code: Code 3 means "some files changed during read" (normal for a live /vw-data directory)
set +e
restic "${RESTIC_OPTS[@]}" backup \
    "./vw-pgdb.dump" \
    "./vw-data" \
    "./compose.yaml" \
    --tag "portable_auto" \
    --host "anemone-pi-server" ### optional, but recommended to label the snapshot
RESTIC_RC=$?
set -e

### Handle exit status codes gracefully
if [[ $RESTIC_RC -ne 0 && $RESTIC_RC -ne 3 ]]; then
    echo "ERROR: Restic backup failed with exit code $RESTIC_RC" >&2
    exit $RESTIC_RC
fi

### Automatic cleanup of expired snapshots
echo "[3/5] Running retention (7D, 4W, 6M)..."
restic "${RESTIC_OPTS[@]}" forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune --quiet

### Periodic health check
echo "[4/5] Verifying repository integrity..."
restic "${RESTIC_OPTS[@]}" check --read-data-subset=10% --quiet

echo "[5/5] Done! Backup successfully synced to Cloudflare R2."
