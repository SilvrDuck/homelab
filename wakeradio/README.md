# wakeradio

Raspberry Pi 3B that rebroadcasts a web radio on FM so the Philips HF3531 wake-up
light (FM-only tuner) can wake to stations that left FM, such as Couleur 3.

```
myMPD (phone) → MPD → bluez-alsa → Bluetooth A2DP → XO-BCC16 FM transmitter → HF3531
```

- Pi: `$WAKERADIO_HOST` (fixed IP in Unifi), hostname `wakeradio`, user `$WAKERADIO_USER`, SSH key only.
- Web UI: `https://$WAKERADIO_HOST:8443` (myMPD, self-signed certificate).
- XO-BCC16: Bluetooth `$WAKERADIO_XO_MAC`, powered from the charger's USB-A port.

The `WAKERADIO_*` values live in the root `.env` (see `.env.dist`).

## Fresh install

1. Flash Raspberry Pi OS Lite 64-bit with a cloud-init `user-data` (hostname, user,
   SSH key) and `network-config` (Wi-Fi, `regulatory-domain: CH`) on the boot partition.
2. Pair the XO once (it is discoverable while not connected):
   `bluetoothctl` → `scan on` → `pair $WAKERADIO_XO_MAC` → `trust …` → `connect …`.
   Bluetooth boots soft-blocked by rfkill; `rfkill unblock bluetooth` first.
3. Deploy from the repo root:
   ```
   set -a && . <(grep '^WAKERADIO_' .env) && set +a
   rsync -a wakeradio/ "$WAKERADIO_USER@$WAKERADIO_HOST:wakeradio/"
   ssh "$WAKERADIO_USER@$WAKERADIO_HOST" sudo WAKERADIO_XO_MAC="$WAKERADIO_XO_MAC" wakeradio/install.sh
   ```

## How it recovers on its own

| Piece | Mechanism |
|---|---|
| Bluetooth link | `bt-keepalive.service` unblocks rfkill and reconnects the XO every 5 s |
| Playback | MPD restores queue and play state (`state_file_interval 10`, `restore_paused no`); `radio-watchdog.service` restarts playback when stopped or stalled |
| Hang | systemd hardware watchdog (`RuntimeWatchdogSec=15`) reboots the Pi |
| Wi-Fi | NetworkManager, power save off |

A reboot is back on air in about a minute.

Because the watchdog restarts playback, stop and pause do not stick; set the volume to 0 for silence.

## Diagnosing

| What | Command |
|---|---|
| Previous boot's logs | `journalctl -b -1` (journal is persistent, capped at 64 MB) |
| Health, one line per minute | `journalctl -t wakeradio-health` |
| CPU / memory / IO / network history | `sar -u`, `sar -r`, `sar -d`, `sar -n DEV` (sysstat, 1-minute samples, 7 days) |
| Kernel panic text | `/var/lib/systemd/pstore/` (ramoops) |
| Playback | `mpc status`, `bluealsa-cli list-pcms` |
