#!/usr/bin/env bash
# Installs and configures the wake radio Pi. Idempotent; run as root from this directory.
set -euo pipefail
cd "$(dirname "$0")"
XO_MAC=41:42:CC:40:1E:6E
DEFAULT_STREAM=http://stream.srg-ssr.ch/m/couleur3/mp3_128

# myMPD apt repository (key fingerprint from https://jcorporation.github.io/myMPD/)
. /etc/os-release
keyring=/usr/share/keyrings/jcorporation.github.io.gpg
repo="https://download.opensuse.org/repositories/home:/jcorporation/Debian_${VERSION_ID}"
if [ ! -f "$keyring" ]; then
  key=$(curl -fsSL "$repo/Release.key")
  gpg --show-keys --with-colons <<<"$key" | grep -q '^fpr:::::::::A37AADC40A1CC6BEFB75372FAA09B8CCE895BD7D:' \
    || { echo "myMPD repository key fingerprint mismatch" >&2; exit 1; }
  gpg --dearmor --yes -o "$keyring" <<<"$key"
fi
echo "deb [signed-by=$keyring] $repo/ ./" > /etc/apt/sources.list.d/jcorporation.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  bluez-alsa-utils libasound2-plugin-bluez mpd mpc mympd rfkill sysstat
echo "XO_MAC=$XO_MAC" > /etc/wakeradio.env
install -m 755 bt-keepalive radio-watchdog wakeradio-health /usr/local/bin/
sed "s/@XO_MAC@/$XO_MAC/" mpd.conf > /etc/mpd.conf

unit() { cat > "/etc/systemd/system/$1"; }
unit bt-keepalive.service <<UNIT
[Unit]
Description=Keep the XO-BCC16 FM transmitter connected
After=bluetooth.service
Wants=bluetooth.service

[Service]
ExecStart=/usr/local/bin/bt-keepalive
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
unit radio-watchdog.service <<UNIT
[Unit]
Description=Keep MPD playing
After=mpd.service
Wants=mpd.service

[Service]
ExecStart=/usr/local/bin/radio-watchdog
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
unit wakeradio-health.service <<UNIT
[Unit]
Description=Log a wake radio health snapshot

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wakeradio-health
SyslogIdentifier=wakeradio-health
UNIT
unit wakeradio-health.timer <<UNIT
[Unit]
Description=Log a wake radio health snapshot every minute

[Timer]
OnCalendar=minutely

[Install]
WantedBy=timers.target
UNIT

# Monitoring: persistent journal, per-minute sysstat, kernel panic capture, hardware watchdog.
mkdir -p /etc/systemd/journald.conf.d /etc/systemd/system.conf.d /etc/systemd/system/sysstat-collect.timer.d /etc/NetworkManager/conf.d
printf '[Journal]\nStorage=persistent\nSystemMaxUse=64M\n' > /etc/systemd/journald.conf.d/50-wakeradio-persistent.conf
sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
printf '[Timer]\nOnCalendar=\nOnCalendar=minutely\n' > /etc/systemd/system/sysstat-collect.timer.d/minutely.conf
grep -q '^dtoverlay=ramoops' /boot/firmware/config.txt || printf 'dtoverlay=ramoops\n' >> /boot/firmware/config.txt
printf '[Manager]\nRuntimeWatchdogSec=15\n' > /etc/systemd/system.conf.d/watchdog.conf
printf '[connection]\nwifi.powersave = 2\n' > /etc/NetworkManager/conf.d/wifi-powersave-off.conf

systemctl daemon-reexec
systemctl daemon-reload
systemctl disable --now bluealsa-aplay.service
systemctl enable --now bluealsa.service bt-keepalive.service mpd.socket mpd.service radio-watchdog.service wakeradio-health.timer sysstat.service sysstat-collect.timer
systemctl restart mpd.service

for _ in $(seq 30); do mpc -q status >/dev/null 2>&1 && break; sleep 1; done
if [ -z "$(mpc playlist)" ]; then
  mpc -q add "$DEFAULT_STREAM"
fi
mpc -q repeat on
mpc -q single off
mpc -q consume off
mpc -q play
echo "setup done"
