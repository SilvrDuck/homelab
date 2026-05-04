# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Conventions

- **Commits**: never add `Co-Authored-By: Claude` (or any Claude/Anthropic) trailers to commit messages.

## Overview

Personal homelab running on Ubuntu 22.04 in an LXC container on Proxmox. Uses Docker Compose with Traefik as reverse proxy. Services are organized into modular directories, each with their own `compose.yaml` that gets included in the root `compose.yaml`.

## Commands

```bash
# Initial setup (run once) - runs setup_docker.sh, setup_networking.sh,
# setup_pre_commit.sh, setup_tailscale.sh, and copies .env.dist -> .env if missing
sudo ./setup.sh

# Start all services
docker compose up -d

# View service status
docker compose ps

# View logs for a service
docker compose logs <service> -f

# Restart a service
docker compose restart <service>

# Generate Ubiquiti USG static host mappings for all services
python3 scripts/generate_usg_mappings.py
```

### Salon-des-inventions (Python/AI project, git submodule)

```bash
cd salon-des-inventions
pdm install          # Install dependencies
pdm run start        # Run chat application
```

VS Code launch configs available for debugging Chat and Sound modules.

### Potluck / "Roulette du Pastis" (`apps/potluck/`, Go)

Built via Docker (no host Go toolchain required); reads `POTLUCK_GEMINI_API_KEY` from `.env`. Listens on container port 8080, exposed via Traefik at `pastis-roulette.thvi.ch`.

## Architecture

```
compose.yaml              # Root compose - defines Traefik + the `web` network, includes all subdirs
├── infra/                # Homepage dashboard, Samba, UpSnap (WoL), Mongo Express
├── servarr/              # Media stack: qBittorrent, SABnzbd, Bazarr, Jellyfin, Jellyseerr,
│                         #   Sonarr, Radarr, Lidarr, Prowlarr, Flaresolverr, Unpackerr, qbit_manage
├── platal/               # Project management (mostly disabled/commented out)
├── apps/                 # File Browser, Potluck/Roulette du Pastis (Go + Gemini)
├── bots/                 # Telegram bots (e.g. telegram-xkcd-ibot, MongoDB-backed)
├── knightcrawler/        # Stremio addon for torrent streaming (PostgreSQL, Redis, LavinMQ)
└── salon-des-inventions/ # Python AI chatbot with MQTT/OpenAI/LangChain
```

Traefik itself lives in the root `compose.yaml`, not `infra/` — the included subdir compose files attach to the externally-created `web` network it manages.

**Git submodules**: `salon-des-inventions/` and `bots/telegram-xkcd-ibot/` are git submodules. After cloning, run `git submodule update --init --recursive` before bringing the stack up. The submodules' own compose files / Dockerfiles are referenced from this repo's compose includes and `build:` contexts.

## Key Patterns

**Docker Compose modular includes**: Each service family has independent `compose.yaml` files aggregated by root.

**Traefik routing**: Services use labels for routing configuration:
- `traefik.http.routers.<name>.rule=Host(...)` for routing
- `traefik.http.routers.<name>.tls.certresolver=myresolver` for ACME certs
- DNS challenge via Infomaniak for SSL certificates

**Dual routing**: Services support both internal (`.lan`) and public (`.thvi.ch`) domains.

**Homepage dashboard integration**: Services use `homepage.*` labels for dashboard widgets.

**LinuxServer.io containers**: Use standard `PUID`, `PGID`, `UMASK`, `TZ` environment variables.

## Environment Configuration

Copy `.env.dist` to `.env` and fill in values. Key sections:
- **Networking**: SMB credentials, Homepage port, Docker group ID
- **Traefik**: `INFOMANIAK_ACCESS_TOKEN` for DNS challenge, `PUBLIC_URL_*` for domains
- **Servarr**: Folder paths (`FOLDER_FOR_CONFIGS`, `FOLDER_FOR_MEDIA`), API keys for each service
- **AI**: OpenAI and LangChain/LangSmith keys for salon-des-inventions

## Networks

- `web`: External network for Traefik routing (created by `scripts/setup_networking.sh`)
- Service-specific networks for isolation (e.g., `knightcrawler-network`)

## Important Notes

- Containerd is pinned to `1.7.28-1~ubuntu.22.04~jammy` and held with `apt-mark` for Proxmox LXC compatibility (newer 2.x fails on `net.ipv4.ip_unprivileged_port_start` inside unprivileged LXCs); see `scripts/setup_docker.sh`. The same script also forces `DOCKER_MIN_API_VERSION=1.24` via systemd override so Traefik's docker provider works.
- Traefik ACME certificates stored in `data/traefik/acme/acme.json`
- Servarr stack follows [trash-guides.info](https://trash-guides.info) best practices
