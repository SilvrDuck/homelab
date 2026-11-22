# Cobalt

Self-hosted [cobalt](https://github.com/imputnet/cobalt) media downloader.

- **Web UI** — `cobalt-web`, built from source (upstream ships only a Cloudflare
  Pages build, no image), served at `https://cobalt.thvi.ch`.
- **API** — `cobalt-api` (`ghcr.io/imputnet/cobalt:11`) at `https://api.cobalt.thvi.ch`.

The web UI is a static SPA that calls the API from the browser, so the two run on
separate hostnames. The API's URL is baked into the web build (`WEB_DEFAULT_API`),
so changing it requires a rebuild (`docker compose build cobalt-web`).

Downloads that need muxing — `auto` on YouTube, plus `audio`, `mute`, `remux` and
`gif` — are processed in the browser by `libav.wasm`, which only runs in a
cross-origin-isolated document. `nginx.conf` supplies the COOP/COEP headers that
upstream gets from the build's Cloudflare-Pages-only `_headers` file.

## Access control

The instance is internet-facing and protected with **Cloudflare Turnstile**:
`API_AUTH_REQUIRED=1` forces every download request to carry a Turnstile-issued
JWT. The browser UI solves the challenge transparently; non-browser clients
(mobile/desktop apps, scripts) cannot obtain a token and are therefore blocked.

The web UI discovers the Turnstile sitekey from the API's public info endpoint,
so the key is only configured on the API — not in the web build.

## Prerequisites

1. **DNS** — add a record for `api.cobalt.thvi.ch` pointing at the same host as
   `cobalt.thvi.ch` (Traefik issues both certs via the Infomaniak DNS challenge).
2. **Cloudflare Turnstile widget** — at
   [dash.cloudflare.com → Turnstile](https://dash.cloudflare.com/?to=/:account/turnstile),
   create an **Invisible** widget with domain `cobalt.thvi.ch` and pre-clearance
   **off**: the hostname resolves straight to Traefik, so a pre-clearance widget
   would try to redeem clearance against a `/cdn-cgi/` endpoint that does not
   exist here. Copy the **sitekey** and **secret** into `.env` as
   `COBALT_TURNSTILE_SITEKEY` / `COBALT_TURNSTILE_SECRET`.
3. **JWT secret** — `openssl rand -hex 32` into `COBALT_JWT_SECRET`.

## Deploy

```bash
docker compose up -d --build cobalt-api cobalt-web
```

To pull a newer web frontend later, rebuild without cache:

```bash
docker compose build --no-cache cobalt-web && docker compose up -d cobalt-web
```
