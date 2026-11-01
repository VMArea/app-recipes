#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"
umask 022

APP_DIR=/opt/anythingllm
APP_PORT=3001
APP_UID=1000

vm_log "installing AnythingLLM 1.18.0"
vm_install_docker
vm_enable_unattended_security_updates

ACCESS_PASS=$(vm_rotating_secret anythingllm_access_password 24)
JWT_SECRET=$(vm_rotating_secret anythingllm_jwt_secret 48)
SIG_KEY=$(vm_secret anythingllm_sig_key 48)
SIG_SALT=$(vm_secret anythingllm_sig_salt 48)

install -d -m 0755 "$APP_DIR"
install -d -m 0750 -o "$APP_UID" -g "$APP_UID" "$APP_DIR/storage"

cat >"$APP_DIR/docker-compose.yml" <<'YML'
services:
  anythingllm:
    image: mintplexlabs/anythingllm:1.18.0@sha256:5461782e7db41318a516925949a8f8366e258dd576411fca7961fe77dff054cc
    restart: unless-stopped
    user: "1000:1000"
    environment:
      STORAGE_DIR: /app/server/storage
    volumes:
      - ./storage:/app/server/storage
      - ./app.env:/app/server/.env
    ports:
      - "127.0.0.1:3001:3001"
YML

ENV_FILE="$APP_DIR/app.env"
(
  umask 077
  if [ -f "$ENV_FILE" ]; then
    grep -v -E '^(AUTH_TOKEN|JWT_SECRET|SIG_KEY|SIG_SALT|DISABLE_TELEMETRY|STORAGE_DIR)=' "$ENV_FILE" >"$ENV_FILE.tmp" || true
  else
    : >"$ENV_FILE.tmp"
  fi
  {
    printf 'STORAGE_DIR="/app/server/storage"\n'
    printf 'DISABLE_TELEMETRY="true"\n'
    printf 'AUTH_TOKEN="%s"\n' "$ACCESS_PASS"
    printf 'JWT_SECRET="%s"\n' "$JWT_SECRET"
    printf 'SIG_KEY="%s"\n' "$SIG_KEY"
    printf 'SIG_SALT="%s"\n' "$SIG_SALT"
  } >>"$ENV_FILE.tmp"
  mv "$ENV_FILE.tmp" "$ENV_FILE"
)
chown "$APP_UID:$APP_UID" "$ENV_FILE"
chmod 0600 "$ENV_FILE"

vm_compose_up "$APP_DIR"
if [ "${VMAREA_RUN_PURPOSE:-FIRST_RUN}" != "FIRST_RUN" ]; then
  docker compose --project-directory "$APP_DIR" restart anythingllm >/dev/null
fi
vm_wait_http "http://127.0.0.1:$APP_PORT/api/ping" 240 || vm_die "AnythingLLM did not start"

vm_caddy_proxy "127.0.0.1:$APP_PORT" https-ip

vm_output url "$(vm_base_url https)"
vm_output adminPassword "$ACCESS_PASS"
vm_log "AnythingLLM is ready"
