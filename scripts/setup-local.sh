#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# Fintech microservices — local setup (no Docker)
# Run once. Re-running is safe (idempotent).
# ─────────────────────────────────────────────

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

step()  { echo -e "\n${CYAN}▶ $1${NC}"; }
ok()    { echo -e "${GREEN}✔ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $1${NC}"; }
die()   { echo -e "${RED}✖ $1${NC}"; exit 1; }

# ─── 1. Dependency checks ────────────────────

step "Checking dependencies"

check_cmd() {
  if command -v "$1" &>/dev/null; then
    ok "$1 found ($(command -v "$1"))"
  else
    die "$1 not found — $2"
  fi
}

check_cmd node   "install from https://nodejs.org (need v20+)"
check_cmd psql   "install postgres: sudo apt install postgresql  |  brew install postgresql@16"
check_cmd pg_isready "should come with postgresql"
check_cmd rabbitmq-server "install: sudo apt install rabbitmq-server  |  brew install rabbitmq"

NODE_VERSION=$(node -e "process.stdout.write(process.versions.node.split('.')[0])")
if [[ "$NODE_VERSION" -lt 20 ]]; then
  die "Node 20+ required, found v$(node --version)"
fi
ok "Node v$(node --version)"

# ─── 2. Check Postgres is running ────────────

step "Checking Postgres"

if pg_isready -q; then
  ok "Postgres is running"
else
  warn "Postgres is not running — attempting to start..."
  # Try common start commands; if none work, give clear instructions.
  if command -v pg_ctlcluster &>/dev/null; then
    PG_VERSION=$(pg_lsclusters -h | awk 'NR==1{print $1}')
    sudo pg_ctlcluster "$PG_VERSION" main start || die "Could not start Postgres. Run: sudo service postgresql start"
  elif command -v brew &>/dev/null; then
    brew services start postgresql@16 || brew services start postgresql || die "Could not start Postgres via brew."
  else
    die "Could not start Postgres automatically.\nRun:  sudo service postgresql start\nthen re-run this script."
  fi
  sleep 2
  pg_isready -q || die "Postgres still not reachable."
  ok "Postgres started"
fi

# ─── 3. Check RabbitMQ is running ────────────

step "Checking RabbitMQ"

if pgrep -x "beam.smp" &>/dev/null || pgrep -f "rabbitmq" &>/dev/null; then
  ok "RabbitMQ appears to be running"
else
  warn "RabbitMQ not detected — attempting to start..."
  if command -v brew &>/dev/null; then
    brew services start rabbitmq || true
  else
    sudo systemctl start rabbitmq-server 2>/dev/null || sudo service rabbitmq-server start 2>/dev/null || true
  fi
  sleep 3
  if pgrep -x "beam.smp" &>/dev/null || pgrep -f "rabbitmq" &>/dev/null; then
    ok "RabbitMQ started"
  else
    warn "Could not confirm RabbitMQ is running."
    warn "If the next steps fail, run:  sudo service rabbitmq-server start"
    warn "Then re-run this script."
  fi
fi

# ─── 4. Create databases ─────────────────────

step "Creating Postgres databases"

# Detect the OS postgres superuser (postgres on Linux, current user on macOS/brew)
if id "postgres" &>/dev/null; then
  PSQL="sudo -u postgres psql"
else
  PSQL="psql"
fi

create_db() {
  local DB=$1 USER=$2 PASS=$3
  # Create role if it doesn't exist
  $PSQL -c "DO \$\$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$USER') THEN
      CREATE ROLE $USER WITH LOGIN PASSWORD '$PASS';
    END IF;
  END \$\$;" &>/dev/null
  # Create database if it doesn't exist
  $PSQL -tc "SELECT 1 FROM pg_database WHERE datname='$DB'" | grep -q 1 \
    || $PSQL -c "CREATE DATABASE $DB OWNER $USER;" &>/dev/null
  ok "Database '$DB' ready (owner: $USER)"
}

create_db auth     appuser secret
create_db payments appuser secret
create_db wallet   appuser secret

# ─── 5. Run migrations ───────────────────────

step "Running migrations"

run_migration() {
  local DB=$1 FILE=$2
  PGPASSWORD=secret psql -U appuser -d "$DB" -h 127.0.0.1 -f "$FILE" -q \
    && ok "Migration applied: $DB ← $(basename "$FILE")" \
    || die "Migration failed: $DB ← $FILE"
}

run_migration auth     "$ROOT/services/auth-service/migrations/001_init.sql"
run_migration payments "$ROOT/services/payments-service/migrations/001_init.sql"
run_migration wallet   "$ROOT/services/wallet-service/migrations/001_init.sql"

# ─── 6. Write .env files ─────────────────────

step "Writing .env files"

write_env() {
  local FILE=$1; shift
  # Never overwrite a .env that already has user edits — only write if absent
  if [[ -f "$FILE" ]]; then
    warn ".env already exists at $FILE — skipping (delete it to regenerate)"
    return
  fi
  printf '%s\n' "$@" > "$FILE"
  ok "Wrote $FILE"
}

write_env "$ROOT/services/auth-service/.env" \
  "DATABASE_URL=postgresql://appuser:secret@127.0.0.1:5432/auth" \
  "JWT_SECRET=local-dev-secret-change-before-prod" \
  "PORT=4001"

write_env "$ROOT/services/payments-service/.env" \
  "DATABASE_URL=postgresql://appuser:secret@127.0.0.1:5432/payments" \
  "RABBITMQ_URL=amqp://127.0.0.1:5672" \
  "PORT=4002"

write_env "$ROOT/services/wallet-service/.env" \
  "DATABASE_URL=postgresql://appuser:secret@127.0.0.1:5432/wallet" \
  "RABBITMQ_URL=amqp://127.0.0.1:5672" \
  "PORT=4003"

write_env "$ROOT/services/api-gateway/.env" \
  "AUTH_URL=http://127.0.0.1:4001" \
  "PAYMENTS_URL=http://127.0.0.1:4002" \
  "WALLET_URL=http://127.0.0.1:4003" \
  "JWT_SECRET=local-dev-secret-change-before-prod" \
  "PORT=4000"

# ─── 7. Install npm dependencies ─────────────

step "Installing npm dependencies"

for svc in auth-service payments-service wallet-service api-gateway; do
  DIR="$ROOT/services/$svc"
  if [[ -d "$DIR/node_modules" ]]; then
    ok "$svc — already installed, skipping"
  else
    echo "  npm install → $svc"
    npm install --prefix "$DIR" --no-audit --no-fund --silent \
      && ok "$svc — installed"
  fi
done

# ─── 8. Done ─────────────────────────────────

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup complete. Now run:${NC}"
echo -e "${GREEN}  bash scripts/start-local.sh${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
