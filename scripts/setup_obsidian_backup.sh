#!/usr/bin/env bash
# Install restic + rclone, the backup script's systemd unit + timer.
# Idempotent. Re-run after pulling repo updates.
#
#   sudo ./scripts/setup_obsidian_backup.sh
#
# Does NOT enable the timer or initialise the restic repo — those need
# rclone OAuth and a populated /etc/obsidian-backup.env first. See
# apps/obsidian/SETUP.md for the manual finish-up steps.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script needs sudo." >&2
  exec sudo "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS_OBS="$REPO_ROOT/apps/obsidian"

echo "==> Installing restic and rclone via apt"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -qq -y restic rclone

echo "==> Installing systemd unit + timer"
install -m 0644 "$APPS_OBS/backup.service" /etc/systemd/system/obsidian-backup.service
install -m 0644 "$APPS_OBS/backup.timer"   /etc/systemd/system/obsidian-backup.timer
systemctl daemon-reload

if [ ! -f /etc/obsidian-backup.env ]; then
  echo "==> Seeding /etc/obsidian-backup.env from template (will need editing)"
  install -m 0600 "$APPS_OBS/backup.env.dist" /etc/obsidian-backup.env
  echo
  echo "Next steps (manual):"
  echo "  1. As user tibo:  rclone config       # set up the gdrive remote"
  echo "  2. Edit /etc/obsidian-backup.env: fill RESTIC_PASSWORD, adjust RESTIC_REPOSITORY"
  echo "  3. Init the repo once:"
  echo "       sudo systemd-run --pipe --uid=tibo --gid=tibo \\"
  echo "         --setenv-file=/etc/obsidian-backup.env restic init"
  echo "  4. Test a backup run:"
  echo "       sudo systemctl start obsidian-backup.service"
  echo "       sudo journalctl -u obsidian-backup.service -f"
  echo "  5. Enable the daily timer:"
  echo "       sudo systemctl enable --now obsidian-backup.timer"
else
  echo "==> /etc/obsidian-backup.env already present, leaving alone"
fi

echo
echo "Done."
