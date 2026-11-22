#!/usr/bin/env bash
# Install restic + rclone, the backup script's systemd unit + timer.
# Idempotent. Re-run after pulling repo updates.
#
#   sudo ./scripts/setup_backup.sh
#
# Does NOT enable the timer or initialise the restic repo — those need
# rclone OAuth and a populated /etc/homelab-backup.env first. See
# infra/backup/README.md for the manual finish-up steps.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This script needs sudo." >&2
  exec sudo "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP_DIR="$REPO_ROOT/infra/backup"

echo "==> Installing restic and rclone via apt"
DEBIAN_FRONTEND=noninteractive apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -qq -y restic rclone

echo "==> Installing systemd unit + timer"
install -m 0644 "$BACKUP_DIR/backup.service" /etc/systemd/system/homelab-backup.service
install -m 0644 "$BACKUP_DIR/backup.timer"   /etc/systemd/system/homelab-backup.timer
systemctl daemon-reload

if [ ! -f /etc/homelab-backup.env ]; then
  echo "==> Seeding /etc/homelab-backup.env from template (will need editing)"
  install -m 0600 "$BACKUP_DIR/backup.env.dist" /etc/homelab-backup.env
  echo
  echo "Next steps (manual):"
  echo "  1. As user tibo:  rclone config       # set up the gdrive remote"
  echo "  2. Edit /etc/homelab-backup.env: fill RESTIC_PASSWORD, adjust RESTIC_REPOSITORY"
  echo "  3. Init the repo once:"
  echo "       sudo systemd-run --pipe --uid=tibo --gid=tibo \\"
  echo "         --setenv-file=/etc/homelab-backup.env restic init"
  echo "  4. Test a backup run:"
  echo "       sudo systemctl start homelab-backup.service"
  echo "       sudo journalctl -u homelab-backup.service -f"
  echo "  5. Enable the daily timer:"
  echo "       sudo systemctl enable --now homelab-backup.timer"
else
  echo "==> /etc/homelab-backup.env already present, leaving alone"
fi

echo
echo "Done."
