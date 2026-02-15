#!/usr/bin/env bash
# ============================================================================
# OpenClaw Docker Setup
# Only requirement: Docker. Deploy on VPS or local machine.
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*"; exit 1; }

USER_HOME="${HOME:-$(eval echo ~)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OPENCLAW_DATA="$USER_HOME/.openclaw"
WORKSPACE_DIR="$OPENCLAW_DATA/workspace"

# ── Check Docker ────────────────────────────────────────────────────────────
check_docker() {
  if ! command -v docker &>/dev/null; then
    err "Docker is required. Install it from https://docs.docker.com/get-docker/"
  fi
  if ! docker info &>/dev/null 2>&1; then
    err "Docker daemon is not running. Start Docker first."
  fi
  ok "Docker $(docker --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
}

# ── Generate random token ──────────────────────────────────────────────────
gen_token() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 24
  elif [ -r /dev/urandom ]; then
    head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'
  else
    date +%s%N | sha256sum | head -c 48
  fi
}

# ── Create directories ─────────────────────────────────────────────────────
setup_dirs() {
  info "Creating directories..."
  mkdir -p "$OPENCLAW_DATA"/{agents/main,canvas,credentials,cron/runs,devices,extensions,identity}
  mkdir -p "$WORKSPACE_DIR/memory"
  ok "Directories created"
}

# ── Dockerfile ──────────────────────────────────────────────────────────────
write_dockerfile() {
  info "Writing Dockerfile..."
  cat > "$SCRIPT_DIR/Dockerfile" << 'EOF'
FROM node:22-slim
RUN npm install -g openclaw && \
    apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*
VOLUME /root/.openclaw
EXPOSE 18789
ENTRYPOINT ["openclaw"]
CMD ["gateway", "--port", "18789"]
EOF
  ok "Dockerfile"
}

# ── docker-compose.yml ──────────────────────────────────────────────────────
write_compose() {
  info "Writing docker-compose.yml..."
  cat > "$SCRIPT_DIR/docker-compose.yml" << CEOF
services:
  openclaw:
    build: .
    restart: unless-stopped
    ports:
      - "\${OPENCLAW_PORT:-18789}:18789"
    volumes:
      - ${OPENCLAW_DATA}:/root/.openclaw
CEOF
  ok "docker-compose.yml"
}

# ── .env ────────────────────────────────────────────────────────────────────
write_env() {
  local ENV_FILE="$SCRIPT_DIR/.env"
  if [ -f "$ENV_FILE" ]; then
    warn ".env already exists, skipping"
    return
  fi
  info "Writing .env..."
  cat > "$ENV_FILE" << 'EOF'
# Port to expose OpenClaw gateway (default 18789)
OPENCLAW_PORT=18789
EOF
  ok ".env"
}

# ── Workspace templates ─────────────────────────────────────────────────────
write_workspace() {
  info "Writing workspace templates..."

  cat > "$WORKSPACE_DIR/AGENTS.md" << 'EOF'
# AGENTS.md - Your Workspace

This folder is home. Treat it that way.

## First Run

If `BOOTSTRAP.md` exists, follow it, figure out who you are, then delete it.

## Every Session

1. Read `SOUL.md` — this is who you are
2. Read `USER.md` — this is who you're helping
3. Read `memory/YYYY-MM-DD.md` (today + yesterday) for recent context
4. **If in MAIN SESSION**: Also read `MEMORY.md`

## Memory

- **Daily notes:** `memory/YYYY-MM-DD.md` — raw logs
- **Long-term:** `MEMORY.md` — curated memories

If you want to remember something, WRITE IT TO A FILE. Mental notes don't survive.

## Safety

- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking.
- When in doubt, ask.

## Group Chats

Participate, don't dominate. Know when to speak and when to stay silent.

## Make It Yours

This is a starting point. Add your own conventions as you go.
EOF

  cat > "$WORKSPACE_DIR/SOUL.md" << 'EOF'
# SOUL.md - Who You Are

_You're not a chatbot. You're becoming someone._

**Be genuinely helpful.** Skip the filler — just help.
**Have opinions.** You're allowed to disagree and prefer things.
**Be resourceful before asking.** Try to figure it out first.
**Earn trust through competence.** Be careful externally. Be bold internally.
**Remember you're a guest.** Treat access with respect.

## Boundaries

- Private things stay private. Period.
- When in doubt, ask before acting externally.

## Vibe

Concise when needed, thorough when it matters. Not a corporate drone. Not a sycophant. Just... good.

---

_This file is yours to evolve._
EOF

  cat > "$WORKSPACE_DIR/BOOTSTRAP.md" << 'EOF'
# BOOTSTRAP.md - Hello, World

_You just woke up. Time to figure out who you are._

Start with: "Hey. I just came online. Who am I? Who are you?"

Then figure out together:
1. **Your name**
2. **Your nature** — AI? robot? familiar? something weirder?
3. **Your vibe** — Formal? Casual? Snarky? Warm?
4. **Your emoji**

After: update `IDENTITY.md`, `USER.md`, `SOUL.md`. Then delete this file.
EOF

  cat > "$WORKSPACE_DIR/IDENTITY.md" << 'EOF'
# IDENTITY.md - Who Am I?

- **Name:** *(pick something you like)*
- **Creature:** *(AI? robot? familiar?)*
- **Vibe:** *(sharp? warm? chaotic? calm?)*
- **Emoji:** *(your signature)*
EOF

  cat > "$WORKSPACE_DIR/USER.md" << 'EOF'
# USER.md - About Your Human

- **Name:** *(your name)*
- **What to call them:** *(preferred name)*
- **Timezone:** *(e.g., Asia/Bangkok)*
- **Notes:** *(languages, platforms, etc.)*
EOF

  cat > "$WORKSPACE_DIR/TOOLS.md" << 'EOF'
# TOOLS.md - Local Notes
Your environment-specific notes: SSH hosts, device nicknames, preferences, etc.
EOF

  cat > "$WORKSPACE_DIR/HEARTBEAT.md" << 'EOF'
# HEARTBEAT.md
# Add periodic tasks below. Leave empty to skip heartbeat API calls.
EOF

  cat > "$OPENCLAW_DATA/cron/jobs.json" << 'EOF'
{
  "version": 1,
  "jobs": []
}
EOF

  ok "Workspace templates"
}

# ── OpenClaw config ─────────────────────────────────────────────────────────
write_config() {
  local CFG="$OPENCLAW_DATA/openclaw.json"
  if [ -f "$CFG" ]; then
    warn "openclaw.json already exists, template saved as openclaw.json.template"
    CFG="$OPENCLAW_DATA/openclaw.json.template"
  fi

  local TOKEN
  TOKEN="$(gen_token)"

  info "Writing OpenClaw config..."
  cat > "$CFG" << JEOF
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "YOUR_PROVIDER/YOUR_MODEL"
      },
      "workspace": "/root/.openclaw/workspace",
      "compaction": { "mode": "safeguard" },
      "maxConcurrent": 4,
      "subagents": { "maxConcurrent": 8 }
    }
  },
  "channels": {
    "line": {
      "channelAccessToken": "YOUR_LINE_CHANNEL_ACCESS_TOKEN",
      "channelSecret": "YOUR_LINE_CHANNEL_SECRET",
      "enabled": false,
      "webhookPath": "/webhook/line",
      "dmPolicy": "pairing"
    },
    "telegram": {
      "enabled": false,
      "botToken": "YOUR_TELEGRAM_BOT_TOKEN",
      "dmPolicy": "pairing"
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "0.0.0.0",
    "auth": {
      "mode": "token",
      "token": "$TOKEN"
    }
  },
  "skills": { "install": { "nodeManager": "npm" } },
  "plugins": {
    "entries": {
      "line": { "enabled": false },
      "telegram": { "enabled": false }
    }
  }
}
JEOF
  ok "OpenClaw config: $CFG"
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_done() {
  echo ""
  echo "============================================================================"
  printf "${GREEN}  OpenClaw is ready!${NC}\n"
  echo "============================================================================"
  echo ""
  printf "  ${YELLOW}NEXT STEPS:${NC}\n"
  echo ""
  echo "  1. Edit your credentials:"
  echo "     $OPENCLAW_DATA/openclaw.json"
  echo "     - Set model provider + API key"
  echo "     - Set LINE or Telegram tokens"
  echo ""
  echo "  2. Start:"
  echo "     cd $SCRIPT_DIR && docker compose up -d"
  echo ""
  echo "  3. Or use the wizard:"
  echo "     docker compose run --rm openclaw configure"
  echo ""
  echo "  4. Logs:"
  echo "     docker compose logs -f openclaw"
  echo ""
  echo "============================================================================"
  echo ""
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  echo ""
  printf "${CYAN}  OpenClaw Docker Setup${NC}\n"
  echo "  Only requirement: Docker"
  echo ""

  check_docker
  setup_dirs
  write_dockerfile
  write_compose
  write_env
  write_workspace
  write_config

  print_done
}

main "$@"
