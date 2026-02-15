# OpenClaw Docker Setup

One-script setup for [OpenClaw](https://docs.openclaw.ai/) — AI gateway with LINE, Telegram, and more.

**Only requirement: Docker.**

## What it does

- Builds an OpenClaw Docker image (Node.js + OpenClaw)
- Sets up **Traefik** (reverse proxy + auto SSL) + **n8n** (workflow automation) + **OpenClaw** (AI gateway)
- Creates workspace templates (AGENTS.md, SOUL.md, BOOTSTRAP.md, etc.)
- Generates `docker-compose.yml` and `.env` — just fill in your credentials and `docker compose up -d`

## Quick start

```bash
bash setup-openclaw.sh
```

Then:

1. Edit `~/openclaw-setup/.env` — set your domain, email, timezone
2. Edit `~/.openclaw/openclaw.json` — set your API keys, LINE/Telegram tokens
3. Start:
   ```bash
   cd ~/openclaw-setup && docker compose up -d
   ```
4. Or run the interactive wizard:
   ```bash
   docker compose run --rm openclaw configure
   ```

## What's NOT included (you provide these)

- AI provider API keys
- LINE channel access token & secret
- Telegram bot token
- Domain name & SSL email

## Works on

- Linux (Ubuntu, Debian, Fedora, Arch, Alpine)
- macOS
- Windows (WSL / Git Bash)
