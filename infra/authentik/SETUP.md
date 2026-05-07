# Authentik setup runbook

Manual setup steps. Re-run any time the Authentik database is reset or you stand up a new homelab. Will be replaced by IaC eventually; until then, this is the source of truth.

The compose definition lives in `infra/compose.yaml` (services `authentik-{postgresql,redis,server,worker}`). Forward-auth middleware and `obsidian-insecure` serversTransport live in `config/traefik/dynamic/authentik.yml`.

---

## Part 1 — Deploy

### Prerequisites
- DNS: `auth.thvi.ch` resolves to the homelab public IP (Infomaniak-managed).
- `web` external Docker network exists (created by `scripts/setup_networking.sh`).
- Traefik is running and watching `config/traefik/dynamic/`.

### .env entries
```env
PUBLIC_URL_AUTHENTIK=auth.thvi.ch
AUTHENTIK_PG_PASS=<openssl rand -base64 36 | tr -d '\n'>
AUTHENTIK_SECRET_KEY=<openssl rand -base64 60 | tr -d '\n'>
```

Generate fresh values with:
```bash
echo "AUTHENTIK_PG_PASS=$(openssl rand -base64 36 | tr -d '\n')" >> .env
echo "AUTHENTIK_SECRET_KEY=$(openssl rand -base64 60 | tr -d '\n')" >> .env
```

### Runtime directories
Created on first `docker compose up`; `.gitignore` covers them:
```
infra/authentik/database/
infra/authentik/redis/
infra/authentik/media/
infra/authentik/custom-templates/   # tracked in git, empty by default
```

### Bring up
```bash
docker compose up -d authentik-postgresql authentik-redis
# wait for both to report healthy
docker compose ps | grep authentik

docker compose up -d authentik-server authentik-worker
docker compose logs -f authentik-server   # wait for "running"
```

`authentik-server` takes ~30s to migrate the DB on first boot. Healthcheck flips to `healthy` once HTTP endpoint responds.

---

## Part 2 — Initial admin

1. Open `https://auth.thvi.ch/if/flow/initial-setup/` from any browser.
2. Set a strong password for `akadmin`. Store in a password manager **and** somewhere offline (recovery scenario).
3. You're now in the admin UI at `/if/admin/`.

---

## Part 3 — Blueprint applies the rest

Most of what used to be manual UI clicking is now declared in
`infra/authentik/blueprints/obsidian-stack.yaml` and auto-applied on
authentik-server boot. Specifically the blueprint creates / updates:

- Group `notes-users`
- TOTP-only MFA validation on `default-authentication-mfa-validation` (with `last_auth_threshold=days=7`)
- Session duration `weeks=1`, remember-me `weeks=4` on `default-authentication-login`
- Obsidian proxy provider in forward-auth single-app mode (external host `https://obsidian.thvi.ch`)
- Obsidian application bound to `notes-users`
- Auto-attach of the provider to the embedded outpost (Authentik does this whenever a proxy provider is created)

To add another protected app, copy the blueprint, change the `provider-` and
`app-` ids and the external host. Drop the new file in
`infra/authentik/blueprints/`. It's loaded automatically.

To verify the blueprint applied, check the worker log right after boot:

```bash
docker compose logs authentik-worker | grep -E 'blueprint|obsidian'
# expect: "Applying blueprint due to changed file"
#         "Provider changed, rebuilding permissions and sending update"
#         "Task finished, exc: null"
```

If the blueprint *fails* to apply, fall back to the manual UI steps in the
appendix at the bottom of this doc.

---

## Part 4 — User TOTP enrollment (manual, per user)

The blueprint can't enroll your phone for you.

1. Add yourself to `notes-users`: **Directory → Users → akadmin → Groups → add `notes-users`**.
2. Log out of `auth.thvi.ch`, log back in.
3. The flow detects you have no TOTP device and runs the configuration stage —
   scan the QR with your authenticator app, enter the 6-digit code.
4. From now on, every login on a device that's outside the `days=7` re-prompt
   threshold will ask for the 6-digit code.

---

## Part 5 — Per-application Traefik labels

Add to the protected service's labels:

```yaml
- "traefik.http.routers.<svc>.middlewares=authentik@file"

# Required for single-app mode: the outpost endpoint must be reachable
# on the SAME hostname, WITHOUT the auth middleware:
- "traefik.http.routers.<svc>-outpost.rule=Host(`<svc>.thvi.ch`) && PathPrefix(`/outpost.goauthentik.io/`)"
- "traefik.http.routers.<svc>-outpost.entrypoints=websecure"
- "traefik.http.routers.<svc>-outpost.tls.certresolver=myresolver"
- "traefik.http.routers.<svc>-outpost.service=authentik@docker"
```

The outpost router has no auth middleware — without it, you get an infinite redirect loop.

See `apps/compose.yaml` (obsidian service) for the full working example.

---

## Recovery scenarios

### Lost TOTP device, still have password access via another session
- Log in as akadmin from any still-authenticated browser.
- **Directory → Users → <user> → Authenticators tab** → delete the TOTP device.
- User re-enrolls on next login.

### Lost akadmin access entirely
The recovery key created during initial setup is the escape hatch. If you don't have it:
```bash
# create a recovery token from inside the worker container
docker compose exec authentik-worker ak create_recovery_key 24 akadmin
# prints a URL, valid 24 hours, that bypasses MFA
```

### Postgres data loss
Database lives at `infra/authentik/database/`. Restore from backup, then `docker compose up -d authentik-postgresql authentik-redis authentik-server authentik-worker`. All users, TOTP enrollments, app/provider config are in the DB.

### Outpost not picking up a new app
- **Applications → Outposts → Embedded Outpost → View Logs** — check for errors.
- Restart with `docker compose restart authentik-server` (embedded outpost runs in the server container).

---

## Appendix — Manual fallback if the blueprint fails

If `docker compose logs authentik-worker` shows the blueprint task ended with
an exception, you can do everything by hand:

### a) TOTP setup stage (already exists by default — `default-authenticator-totp-setup`)

### b) Edit MFA validation
**Flows and Stages → Stages → `default-authentication-mfa-validation`**
- Device classes: **TOTP** only
- Not configured action: `Configure`
- Configuration stages: `default-authenticator-totp-setup`
- Last validation threshold: `days=7`

### c) Edit User Login
**Flows and Stages → Stages → `default-authentication-login`**
- Session duration: `weeks=1`
- Remember me offset: `weeks=4`

### d) Group
**Directory → Groups → Create** → `notes-users`.

### e) Provider
**Applications → Providers → Create**
- Type: `Proxy Provider`, Name: `Obsidian Proxy`
- Authentication flow: `default-authentication-flow`
- Authorization flow: `default-provider-authorization-implicit-consent`
- Mode: **Forward auth (single application)**
- External host: `https://obsidian.thvi.ch`

### f) Application
**Applications → Applications → Create**
- Name: `Obsidian`, Slug: `obsidian`
- Provider: `Obsidian Proxy`
- Launch URL: `https://obsidian.thvi.ch`

Then **Policy / Group / User Bindings → Bind existing** → group `notes-users`.

### g) Outpost
**Applications → Outposts → authentik Embedded Outpost → Edit** → add `Obsidian` to Applications.
