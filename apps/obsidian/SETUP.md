# Obsidian stack setup runbook

Full runbook for the Obsidian + Syncthing stack. Most of the
configuration is declarative (compose files, the Authentik blueprint, the
Syncthing API helper, systemd units). Manual steps are flagged.

## What's in this stack

| Piece | Lives in | Public URL | Auth |
|---|---|---|---|
| Obsidian (LinuxServer container) | `apps/compose.yaml` | `obsidian.thvi.ch` | Authentik forward-auth |
| Syncthing | `apps/compose.yaml` | `syncthing.lan` | Built-in user/pass (LAN-only) |
| restic backup → Google Drive | `infra/backup/` | — | rclone OAuth |

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

This sets `globalAnnounceEnabled=false` (peers must be added by device ID,
no anonymous discovery), `relaysEnabled=true` (public relays as a fallback
for off-LAN/off-tailnet peers), `natEnabled=false`, declines usage reports,
and adds the `obsidian-vault` folder pointing at `/sync/obsidian-vault` with
trashcan versioning. Re-runnable.

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
3. On each peer:
   - Mac / Linux: install Syncthing (Homebrew / pacman / package manager).
   - iOS: Möbius Sync (paid, App Store).
   - Android: Syncthing-Fork (free, Play Store / F-Droid).
   - Add the homelab's device ID as a remote device.
   - Accept the auto-share invite for the `obsidian-vault` folder.
   - Set local sync path (e.g. `~/vaults/main` on Mac).

Connectivity:
- **Same LAN as homelab** — peers auto-discover via UDP 21027 multicast and
  connect direct on TCP 22000.
- **On the tailnet** — peers reach the homelab on its tailnet IP at TCP 22000.
- **Anywhere else** — falls back through Syncthing's public relay pool. Slower
  than direct, but secure: traffic is end-to-end TLS, the relay only sees
  ciphertext between two device IDs. Requires no router port forward.

Port 22000 is published on the LXC interface but not router-forwarded, so
inbound direct connections from the public internet won't work — relayed
connections will.

## Backup

The vault and the Obsidian config are part of the homelab-wide restic backup;
see `infra/backup/README.md` for setup and restores.

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
apps/syncthing/configure.sh                    # one-shot REST API converger
config/traefik/dynamic/authentik.yml           # forward-auth middleware (shared with other Authentik-protected apps)
infra/authentik/blueprints/obsidian-stack.yaml # Authentik IaC: group + provider + app + flow tweaks
```
