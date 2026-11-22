#!/usr/bin/env bash
# Daily restic backup of all app configs (/mnt/apps) and the Obsidian vault to
# Google Drive via rclone. Invoked by /etc/systemd/system/homelab-backup.service
# (see backup.service).
#
# Required environment (loaded from EnvironmentFile in the systemd unit):
#   RESTIC_REPOSITORY      e.g. rclone:gdrive:homelab-backups
#   RESTIC_PASSWORD        the repo passphrase
#   RCLONE_CONFIG          path to rclone.conf (default ~/.config/rclone/rclone.conf)
set -euo pipefail

APPS_PATH=/mnt/apps
VAULT_PATH=/mnt/media/obsidian/vaults
HOSTNAME_TAG="$(hostname)"

if [ ! -d "$APPS_PATH" ] || [ ! -d "$VAULT_PATH" ]; then
  echo "homelab backup: source paths missing ($APPS_PATH or $VAULT_PATH)" >&2
  exit 1
fi

restic backup \
  --host "$HOSTNAME_TAG" \
  --tag homelab \
  --exclude "$APPS_PATH/knightcrawler" \
  --exclude "$APPS_PATH/obsidian/.cache" \
  --exclude "$APPS_PATH/obsidian/.config/obsidian/Singleton*" \
  --exclude "$APPS_PATH/obsidian/Desktop/Trash" \
  --exclude '.obsidian/workspace*.json' \
  "$APPS_PATH" \
  "$VAULT_PATH"

restic forget \
  --tag homelab \
  --host "$HOSTNAME_TAG" \
  --keep-daily 14 \
  --keep-weekly 8 \
  --keep-monthly 12 \
  --keep-yearly 5 \
  --prune

# Read-back a slice each run so bit-rot / partial uploads / pack-file damage
# get caught before they bite a restore. 5% per day → whole repo every ~3 weeks.
restic check --read-data-subset=5%
