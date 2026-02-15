# OpenClaw Docker Setup

One-script setup for [OpenClaw](https://docs.openclaw.ai/) — AI gateway with LINE, Telegram, and more.

**Only requirement: Docker.**

## Quick start

```bash
git clone https://github.com/Boom-Vitt/openclaw-setup.git
cd openclaw-setup
bash setup-openclaw.sh
```

The script asks you one question:

```
Where are you deploying?

  1) VPS   — public server with domain (adds Traefik + auto SSL)
  2) Local — your machine, localhost access only
```

### VPS mode

Deploys **Traefik** (reverse proxy + auto Let's Encrypt SSL) + **OpenClaw** in Docker.

You get: `https://openclaw.yourdomain.com`

The script will ask for:
- Your domain (e.g. `srv1068766.hstgr.cloud`)
- SSL email (for Let's Encrypt)
- Timezone

Then just:
```bash
# edit ~/.openclaw/openclaw.json  (add API keys + LINE tokens)
docker compose up -d --build
```

Set your LINE webhook to: `https://openclaw.yourdomain.com/webhook/line`

Make sure DNS `openclaw.yourdomain.com` points to your server IP.

### Local mode

Just OpenClaw on `localhost:18789`. No Traefik, no SSL.

```bash
# edit ~/.openclaw/openclaw.json  (add API keys + LINE tokens)
docker compose up -d --build
```

## What you provide

- AI model provider + API key (e.g. `kimi-coding/k2p5`, `anthropic/claude-opus-4-5`)
- LINE channel access token & secret (from [LINE Developers Console](https://developers.line.biz/))
- Telegram bot token (optional, from [@BotFather](https://t.me/BotFather))

## Commands

```bash
# Start
docker compose up -d --build

# Logs
docker compose logs -f openclaw

# Interactive wizard
docker compose run --rm openclaw configure

# Stop
docker compose down

# Rebuild after OpenClaw update
docker compose build --no-cache && docker compose up -d
```
