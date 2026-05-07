#!/usr/bin/env bash
# Idempotent Syncthing configuration via REST API.
# Run after `docker compose up -d syncthing` to converge the running instance
# to our desired state: Tailscale-only discovery, no public relays, with the
# Obsidian vault folder added. Re-runnable; safe to run on every deploy.
#
# Usage: ./configure.sh [SYNCTHING_CONFIG_DIR] [SYNCTHING_URL]
set -euo pipefail

CONFIG_DIR=${1:-${SYNCTHING_CONFIG_DIR:-/mnt/apps/syncthing}}
# Default URL: discover container IP since we don't publish 8384 on the host.
ST_URL=${2:-${ST_URL:-}}
if [ -z "$ST_URL" ]; then
  ST_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' syncthing 2>/dev/null | head -1)
  if [ -z "$ST_IP" ]; then
    echo "syncthing: container 'syncthing' not running. Try: docker compose up -d syncthing" >&2
    exit 1
  fi
  ST_URL="http://$ST_IP:8384"
fi

if [ ! -f "$CONFIG_DIR/config.xml" ]; then
  echo "syncthing: config.xml not found at $CONFIG_DIR/config.xml" >&2
  echo "Is the container running and config dir mounted?" >&2
  exit 1
fi

API_KEY=$(sed -n 's:.*<apikey>\(.*\)</apikey>.*:\1:p' "$CONFIG_DIR/config.xml" | head -1)
if [ -z "$API_KEY" ]; then
  echo "syncthing: failed to extract API key from config.xml" >&2
  exit 1
fi

api() { curl -fsS -H "X-API-Key: $API_KEY" -H "Content-Type: application/json" "$@"; }

echo "==> Disabling global discovery, global relays (Tailscale-only mode)"
api -X PATCH "$ST_URL/rest/config/options" -d '{
  "globalAnnounceEnabled": false,
  "relaysEnabled": false,
  "natEnabled": false,
  "localAnnounceEnabled": true,
  "urAccepted": -1
}' >/dev/null
echo "    ok"

echo "==> Upserting obsidian-vault folder"
api -X PUT "$ST_URL/rest/config/folders/obsidian-vault" -d '{
  "id": "obsidian-vault",
  "label": "Obsidian Vault",
  "path": "/sync/obsidian-vault",
  "type": "sendreceive",
  "rescanIntervalS": 60,
  "fsWatcherEnabled": true,
  "ignorePerms": false,
  "autoNormalize": true,
  "minDiskFree": {"value": 1, "unit": "%"},
  "versioning": {
    "type": "trashcan",
    "params": {"cleanoutDays": "30"}
  }
}' >/dev/null
echo "    ok"

echo
echo "Device ID (give this to your other devices):"
api "$ST_URL/rest/system/status" | sed -n 's/.*"myID":"\([^"]*\)".*/  \1/p' | head -1
echo
echo "GUI: $ST_URL  (set a password under Actions → Settings → GUI before exposing)"
