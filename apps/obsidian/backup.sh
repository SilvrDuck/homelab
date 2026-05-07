#!/usr/bin/env bash
# Daily restic backup of the Obsidian vault and config to Google Drive via rclone.
# Invoked by /etc/systemd/system/obsidian-backup.service (see backup.service).
#
# Required environment (loaded from EnvironmentFile in the systemd unit):
#   RESTIC_REPOSITORY      e.g. rclone:gdrive:homelab-backups/obsidian
#   RESTIC_PASSWORD        the repo passphrase
#   RCLONE_CONFIG          path to rclone.conf (default ~/.config/rclone/rclone.conf)
set -euo pipefail

VAULT_PATH=/mnt/media/obsidian/vaults
CONFIG_PATH=/mnt/apps/obsidian
HOSTNAME_TAG="$(hostname)"

if [ ! -d "$VAULT_PATH" ] || [ ! -d "$CONFIG_PATH" ]; then
  echo "obsidian backup: source paths missing ($VAULT_PATH or $CONFIG_PATH)" >&2
  exit 1
fi

restic backup \
  --host "$HOSTNAME_TAG" \
  --tag obsidian \
  --exclude "$CONFIG_PATH/.cache" \
  --exclude "$CONFIG_PATH/Desktop/Trash" \
  --exclude '.obsidian/workspace*.json' \
  "$VAULT_PATH" \
  "$CONFIG_PATH"

restic forget \
  --tag obsidian \
  --host "$HOSTNAME_TAG" \
  --keep-daily 14 \
  --keep-weekly 8 \
  --keep-monthly 12 \
  --keep-yearly 5 \
  --prune
