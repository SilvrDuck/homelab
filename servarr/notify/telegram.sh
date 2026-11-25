#!/bin/bash
# Custom Script connection for Sonarr, Radarr and Lidarr: one Telegram message per
# grab, import and upgrade. Needs TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID.
set -euo pipefail

# The apps' variable names differ in case between versions, so look them up lowercased.
declare -A var
while IFS= read -r -d '' pair; do
  name=${pair%%=*}
  var[${name,,}]=${pair#*=}
done < <(env -0)

get() { printf '%s' "${var[$1]:-}"; }

app=
for candidate in sonarr radarr lidarr; do
  [[ -n $(get "${candidate}_eventtype") ]] && app=$candidate
done
[[ -n $app ]] || exit 0

event=$(get "${app}_eventtype")
case $event in
  Grab) heading="⬇️ Grabbed" ;;
  Download | AlbumDownload)
    if [[ $(get "${app}_isupgrade") == True || -n $(get lidarr_deletedpaths) ]]; then
      heading="⬆️ Upgraded"
    else
      heading="✅ Downloaded"
    fi
    ;;
  Test) heading="🔔 Test from ${app^}" ;;
  *) exit 0 ;;
esac

if [[ $event == Grab ]]; then
  file=release
elif [[ $app == radarr ]]; then
  file=moviefile
else
  file=episodefile
fi

detail=
quality=
case $app in
  sonarr)
    season=$(get "sonarr_${file}_seasonnumber")
    if [[ -n $season ]]; then
      episodes=
      IFS=, read -ra numbers <<<"$(get "sonarr_${file}_episodenumbers")"
      for number in "${numbers[@]}"; do
        printf -v number '%02d' "$((10#$number))"
        episodes+=${episodes:+,}$number
      done
      titles=$(get "sonarr_${file}_episodetitles")
      detail="$(get sonarr_series_title) - ${season}x${episodes} - ${titles//|/, }"
      quality=$(get "sonarr_${file}_quality")
    fi
    ;;
  radarr)
    if [[ -n $(get radarr_movie_title) ]]; then
      detail="$(get radarr_movie_title) ($(get radarr_movie_year))"
      quality=$(get "radarr_${file}_quality")
    fi
    ;;
  lidarr)
    if [[ $event == Grab ]]; then
      albums=$(get lidarr_release_albumtitles)
      quality=$(get lidarr_release_quality)
    else
      albums=$(get lidarr_album_title)
    fi
    [[ -n $albums ]] && detail="$(get lidarr_artist_name) - ${albums//|/, }"
    ;;
esac

text=$heading
[[ -n $detail ]] && text+=$'\n'$detail
[[ -n $quality ]] && text+=" [$quality]"

# The URL carries the token, so it goes through stdin to stay out of the process list.
printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "${TELEGRAM_BOT_TOKEN:?}" |
  curl --silent --show-error --fail --max-time 20 --output /dev/null --config - \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID:?}" \
    --data-urlencode "text=$text"
