#!/usr/bin/env bash
# ============================================================================
# OpenClaw Docker Setup
# Only requirement: Docker. Works on Linux / macOS / Windows (WSL).
# Creates Dockerfile + docker-compose + workspace templates, then starts it.
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${NC}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*"; exit 1; }

USER_HOME="${HOME:-$(eval echo ~)}"
SETUP_DIR="$USER_HOME/openclaw-setup"
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
  ok "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+')"
}

# ── Generate random token ──────────────────────────────────────────────────
gen_token() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 24
  else
    head -c 24 /dev/urandom | xxd -p 2>/dev/null || cat /proc/sys/kernel/random/uuid | tr -d '-'
  fi
}

# ── Create project directory ────────────────────────────────────────────────
setup_dirs() {
  info "Creating project structure..."
  mkdir -p "$SETUP_DIR"
  mkdir -p "$OPENCLAW_DATA"/{agents/main,canvas,credentials,cron/runs,devices,extensions,identity}
  mkdir -p "$WORKSPACE_DIR/memory"
  mkdir -p "$SETUP_DIR/traefik-config"
  ok "Directories created"
}

# ── Dockerfile ──────────────────────────────────────────────────────────────
write_dockerfile() {
  info "Writing Dockerfile..."
  cat > "$SETUP_DIR/Dockerfile" << 'DEOF'
FROM node:22-slim

RUN npm install -g openclaw && \
    apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

VOLUME /root/.openclaw
EXPOSE 18789

ENTRYPOINT ["openclaw"]
CMD ["gateway", "--port", "18789"]
DEOF
  ok "Dockerfile"
}

# ── docker-compose.yml ──────────────────────────────────────────────────────
write_compose() {
  info "Writing docker-compose.yml..."
  cat > "$SETUP_DIR/docker-compose.yml" << 'CEOF'
services:
  # ── Traefik (reverse proxy + auto SSL) ──
  traefik:
    image: traefik:latest
    restart: always
    command:
      - "--api=true"
      - "--api.insecure=true"
      - "--providers.docker=true"
      - "--providers.docker.exposedbydefault=false"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
      - "--entrypoints.web.http.redirections.entryPoint.to=websecure"
      - "--entrypoints.web.http.redirections.entryPoint.scheme=https"
      - "--entrypoints.websecure.address=:443"
      - "--certificatesresolvers.mytlschallenge.acme.tlschallenge=true"
      - "--certificatesresolvers.mytlschallenge.acme.email=${SSL_EMAIL:-admin@localhost}"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - traefik_data:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik-config:/etc/traefik/dynamic:ro

  # ── n8n (workflow automation) ──
  n8n:
    image: docker.n8n.io/n8nio/n8n
    restart: always
    ports:
      - "127.0.0.1:5678:5678"
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${N8N_SUBDOMAIN:-n8n}.${DOMAIN_NAME:-localhost}`)
      - traefik.http.routers.n8n.tls=true
      - traefik.http.routers.n8n.entrypoints=web,websecure
      - traefik.http.routers.n8n.tls.certresolver=mytlschallenge
    environment:
      - N8N_HOST=${N8N_SUBDOMAIN:-n8n}.${DOMAIN_NAME:-localhost}
      - N8N_PORT=5678
      - N8N_PROTOCOL=https
      - NODE_ENV=production
      - WEBHOOK_URL=https://${N8N_SUBDOMAIN:-n8n}.${DOMAIN_NAME:-localhost}/
      - GENERIC_TIMEZONE=${TZ:-UTC}
      - N8N_PROXY_HOPS=1
    volumes:
      - n8n_data:/home/node/.n8n

  # ── OpenClaw (AI gateway + LINE/Telegram) ──
  openclaw:
    build: .
    restart: always
    labels:
      - traefik.enable=true
      - traefik.http.routers.openclaw.rule=Host(`${OPENCLAW_SUBDOMAIN:-openclaw}.${DOMAIN_NAME:-localhost}`)
      - traefik.http.routers.openclaw.tls=true
      - traefik.http.routers.openclaw.entrypoints=web,websecure
      - traefik.http.routers.openclaw.tls.certresolver=mytlschallenge
      - traefik.http.services.openclaw.loadbalancer.server.port=18789
    volumes:
      - ${OPENCLAW_DATA:-~/.openclaw}:/root/.openclaw
    ports:
      - "127.0.0.1:18789:18789"

volumes:
  traefik_data:
  n8n_data:
CEOF
  ok "docker-compose.yml"
}

# ── .env template ───────────────────────────────────────────────────────────
write_env() {
  local ENV_FILE="$SETUP_DIR/.env"
  if [ -f "$ENV_FILE" ]; then
    warn ".env already exists, skipping"
    return
  fi

  info "Writing .env..."
  cat > "$ENV_FILE" << EOF
# ── Domain ──
DOMAIN_NAME=your.domain.com
N8N_SUBDOMAIN=n8n
OPENCLAW_SUBDOMAIN=openclaw
SSL_EMAIL=you@example.com
TZ=UTC

# ── OpenClaw data path ──
OPENCLAW_DATA=$OPENCLAW_DATA
EOF
  ok ".env template"
}

# ── Traefik dynamic route for OpenClaw ──────────────────────────────────────
write_traefik_config() {
  info "Writing Traefik dynamic config..."

  # When using docker provider with labels, this file is optional.
  # Kept as fallback for non-docker setups.
  cat > "$SETUP_DIR/traefik-config/openclaw.yml" << 'TEOF'
# This file is a fallback. Docker labels in docker-compose.yml handle routing.
# Uncomment below if you run OpenClaw outside Docker and need Traefik to proxy.
#
# http:
#   routers:
#     openclaw:
#       rule: "Host(`openclaw.YOUR_DOMAIN`)"
#       service: openclaw
#       entrypoints:
#         - websecure
#       tls:
#         certResolver: mytlschallenge
#   services:
#     openclaw:
#       loadBalancer:
#         servers:
#           - url: "http://host.docker.internal:18789"
TEOF
  ok "Traefik config"
}

# ── Workspace template files ────────────────────────────────────────────────
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

  # Cron template
  cat > "$OPENCLAW_DATA/cron/jobs.json" << 'EOF'
{
  "version": 1,
  "jobs": []
}
EOF

  ok "Workspace templates"
}

# ── OpenClaw config template ───────────────────────────────────────────────
write_openclaw_config() {
  local CFG="$OPENCLAW_DATA/openclaw.json"
  if [ -f "$CFG" ]; then
    warn "openclaw.json already exists, saving template as openclaw.json.template"
    CFG="$OPENCLAW_DATA/openclaw.json.template"
  fi

  info "Writing OpenClaw config template..."
  cat > "$CFG" << JEOF
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "YOUR_PROVIDER/YOUR_MODEL"
      },
      "workspace": "$WORKSPACE_DIR",
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
      "token": "$(gen_token)"
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

# ── Print summary ──────────────────────────────────────────────────────────
print_done() {
  echo ""
  echo "============================================================================"
  printf "${GREEN}  Setup Complete!${NC}\n"
  echo "============================================================================"
  echo ""
  echo "  Project:   $SETUP_DIR/"
  echo "  Data:      $OPENCLAW_DATA/"
  echo "  Workspace: $WORKSPACE_DIR/"
  echo ""
  printf "  ${YELLOW}NEXT STEPS:${NC}\n"
  echo ""
  echo "  1. Edit your credentials:"
  echo ""
  echo "     $SETUP_DIR/.env                  # domain, email, timezone"
  echo "     $OPENCLAW_DATA/openclaw.json     # API keys, LINE/Telegram tokens"
  echo ""
  echo "  2. Start everything:"
  echo ""
  echo "     cd $SETUP_DIR && docker compose up -d"
  echo ""
  echo "  3. Or run the interactive wizard inside the container:"
  echo ""
  echo "     docker compose run --rm openclaw configure"
  echo ""
  echo "  4. Check status:"
  echo ""
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
  write_traefik_config
  write_workspace
  write_openclaw_config

  print_done
}

main "$@"
