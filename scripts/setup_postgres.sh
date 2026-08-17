#!/usr/bin/env bash
# Configure PostgreSQL for MedLock. Never silent-sudo.
# Order: existing server -> docker compose -> print apt instructions.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

PROJECT_DIR="${PROJECT_DIR:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SCHEMA="${PROJECT_DIR}/db/schema.sql"
COMPOSE="${PROJECT_DIR}/db/docker-compose.yml"

POSTGRES_USER="${POSTGRES_USER:-medlock}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_DB="${POSTGRES_DB:-medlock}"
POSTGRES_HOST="${POSTGRES_HOST:-127.0.0.1}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"

require_file "$SCHEMA"

apply_schema() {
  local url="$1"
  if have_cmd psql; then
    PGPASSWORD="${POSTGRES_PASSWORD}" psql "$url" -v ON_ERROR_STOP=1 -f "$SCHEMA"
    return 0
  fi
  if have_cmd python3; then
    python3 - "$url" "$SCHEMA" <<'PY'
import sys
from pathlib import Path
url, schema = sys.argv[1], Path(sys.argv[2]).read_text()
# SQLAlchemy URL -> libpq
dsn = url.replace("postgresql+psycopg://", "postgresql://").replace("postgresql+psycopg2://", "postgresql://")
try:
    import psycopg
except ImportError:
    sys.exit("psycopg not installed in this Python")
# schema uses CREATE EXTENSION vector which may fail; apply in pieces
with psycopg.connect(dsn, autocommit=True) as conn:
    cur = conn.cursor()
    for stmt in schema.split(";"):
        s = stmt.strip()
        if not s:
            continue
        try:
            cur.execute(s)
        except Exception as exc:
            if "extension" in s.lower() and "vector" in s.lower():
                print(f"WARN: pgvector not available ({exc}); RAG ANN index disabled", file=sys.stderr)
                continue
            raise
print("schema applied")
PY
    return 0
  fi
  die "Need psql or Python psycopg to apply db/schema.sql"
}

pg_ready() {
  local dsn="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  if have_cmd pg_isready; then
    pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1
    return $?
  fi
  if have_cmd python3; then
    python3 - "$dsn" <<'PY' 2>/dev/null
import sys
dsn = sys.argv[1]
try:
    import psycopg
    with psycopg.connect(dsn, connect_timeout=3) as c:
        c.execute("SELECT 1")
except Exception:
    sys.exit(1)
PY
    return $?
  fi
  return 1
}

log_step "PostgreSQL"

if [[ -z "$POSTGRES_PASSWORD" ]]; then
  die "POSTGRES_PASSWORD is empty. Re-run install.sh so .env is generated."
fi

if pg_ready; then
  log_ok "PostgreSQL already reachable at ${POSTGRES_HOST}:${POSTGRES_PORT}"
  apply_schema "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
  exit 0
fi

if have_cmd docker && [[ -f "$COMPOSE" ]]; then
  log_info "Starting Postgres via Docker Compose (loopback only)"
  if [[ "${MEDLOCK_OFFLINE:-0}" == "1" ]]; then
    if ! docker image inspect pgvector/pgvector:pg16 >/dev/null 2>&1; then
      die "--offline: pgvector/pgvector:pg16 image is not cached. Load it first or use a local Postgres."
    fi
  fi
  docker compose --env-file "${PROJECT_DIR}/.env" -f "$COMPOSE" up -d
  for _ in $(seq 1 30); do
    if pg_ready; then
      log_ok "Docker Postgres is ready"
      apply_schema "postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}"
      exit 0
    fi
    sleep 2
  done
  die "Docker Postgres did not become ready. Check: docker compose -f ${COMPOSE} logs"
fi

log_warn "No reachable Postgres and Docker is not available."
cat <<EOF
Install PostgreSQL locally (this needs sudo — not run automatically):

  sudo apt-get update
  sudo apt-get install -y postgresql postgresql-contrib
  # Optional pgvector:
  sudo apt-get install -y postgresql-16-pgvector || sudo apt-get install -y postgresql-14-pgvector

Then as postgres superuser:

  sudo -u postgres psql -c "CREATE USER ${POSTGRES_USER} WITH PASSWORD 'YOUR_PASSWORD';"
  sudo -u postgres psql -c "CREATE DATABASE ${POSTGRES_DB} OWNER ${POSTGRES_USER};"
  sudo -u postgres psql -d ${POSTGRES_DB} -c "CREATE EXTENSION IF NOT EXISTS vector;"
  sudo -u postgres psql -d ${POSTGRES_DB} -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

  PGPASSWORD=YOUR_PASSWORD psql -h 127.0.0.1 -U ${POSTGRES_USER} -d ${POSTGRES_DB} -f ${SCHEMA}

Re-run: ./install.sh --repair
EOF

if [[ "${MEDLOCK_NONINTERACTIVE:-0}" == "1" ]]; then
  die "PostgreSQL is required and was not available in non-interactive mode."
fi

exit 2
