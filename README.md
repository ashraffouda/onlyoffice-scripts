# ONLYOFFICE Community Server — Self-Hosted Deployment

Production-structured, single-host deployment of [ONLYOFFICE Community Server](https://github.com/ONLYOFFICE/CommunityServer) + Document Server, fronted by Caddy with automatic HTTPS.

## Stack

| Service | Image | Purpose |
|---|---|---|
| `communityserver` | `onlyoffice/communityserver:latest` | Portal (CRM, projects, mail, documents UI) |
| `documentserver` | `onlyoffice/documentserver:latest` | Online editors (docx/xlsx/pptx) |
| `mysql` | `mysql:8.0` | Primary database |
| `redis` | `redis:7-alpine` | Cache / sessions |
| `caddy` | `caddy:2-alpine` | Reverse proxy, TLS, WebSockets |

All services run on a private Docker bridge network. Only Caddy (80/443) and the XMPP port (5222) are exposed to the host.

## Quick start

```bash
chmod +x setup.sh
sudo ./setup.sh
```

The script is idempotent: re-running it re-generates config where safe, pulls latest images, and restarts the stack. Existing secrets in `.env` are preserved.

### Custom domain / public host

```bash
sudo ONLYOFFICE_DOMAIN=office.example.com \
     ADMIN_EMAIL=you@example.com \
     USE_LOCAL_CERTS=false \
     ./setup.sh
```

- `USE_LOCAL_CERTS=true` (default) → Caddy self-signed CA (good for `*.localhost`).
- `USE_LOCAL_CERTS=false` → real Let's Encrypt cert (domain must resolve to this host).

## What the script does

```
install_docker      # docker + compose plugin via get.docker.com
install_caddy       # host-side caddy cli (optional helper)
generate_configs    # .env (secrets), docker-compose.yml, Caddyfile
start_services      # docker compose pull && up -d
```

All secrets (`MYSQL_*`, `REDIS_PASSWORD`, `JWT_SECRET`) are generated with `openssl rand -hex 32` on first run and stored in `.env` (mode 600).

## Files

- [setup.sh](setup.sh) — one-shot deployer
- [docker-compose.yml](docker-compose.yml) — the stack
- [Caddyfile](Caddyfile) — reverse proxy + TLS
- [.env.example](.env.example) — template (real `.env` is generated)

## First-time configuration

1. Open `https://<ONLYOFFICE_DOMAIN>` — the portal wizard asks for admin email + password.
2. In the portal: **Settings → Integration → Document Service**
   - Document Service address: `https://<ONLYOFFICE_DOMAIN>/ds-vpath/`
   - Internal address: `http://documentserver/`
   - Community Server address: `http://communityserver/`
   - JWT secret: value of `JWT_SECRET` from `.env`

## Security

- **TLS** via Caddy (internal CA for local, Let's Encrypt otherwise).
- **JWT** enforced between Community Server and Document Server — neither accepts unsigned requests.
- **Basic auth** (optional): generate `caddy hash-password`, add `BASIC_AUTH_HASH` to `.env`, uncomment the `basicauth` block in `Caddyfile`.
- MySQL and Redis are not reachable from the host network.

## Operations

```bash
docker compose logs -f communityserver    # tail CS logs
docker compose ps                          # service state
docker compose restart communityserver    # restart one service
docker compose down                        # stop (keeps data)
docker compose down -v                     # nuke everything (data loss!)
```

First boot takes 2–5 min while Community Server runs DB migrations.

## Troubleshooting

| Symptom | Fix |
|---|---|
| CS stuck `starting` | Normal for first ~3 min. Watch `docker compose logs -f communityserver`. |
| "Download failed" in editor | JWT mismatch — `JWT_SECRET` must match in CS and DS env blocks. |
| Editor blank / WS errors | Ensure nothing fronts Caddy that strips `Upgrade` headers. |
| MySQL auth errors | Keep `--default-authentication-plugin=mysql_native_password`. |
| Self-signed cert rejected | `sudo caddy trust` on host, or import from `caddy_data` volume. |
| Port 80/443 in use | `ss -ltnp \| grep -E ':80\|:443'` — stop the other service. |

## License

Configuration files in this directory: MIT. ONLYOFFICE itself is AGPLv3 — see upstream.
