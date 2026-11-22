# Backup

Daily restic backup to Google Drive (via rclone) of:

- `/mnt/apps` — every service's config and database (Radarr, Sonarr, Prowlarr,
  Jellyfin, Jellyseerr, qBittorrent, Cleanuparr, …). Restoring this folder
  restores the services as they were.
- `/mnt/media/obsidian/vaults` — the Obsidian vault.

Runs on the LXC host as a systemd timer (03:30), not in a container.
Retention: 14 daily, 8 weekly, 12 monthly, 5 yearly. Each run also reads back
5% of the repository to catch corruption.

| File | Role |
|---|---|
| `backup.sh` | restic backup + forget + partial check |
| `backup.service` | systemd unit, runs `backup.sh` as `tibo` |
| `backup.timer` | daily 03:30 trigger |
| `backup.env.dist` | template for `/etc/homelab-backup.env` |
| `../../scripts/setup_backup.sh` | installs restic/rclone and the units |
| `../../scripts/verify_backup_restore.sh` | restore drill |

## Setup

```bash
sudo ./scripts/setup_backup.sh
```

That installs `restic` and `rclone` via apt, drops the systemd unit + timer
into `/etc/systemd/system/`, and seeds `/etc/homelab-backup.env` from the
template. Then:

1. **rclone config** (as user `tibo`, interactive — opens a browser for Google Drive OAuth):
   ```bash
   rclone config
   # n)ew remote, name: gdrive, storage: drive, scope: drive, leave the rest default
   # auto-config: y on a desktop, n if running over SSH (paste auth URL into a local browser)
   ```
2. **Edit `/etc/homelab-backup.env`** with sudo:
   - Set `RESTIC_PASSWORD` to a fresh value (`openssl rand -base64 32`). Save it in a password manager too — losing it means the backups are unrecoverable.
   - Adjust `RESTIC_REPOSITORY` if you used a remote name other than `gdrive`.
3. **Initialise the restic repo** (one-time):
   ```bash
   sudo systemd-run --wait --pipe --uid=tibo --gid=tibo \
     --property=EnvironmentFile=/etc/homelab-backup.env \
     /usr/bin/restic init
   ```
4. **Test a backup**:
   ```bash
   sudo systemctl start homelab-backup.service
   sudo journalctl -u homelab-backup.service -f
   ```
5. **Enable the daily timer**:
   ```bash
   sudo systemctl enable --now homelab-backup.timer
   sudo systemctl list-timers homelab-backup.timer
   ```

## Restore

Drill (quarterly): restores the latest snapshot to a temp dir and compares file
counts with the live data.

```bash
sudo ./scripts/verify_backup_restore.sh
KEEP_TEMP=1 sudo ./scripts/verify_backup_restore.sh   # keep the restore for inspection
```

Real restore of the service configs, with the stack stopped:

```bash
docker compose down
sudo systemd-run --wait --pipe --uid=tibo --gid=tibo \
  --property=EnvironmentFile=/etc/homelab-backup.env \
  /usr/bin/restic restore latest --target / --include /mnt/apps
docker compose up -d
```
