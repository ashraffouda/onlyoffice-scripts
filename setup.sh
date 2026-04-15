#!/usr/bin/env bash
#
# ONLYOFFICE Community Server — one-shot deployer.
# Idempotent: safe to re-run.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# -------- config (override via env) --------
: "${ONLYOFFICE_DOMAIN:=onlyoffice.localhost}"
: "${ADMIN_EMAIL:=admin@${ONLYOFFICE_DOMAIN}}"
: "${USE_LOCAL_CERTS:=true}"   # true = self-signed via Caddy's internal CA

ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
CADDY_FILE="${SCRIPT_DIR}/Caddyfile"

log()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; }
trap 'err "failed at line $LINENO"' ERR

require_root() {
  if [[ $EUID -ne 0 ]]; then
    warn "re-exec with sudo"
    exec sudo -E bash "$0" "$@"
  fi
}

install_docker() {
  if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
    log "docker + compose already installed"
    return
  fi
  log "installing docker"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
}

install_caddy() {
  # Caddy runs in Docker; host CLI is useful for `caddy hash-password` / `caddy trust`.
  if command -v caddy >/dev/null; then
    log "caddy cli already installed"
    return
  fi
  log "installing caddy cli (optional helper)"
  apt-get update -y
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
    | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
    | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  apt-get update -y
  apt-get install -y caddy
  systemctl disable --now caddy || true
}

gen_secret() { openssl rand -hex 32; }

generate_env() {
  if [[ -f "$ENV_FILE" ]]; then
    log ".env already exists — keeping existing secrets"
    return
  fi
  log "generating .env"
  cat > "$ENV_FILE" <<EOF
# generated $(date -Iseconds)
ONLYOFFICE_DOMAIN=${ONLYOFFICE_DOMAIN}
ADMIN_EMAIL=${ADMIN_EMAIL}

MYSQL_ROOT_PASSWORD=$(gen_secret)
MYSQL_PASSWORD=$(gen_secret)
REDIS_PASSWORD=$(gen_secret)
JWT_SECRET=$(gen_secret)
EOF
  chmod 600 "$ENV_FILE"
}

generate_compose() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    log "docker-compose.yml already present — overwriting"
  fi
  log "writing docker-compose.yml"
  cat > "$COMPOSE_FILE" <<'YAML'
name: onlyoffice

networks:
  onlyoffice:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/16

volumes:
  cs_data:
  cs_logs:
  cs_letsencrypt:
  ds_data:
  ds_logs:
  ds_cache:
  mysql_data:
  redis_data:
  caddy_data:
  caddy_config:

services:
  mysql:
    image: mysql:5.7
    container_name: onlyoffice-mysql
    restart: unless-stopped
    command: >
      --character-set-server=utf8
      --collation-server=utf8_general_ci
      --max_connections=1000
      --max_allowed_packet=1048576000
      --group_concat_max_len=2048
      --log-bin-trust-function-creators=1
      --sql_mode=NO_ENGINE_SUBSTITUTION
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: onlyoffice
      MYSQL_USER: onlyoffice
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    volumes:
      - mysql_data:/var/lib/mysql
    networks:
      onlyoffice:
        ipv4_address: 172.28.0.10
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    container_name: onlyoffice-redis
    restart: unless-stopped
    command: ["redis-server", "--appendonly", "yes", "--requirepass", "${REDIS_PASSWORD}"]
    volumes:
      - redis_data:/data
    networks:
      onlyoffice:
        ipv4_address: 172.28.0.11
    healthcheck:
      test: ["CMD-SHELL", "redis-cli -a \"$REDIS_PASSWORD\" ping | grep -q PONG"]
      interval: 10s
      timeout: 5s
      retries: 10

  documentserver:
    image: onlyoffice/documentserver:latest
    container_name: onlyoffice-documentserver
    restart: unless-stopped
    environment:
      JWT_ENABLED: "true"
      JWT_SECRET: ${JWT_SECRET}
      JWT_HEADER: "AuthorizationJwt"
      JWT_IN_BODY: "true"
    volumes:
      - ds_data:/var/www/onlyoffice/Data
      - ds_logs:/var/log/onlyoffice
      - ds_cache:/var/lib/onlyoffice/documentserver/App_Data/cache/files
    networks:
      onlyoffice:
        ipv4_address: 172.28.0.12
    expose: ["80"]
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5

  communityserver:
    image: onlyoffice/communityserver:latest
    container_name: onlyoffice-communityserver
    restart: unless-stopped
    depends_on:
      mysql: { condition: service_healthy }
      redis: { condition: service_healthy }
      documentserver: { condition: service_started }
    environment:
      MYSQL_SERVER_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_SERVER_DB_NAME: onlyoffice
      MYSQL_SERVER_HOST: 172.28.0.10
      MYSQL_SERVER_PORT: "3306"
      MYSQL_SERVER_USER: onlyoffice
      MYSQL_SERVER_PASS: ${MYSQL_PASSWORD}
      REDIS_SERVER_HOST: 172.28.0.11
      REDIS_SERVER_PORT: "6379"
      REDIS_SERVER_DB_NUMBER: "0"
      REDIS_SERVER_PASSWORD: ${REDIS_PASSWORD}
      DOCUMENT_SERVER_PORT_80_TCP_ADDR: 172.28.0.12
      DOCUMENT_SERVER_JWT_ENABLED: "true"
      DOCUMENT_SERVER_JWT_SECRET: ${JWT_SECRET}
      DOCUMENT_SERVER_JWT_HEADER: "AuthorizationJwt"
    volumes:
      - cs_data:/var/www/onlyoffice/Data
      - cs_logs:/var/log/onlyoffice
      - cs_letsencrypt:/etc/letsencrypt
    networks:
      onlyoffice:
        ipv4_address: 172.28.0.13
    expose: ["80", "443", "5222"]
    ports:
      - "5222:5222"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost/"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 180s

  caddy:
    image: caddy:2-alpine
    container_name: onlyoffice-caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      ONLYOFFICE_DOMAIN: ${ONLYOFFICE_DOMAIN}
      ADMIN_EMAIL: ${ADMIN_EMAIL}
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [onlyoffice]
    depends_on:
      - communityserver
      - documentserver
YAML
}

generate_caddyfile() {
  log "writing Caddyfile (local_certs=${USE_LOCAL_CERTS})"
  local tls_block=""
  if [[ "$USE_LOCAL_CERTS" == "true" ]]; then
    tls_block=$'\n    tls internal'
  fi
  cat > "$CADDY_FILE" <<EOF
{
    email {\$ADMIN_EMAIL}
}

{\$ONLYOFFICE_DOMAIN} {${tls_block}
    encode gzip zstd

    # Document Server under /ds-vpath/
    handle_path /ds-vpath/* {
        reverse_proxy 172.28.0.12:80 {
            header_up Host {host}
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-Proto {scheme}
            header_up X-Real-IP {remote_host}
        }
    }

    # Community Server (default)
    handle {
        reverse_proxy 172.28.0.13:80 {
            header_up Host {host}
            header_up X-Forwarded-Host {host}
            header_up X-Forwarded-Proto {scheme}
            header_up X-Real-IP {remote_host}
        }
    }

    header {
        Strict-Transport-Security "max-age=31536000;"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF
}

generate_configs() {
  generate_env
  generate_compose
  generate_caddyfile
}

start_services() {
  log "pulling images"
  docker compose --env-file "$ENV_FILE" pull
  log "starting stack"
  docker compose --env-file "$ENV_FILE" up -d
}

print_summary() {
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  cat <<EOF

────────────────────────────────────────────────────
 ONLYOFFICE is starting. First boot takes 2–5 min.

 URL       : https://${ONLYOFFICE_DOMAIN}
 Admin     : set via the web wizard on first visit
 JWT secret: stored in ${ENV_FILE}

 Logs      : docker compose logs -f communityserver
 Stop      : docker compose down
 Reset     : docker compose down -v   (deletes data!)
────────────────────────────────────────────────────
EOF
}

main() {
  require_root "$@"
  install_docker
  install_caddy
  generate_configs
  start_services
  print_summary
}

main "$@"
