#!/usr/bin/env bash
# Sends a Telegram DM when a homelab filesystem crosses the usage threshold,
# and again when it drops back below. Run from cron; it only messages on a change.
#
# Reads from the repo's .env:
#   DISK_ALERT_TELEGRAM_TOKEN    bot token from @BotFather
#   DISK_ALERT_TELEGRAM_CHAT_ID  your chat ID with that bot
#   DISK_ALERT_THRESHOLD         percent, default 90
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/homelab-disk-alert"
MOUNTS=(/ /mnt/media /mnt/apps)

env_value() {
  grep -E "^$1=" "$REPO_DIR/.env" | tail -1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$//; s/^"(.*)"$/\1/; s/[[:space:]]+$//'
}

TOKEN="$(env_value DISK_ALERT_TELEGRAM_TOKEN)"
CHAT_ID="$(env_value DISK_ALERT_TELEGRAM_CHAT_ID)"
THRESHOLD="$(env_value DISK_ALERT_THRESHOLD)"
THRESHOLD="${THRESHOLD:-90}"

if [[ -z "$TOKEN" || -z "$CHAT_ID" ]]; then
  echo "disk_alert: DISK_ALERT_TELEGRAM_TOKEN or DISK_ALERT_TELEGRAM_CHAT_ID missing in .env" >&2
  exit 1
fi

send() {
  curl -fsS -m 20 "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null
}

mkdir -p "$STATE_DIR"

for mount in "${MOUNTS[@]}"; do
  read -r used avail < <(df --output=pcent,avail -h "$mount" | tail -1 | tr -d '%')
  state_file="$STATE_DIR/$(echo "$mount" | tr / _)"
  was_full=false
  [[ -f "$state_file" ]] && was_full=true

  if (( used >= THRESHOLD )) && ! $was_full; then
    send "⚠️ $(hostname): $mount is ${used}% full (${avail} free)." && touch "$state_file"
  elif (( used < THRESHOLD )) && $was_full; then
    send "✅ $(hostname): $mount is back to ${used}% (${avail} free)." && rm -f "$state_file"
  fi
done
