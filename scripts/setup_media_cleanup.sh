#!/usr/bin/env bash
# Configures qBittorrent, Radarr and Sonarr so that deleting a movie or show
# (in Jellyseerr, Radarr or Sonarr) also removes its torrent and download data
# through qbit_manage. Safe to re-run; run it with the stack up.
#
#   ./scripts/setup_media_cleanup.sh
#
# - qBittorrent gets movies-imported / shows-imported categories sharing the
#   save paths of movies / shows, so recategorising never moves data.
# - Radarr/Sonarr move a torrent into those categories once it is imported.
#   qbit_manage only acts there (servarr/config/qbit_manage/config.yml).
# - Radarr/Sonarr run servarr/hooks/qbit-manage-cleanup.sh on delete events.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck disable=SC1091
. ./.env
set +a

QBT="http://localhost:${WEBUI_PORT_QBITTORRENT}"
HOOK_NAME="qbit_manage cleanup"
HOOK_PATH="/hooks/qbit-manage-cleanup.sh"

cookies=$(mktemp)
trap 'rm -f "$cookies"' EXIT

echo "==> qBittorrent categories"
curl -fsS -c "$cookies" -o /dev/null \
  --data-urlencode "username=${QBITTORRENT_USER}" \
  --data-urlencode "password=${QBITTORRENT_PASS}" \
  "$QBT/api/v2/auth/login"
existing=$(curl -fsS -b "$cookies" "$QBT/api/v2/torrents/categories")
for pair in movies-imported:movies shows-imported:shows; do
  category=${pair%%:*}
  save_path=${pair#*:}
  current_path=$(jq -r --arg c "$category" '.[$c].savePath // empty' <<<"$existing")
  if [ "$current_path" = "$save_path" ]; then
    echo "    $category -> $save_path"
    continue
  elif jq -e --arg c "$category" 'has($c)' <<<"$existing" >/dev/null; then
    endpoint=editCategory
  else
    endpoint=createCategory
  fi
  curl -fsS -b "$cookies" -o /dev/null \
    --data-urlencode "category=$category" \
    --data-urlencode "savePath=$save_path" \
    "$QBT/api/v2/torrents/$endpoint"
  echo "    $category -> $save_path"
done

# arr_configure <name> <url> <api key> <imported-category field> <category> <event flags...>
arr_configure() {
  local name=$1 url=$2 key=$3 field=$4 category=$5
  shift 5
  local api=("-fsS" "-H" "X-Api-Key: $key" "-H" "Content-Type: application/json")

  echo "==> $name: post-import category"
  curl "${api[@]}" "$url/api/v3/downloadclient" |
    jq -c '.[] | select(.implementation == "QBittorrent")' |
    while read -r client; do
      updated=$(jq -c --arg f "$field" --arg c "$category" \
        '.fields |= map(if .name == $f then .value = $c else . end)' <<<"$client")
      curl "${api[@]}" -o /dev/null -X PUT \
        "$url/api/v3/downloadclient/$(jq -r .id <<<"$client")" -d "$updated"
      echo "    $(jq -r .name <<<"$client"): $field=$category"
    done

  echo "==> $name: delete hook"
  local flags
  flags=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({(.): true}) | add')
  local current
  current=$(curl "${api[@]}" "$url/api/v3/notification" |
    jq -c --arg n "$HOOK_NAME" '.[] | select(.name == $n)')
  local base method target
  if [ -n "$current" ]; then
    base=$current
    method=PUT
    target="$url/api/v3/notification/$(jq -r .id <<<"$current")"
  else
    base=$(curl "${api[@]}" "$url/api/v3/notification/schema" |
      jq -c '.[] | select(.implementation == "CustomScript")')
    method=POST
    target="$url/api/v3/notification"
  fi
  local body
  body=$(jq -c --arg n "$HOOK_NAME" --arg p "$HOOK_PATH" --argjson flags "$flags" '
    with_entries(if (.key | startswith("on")) and (.value | type == "boolean")
                 then .value = false else . end)
    + $flags
    + {name: $n, tags: []}
    | .fields |= map(if .name == "path" then .value = $p else . end)' <<<"$base")
  curl "${api[@]}" -o /dev/null -X "$method" "$target" -d "$body"
  echo "    $HOOK_NAME -> $HOOK_PATH ($*)"
}

arr_configure Radarr "http://localhost:${WEBUI_PORT_RADARR}" "$RADARR_API_KEY" \
  movieImportedCategory movies-imported \
  onMovieDelete onMovieFileDelete onMovieFileDeleteForUpgrade

arr_configure Sonarr "http://localhost:${WEBUI_PORT_SONARR}" "$SONARR_API_KEY" \
  tvImportedCategory shows-imported \
  onSeriesDelete onEpisodeFileDelete onEpisodeFileDeleteForUpgrade
