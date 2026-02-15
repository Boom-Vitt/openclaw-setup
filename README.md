# OpenClaw Docker Setup

One-script setup for [OpenClaw](https://docs.openclaw.ai/) — AI gateway with LINE, Telegram, and more.

**Only requirement: Docker.** Works on VPS or local machine.

## Quick start

```bash
git clone https://github.com/Boom-Vitt/openclaw-setup.git
cd openclaw-setup
bash setup-openclaw.sh
```

Then:

1. Edit `~/.openclaw/openclaw.json` — set your API keys + LINE/Telegram tokens
2. Start: `docker compose up -d`
3. Or run the wizard: `docker compose run --rm openclaw configure`

## What's included

- Dockerfile (Node 22 + OpenClaw)
- docker-compose.yml
- Workspace templates (AGENTS.md, SOUL.md, BOOTSTRAP.md, etc.)
- Auto-generated gateway auth token

## What you provide

- AI model provider + API key
- LINE channel access token & secret (optional)
- Telegram bot token (optional)

## Deploy

**VPS:**
```bash
bash setup-openclaw.sh
docker compose up -d
```

**Local machine:**
```bash
bash setup-openclaw.sh
docker compose up -d
```

Same command everywhere.
