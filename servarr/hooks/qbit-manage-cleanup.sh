#!/bin/sh
# Radarr/Sonarr Connect custom script, run on movie/series/file delete events.
# Asks qbit_manage to remove torrents whose library copy no longer exists.

[ "${radarr_eventtype:-$sonarr_eventtype}" = "Test" ] && exit 0

# Delete events can fire before the files are gone from disk, and the *arr
# waits for this script to exit, so trigger the run in the background after a
# short delay.
(
  sleep 30
  curl -fsS -X POST http://qbit_manage:8181/api/run-command \
    -H 'Content-Type: application/json' \
    -d '{"commands": ["tag_nohardlinks", "share_limits"]}'
) >/dev/null 2>&1 &

exit 0
