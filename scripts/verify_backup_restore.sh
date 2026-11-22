#!/usr/bin/env bash
# Quarterly drill: restore the latest backup and confirm it looks right.
# Doesn't expect bit-perfect match — live data drifts between snapshots.
#
#   sudo ./scripts/verify_backup_restore.sh
#   KEEP_TEMP=1 sudo ./scripts/verify_backup_restore.sh   # keep restore for inspection
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

ENV_FILE=/etc/homelab-backup.env
[ -f "$ENV_FILE" ] || { echo "Missing $ENV_FILE — has the backup been installed?" >&2; exit 1; }

TARGET=$(mktemp -d -t homelab-restore.XXXXXX)
if [ -z "${KEEP_TEMP:-}" ]; then
  trap 'rm -rf "$TARGET"' EXIT
fi

restic_run() {
  systemd-run --wait --pipe --quiet --uid=tibo --gid=tibo \
    --property=EnvironmentFile="$ENV_FILE" \
    /usr/bin/restic "$@"
}

echo "==> Recent snapshots"
restic_run snapshots --latest 3

echo "==> Restoring latest to $TARGET"
restic_run restore latest --target "$TARGET"

LIVE_VAULT=/mnt/media/obsidian/vaults
LIVE_CONFIG=/mnt/apps

echo "==> File counts"
printf '    %-7s  live: %6d   restored: %6d\n' "vault"  \
  "$(find "$LIVE_VAULT"  -type f 2>/dev/null | wc -l)" \
  "$(find "$TARGET$LIVE_VAULT"  -type f 2>/dev/null | wc -l)"
printf '    %-7s  live: %6d   restored: %6d\n' "config" \
  "$(find "$LIVE_CONFIG" -type f 2>/dev/null | wc -l)" \
  "$(find "$TARGET$LIVE_CONFIG" -type f 2>/dev/null | wc -l)"

echo "==> Sample restored markdown"
find "$TARGET$LIVE_VAULT" -type f -name '*.md' 2>/dev/null | head -3 | sed 's/^/    /'

echo
if [ -n "${KEEP_TEMP:-}" ]; then
  echo "Kept at: $TARGET (clean up manually)"
else
  echo "Cleaning up $TARGET"
fi
