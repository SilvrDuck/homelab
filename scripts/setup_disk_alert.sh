#!/usr/bin/env bash
# Installs a cron entry that runs disk_alert.sh every 15 minutes (idempotent).
# Works from setup.sh under sudo (installs for the invoking user) or as that user directly.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/disk_alert.sh"
TARGET_USER="${SUDO_USER:-$(id -un)}"
LINE="*/15 * * * * $SCRIPT >/dev/null 2>&1"

current="$(crontab -u "$TARGET_USER" -l 2>/dev/null || true)"
if grep -qF "$SCRIPT" <<<"$current"; then
  echo "[setup_disk_alert] cron entry already present for $TARGET_USER"
else
  printf '%s\n%s\n' "$current" "$LINE" | sed '/^$/d' | crontab -u "$TARGET_USER" -
  echo "[setup_disk_alert] cron entry installed for $TARGET_USER"
fi
