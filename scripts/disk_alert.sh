#!/usr/bin/env bash
# Sends a Telegram DM when a homelab filesystem crosses the usage threshold,
# and again when it drops back below. Run from cron; it only messages on a change.
#
# Reads from the repo's .env:
#   DISK_ALERT_TELEGRAM_TOKEN    bot token from @BotFather
#   DISK_ALERT_TELEGRAM_CHAT_ID  your chat ID with that bot
#   DISK_ALERT_THRESHOLD         percent, default 90
#   DISK_ALERT_KUMA_PUSH_URL     optional Uptime Kuma push URL, pinged on every run
#                                so a dead cron job shows up as a down monitor
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/homelab-disk-alert"
MOUNTS=(/ /mnt/media /mnt/apps)

env_value() {
  { grep -E "^$1=" "$REPO_DIR/.env" || true; } | tail -1 | cut -d= -f2- | sed -E 's/[[:space:]]+#.*$//; s/^"(.*)"$/\1/; s/[[:space:]]+$//'
}

TOKEN="$(env_value DISK_ALERT_TELEGRAM_TOKEN)"
CHAT_ID="$(env_value DISK_ALERT_TELEGRAM_CHAT_ID)"
THRESHOLD="$(env_value DISK_ALERT_THRESHOLD)"
THRESHOLD="${THRESHOLD:-90}"
PUSH_URL="$(env_value DISK_ALERT_KUMA_PUSH_URL)"

if [[ -z "$TOKEN" || -z "$CHAT_ID" ]]; then
  echo "disk_alert: DISK_ALERT_TELEGRAM_TOKEN or DISK_ALERT_TELEGRAM_CHAT_ID missing in .env" >&2
  exit 1
fi

send() {
  # The URL goes in via stdin config so the bot token never shows up in `ps`.
  curl -fsS -m 20 -K - <<<"url = \"https://api.telegram.org/bot${TOKEN}/sendMessage\"" \
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
    # A full root disk can make touch fail; that must not abort the run before the heartbeat.
    send "⚠️ $(hostname): $mount is ${used}% full (${avail} free)." && { touch "$state_file" || true; }
  elif (( used < THRESHOLD )) && $was_full; then
    send "✅ $(hostname): $mount is back to ${used}% (${avail} free)." && rm -f "$state_file"
  fi
done

if [[ -n "$PUSH_URL" ]]; then
  # Via stdin config, like send(), so the push token stays out of `ps`.
  curl -fsS -m 10 -K - <<<"url = \"${PUSH_URL}\"" >/dev/null || true
fi
