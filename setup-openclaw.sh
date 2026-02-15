#!/usr/bin/env bash
# ============================================================================
# OpenClaw Docker Setup
# Only requirement: Docker.
#   VPS mode  → Traefik + auto SSL + openclaw.yourdomain.com
#   Local mode → localhost:18789
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
  command -v docker &>/dev/null || err "Docker required. Install: https://docs.docker.com/get-docker/"
  docker info &>/dev/null 2>&1  || err "Docker daemon not running. Start Docker first."
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

# ── Ask deploy mode ────────────────────────────────────────────────────────
ask_mode() {
  echo ""
  echo "  Where are you deploying?"
  echo ""
  echo "    1) VPS   — public server with domain (adds Traefik + auto SSL)"
  echo "    2) Local — your machine, localhost access only"
  echo ""
  printf "  Choose [1/2]: "
  read -r MODE_INPUT
  case "${MODE_INPUT:-2}" in
    1|vps|VPS)   DEPLOY_MODE="vps" ;;
    *)           DEPLOY_MODE="local" ;;
  esac
  ok "Deploy mode: $DEPLOY_MODE"

  if [ "$DEPLOY_MODE" = "vps" ]; then
    echo ""
    printf "  Your domain (e.g. srv1068766.hstgr.cloud): "
    read -r DOMAIN_NAME
    [ -z "${DOMAIN_NAME:-}" ] && err "Domain is required for VPS mode."

    printf "  SSL email (for Let's Encrypt): "
    read -r SSL_EMAIL
    [ -z "${SSL_EMAIL:-}" ] && SSL_EMAIL="admin@$DOMAIN_NAME"

    printf "  Timezone (e.g. Asia/Bangkok) [UTC]: "
    read -r TZ_INPUT
    TZ_VAL="${TZ_INPUT:-UTC}"

    ok "Domain: openclaw.$DOMAIN_NAME"
  fi
}

# ── Create directories ─────────────────────────────────────────────────────
setup_dirs() {
  info "Creating directories..."
  mkdir -p "$OPENCLAW_DATA"/{agents/main,canvas,credentials,cron/runs,devices,extensions,identity}
  mkdir -p "$WORKSPACE_DIR/memory"
  [ "$DEPLOY_MODE" = "vps" ] && mkdir -p "$SCRIPT_DIR/traefik-config"
  ok "Directories"
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

  if [ "$DEPLOY_MODE" = "vps" ]; then
    # ── VPS: Traefik + OpenClaw ──
    cat > "$SCRIPT_DIR/docker-compose.yml" << CEOF
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
      - "--certificatesresolvers.mytlschallenge.acme.email=$SSL_EMAIL"
      - "--certificatesresolvers.mytlschallenge.acme.storage=/letsencrypt/acme.json"
    ports:
      - "80:80"
      - "443:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - traefik_data:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik-config:/etc/traefik/dynamic:ro

  # ── OpenClaw (AI gateway) ──
  openclaw:
    build: .
    restart: unless-stopped
    ports:
      - "127.0.0.1:18789:18789"
    labels:
      - traefik.enable=true
      - traefik.http.routers.openclaw.rule=Host(\`openclaw.$DOMAIN_NAME\`)
      - traefik.http.routers.openclaw.tls=true
      - traefik.http.routers.openclaw.entrypoints=web,websecure
      - traefik.http.routers.openclaw.tls.certresolver=mytlschallenge
      - traefik.http.services.openclaw.loadbalancer.server.port=18789
    volumes:
      - $OPENCLAW_DATA:/root/.openclaw

volumes:
  traefik_data:
CEOF

    # ── Traefik dynamic config (fallback route) ──
    cat > "$SCRIPT_DIR/traefik-config/openclaw.yml" << TEOF
http:
  routers:
    openclaw:
      rule: "Host(\`openclaw.$DOMAIN_NAME\`)"
      service: openclaw
      entrypoints:
        - websecure
      tls:
        certResolver: mytlschallenge
  services:
    openclaw:
      loadBalancer:
        servers:
          - url: "http://host.docker.internal:18789"
TEOF

  else
    # ── Local: just OpenClaw ──
    cat > "$SCRIPT_DIR/docker-compose.yml" << CEOF
services:
  openclaw:
    build: .
    restart: unless-stopped
    ports:
      - "18789:18789"
    volumes:
      - $OPENCLAW_DATA:/root/.openclaw
CEOF
  fi

  ok "docker-compose.yml ($DEPLOY_MODE)"
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

  # Build remote block for VPS mode
  local REMOTE_BLOCK=""
  if [ "$DEPLOY_MODE" = "vps" ]; then
    REMOTE_BLOCK="$(cat << REOF
,
    "remote": {
      "url": "wss://openclaw.$DOMAIN_NAME",
      "token": "$TOKEN"
    }
REOF
)"
  fi

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
    }$REMOTE_BLOCK
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
  ok "OpenClaw config → $CFG"
}

# ── Summary ─────────────────────────────────────────────────────────────────
print_done() {
  echo ""
  echo "============================================================================"
  printf "${GREEN}  OpenClaw is ready!${NC}\n"
  echo "============================================================================"
  echo ""

  if [ "$DEPLOY_MODE" = "vps" ]; then
    echo "  Mode:      VPS (Traefik + auto SSL)"
    echo "  URL:       https://openclaw.$DOMAIN_NAME"
    echo "  Webhook:   https://openclaw.$DOMAIN_NAME/webhook/line"
    echo ""
  else
    echo "  Mode:      Local"
    echo "  URL:       http://localhost:18789"
    echo ""
  fi

  printf "  ${YELLOW}NEXT STEPS:${NC}\n"
  echo ""
  echo "  1. Edit credentials:"
  echo "     $OPENCLAW_DATA/openclaw.json"
  echo "       - model provider + API key"
  echo "       - LINE channel token & secret"
  echo "       - Telegram bot token (optional)"
  echo ""
  echo "  2. Start:"
  echo "     cd $SCRIPT_DIR && docker compose up -d --build"
  echo ""
  echo "  3. Or wizard:"
  echo "     docker compose run --rm openclaw configure"
  echo ""
  echo "  4. Logs:"
  echo "     docker compose logs -f openclaw"
  echo ""

  if [ "$DEPLOY_MODE" = "vps" ]; then
    echo "  5. Set LINE webhook URL to:"
    echo "     https://openclaw.$DOMAIN_NAME/webhook/line"
    echo ""
    echo "  Make sure DNS points openclaw.$DOMAIN_NAME → this server's IP"
    echo ""
  fi

  echo "============================================================================"
  echo ""
}

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  echo ""
  printf "${CYAN}  OpenClaw Docker Setup${NC}\n"
  echo "  Only requirement: Docker"

  check_docker
  ask_mode
  setup_dirs
  write_dockerfile
  write_compose
  write_workspace
  write_config

  print_done
}

main "$@"
