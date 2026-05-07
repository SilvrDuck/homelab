# Obsidian stack setup runbook

Full runbook for the Obsidian + Syncthing + restic-backup stack. Most of the
configuration is declarative (compose files, the Authentik blueprint, the
Syncthing API helper, systemd units). Manual steps are flagged.

## What's in this stack

| Piece | Lives in | Public URL | Auth |
|---|---|---|---|
| Obsidian (LinuxServer container) | `apps/compose.yaml` | `obsidian.thvi.ch` | Authentik forward-auth |
| Syncthing | `apps/compose.yaml` | `syncthing.lan` | Built-in user/pass (LAN-only) |
| restic backup → Google Drive | `apps/obsidian/backup.{sh,service,timer}` | — | rclone OAuth |

Vault data: `/mnt/media/obsidian/vaults/` (matches the qBittorrent media share pattern).
Obsidian app config: `/mnt/apps/obsidian/` (matches `/mnt/apps/qbittorrent/`).

## Requirements before deploy

- DNS: `obsidian.thvi.ch` → homelab public IP. `auth.thvi.ch` already covered by the Authentik stack.
- Authentik already running (see `infra/authentik/SETUP.md`).
- Tailscale on the homelab and on every device that needs to sync.
- `.env` populated:
  ```env
  PUBLIC_URL_OBSIDIAN=obsidian.thvi.ch
  ```

## Deploy

```bash
docker compose up -d obsidian syncthing
```

Forward-auth, group binding, embedded-outpost attachment are all in the Authentik blueprint
(`infra/authentik/blueprints/obsidian-stack.yaml`); they apply on first authentik-server boot.

After Syncthing's first start, converge it to our preferences:

```bash
bash apps/syncthing/configure.sh
```

This sets `globalAnnounceEnabled=false`, `relaysEnabled=false`, adds the
`obsidian-vault` folder pointing at `/sync/obsidian-vault` with trashcan
versioning. Re-runnable.

## Manual: Authentik post-deploy

1. **Initial admin** (one-time only). Open `https://auth.thvi.ch/if/flow/initial-setup/`, set the akadmin password.
2. **Add yourself to `notes-users`**: Directory → Users → akadmin → Groups → add `notes-users`.
3. **Enrol TOTP**: log out, log back in. The flow forces TOTP setup on first login.

Everything else (group, app, provider, group binding, embedded-outpost attachment,
TOTP-required flow, weeks=1 session) comes from the blueprint.

## Manual: Syncthing pairing

GUI is at `http://syncthing.lan` (LAN/Tailscale only). On first visit:

1. Set a GUI username/password under **Actions → Settings → GUI**.
2. The homelab's device ID is shown at the top of the page.
3. On each peer (Mac / Linux / Android with Möbius Sync):
   - Install Syncthing.
   - Add the homelab's device ID as a remote device.
   - Accept the auto-share invite for the `obsidian-vault` folder.
   - Set local sync path (e.g. `~/vaults/main` on Mac).

Tailscale is the transport. Port 22000 is published on the LXC interface but
not router-forwarded; devices must be on the tailnet to sync.

## Manual: backup setup

One-time installer (run as a user with sudo):

```bash
sudo ./scripts/setup_obsidian_backup.sh
```

That installs `restic` and `rclone` via apt, drops the systemd unit + timer
into `/etc/systemd/system/`, and seeds `/etc/obsidian-backup.env` from the
template. It then prints the remaining manual steps:

1. **rclone config** (as user `tibo`, interactive — opens a browser for Google Drive OAuth):
   ```bash
   rclone config
   # n)ew remote, name: gdrive, storage: drive, scope: drive, leave the rest default
   # auto-config: y on a desktop, n if running over SSH (paste auth URL into a local browser)
   ```
2. **Edit `/etc/obsidian-backup.env`** with sudo:
   - Set `RESTIC_PASSWORD` to a fresh value (`openssl rand -base64 32`). Save it in a password manager too — losing it means the backups are unrecoverable.
   - Adjust `RESTIC_REPOSITORY` if you used a remote name other than `gdrive`.
3. **Initialise the restic repo** (one-time):
   ```bash
   sudo systemd-run --wait --pipe --uid=tibo --gid=tibo \
     --property=EnvironmentFile=/etc/obsidian-backup.env \
     /usr/bin/restic init
   ```
4. **Test a backup**:
   ```bash
   sudo systemctl start obsidian-backup.service
   sudo journalctl -u obsidian-backup.service -f
   ```
5. **Enable the daily timer**:
   ```bash
   sudo systemctl enable --now obsidian-backup.timer
   sudo systemctl list-timers obsidian-backup.timer
   ```

### Verify a restore (this is the only test that matters)

```bash
sudo systemd-run --wait --pipe --uid=tibo --gid=tibo \
  --property=EnvironmentFile=/etc/obsidian-backup.env \
  /usr/bin/restic snapshots
# pick a snapshot ID, then:
sudo systemd-run --wait --pipe --uid=tibo --gid=tibo \
  --property=EnvironmentFile=/etc/obsidian-backup.env \
  /usr/bin/restic restore <snapshot-id> --target /tmp/restore-test
diff -r /mnt/media/obsidian/vaults /tmp/restore-test/mnt/media/obsidian/vaults
```

## Concurrency note

The vault is now a directory shared between four-ish writers: the LinuxServer
Obsidian container, native Obsidian on each Syncthing peer, native nvim on each
Syncthing peer. Markdown files are safe under concurrent edits — Syncthing
produces `.sync-conflict-*.md` files when two peers edit the same file
simultaneously, so nothing's lost; you just have to merge.

What's *not* safe: `.obsidian/workspace.json` (Obsidian's window state) churns
constantly and creates noisy conflicts. Add this to the vault root after first
sync:

```
# .stignore
.obsidian/workspace*.json
.obsidian/cache/
```

(Note: that file goes inside the vault and itself gets synced.)

## File map

```
apps/compose.yaml                              # obsidian + syncthing services
apps/obsidian/backup.sh                        # restic backup script
apps/obsidian/backup.service                   # systemd unit
apps/obsidian/backup.timer                     # daily 03:30 timer
apps/obsidian/backup.env.dist                  # template for /etc/obsidian-backup.env
apps/syncthing/configure.sh                    # one-shot REST API converger
config/traefik/dynamic/authentik.yml           # forward-auth middleware (shared with other Authentik-protected apps)
infra/authentik/blueprints/obsidian-stack.yaml # Authentik IaC: group + provider + app + flow tweaks
scripts/setup_obsidian_backup.sh               # sudo installer for restic/rclone/systemd
```
