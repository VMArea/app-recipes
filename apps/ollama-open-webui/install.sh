#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"
umask 022

APP_DIR=/opt/ollama-open-webui
UI_PORT=8080
MODEL=qwen2.5:0.5b
ADMIN_EMAIL=admin@openwebui.local

vm_log "installing Ollama 0.40.11 with Open WebUI v0.12.3"
vm_install_docker
vm_enable_unattended_security_updates

OLD_PASS=""
if [ -s "$VM_SECRETS_DIR/openwebui_admin_password" ]; then
  OLD_PASS=$(cat "$VM_SECRETS_DIR/openwebui_admin_password")
fi
ADMIN_PASS=$(vm_rotating_secret openwebui_admin_password 24)
SECRET_KEY=$(vm_secret openwebui_secret_key 48)

install -d -m 0755 "$APP_DIR"

cat >"$APP_DIR/docker-compose.yml" <<'YML'
services:
  ollama:
    image: ollama/ollama:0.40.11@sha256:dea72d1e22270fe095b68fdf756d2b489d615643c5a2eaebbc5f569181e322d8
    restart: unless-stopped
    environment:
      OLLAMA_HOST: 0.0.0.0:11434
    ports:
      - "127.0.0.1:11434:11434"
    volumes:
      - ollama-data:/root/.ollama
    networks: [internal]
  open-webui:
    image: ghcr.io/open-webui/open-webui:v0.12.3@sha256:a537bbe1e6b428820f52ed4a029d7fff97062e24d5cf32c365fba36fd0542def
    restart: unless-stopped
    depends_on: [ollama]
    env_file: .env
    ports:
      - "127.0.0.1:8080:8080"
    volumes:
      - open-webui-data:/app/backend/data
    networks: [internal]
volumes:
  ollama-data:
  open-webui-data:
networks:
  internal:
YML

(
  umask 077
  {
    printf 'OLLAMA_BASE_URL=http://ollama:11434\n'
    printf 'ENABLE_OPENAI_API=false\n'
    printf 'WEBUI_SECRET_KEY=%s\n' "$SECRET_KEY"
    printf 'ENABLE_SIGNUP=false\n'
    printf 'WEBUI_ADMIN_EMAIL=%s\n' "$ADMIN_EMAIL"
    printf 'WEBUI_ADMIN_PASSWORD=%s\n' "$ADMIN_PASS"
    printf 'WEBUI_ADMIN_NAME=Admin\n'
    printf 'SCARF_NO_ANALYTICS=true\n'
    printf 'DO_NOT_TRACK=true\n'
    printf 'ANONYMIZED_TELEMETRY=false\n'
  } >"$APP_DIR/.env.tmp"
  mv "$APP_DIR/.env.tmp" "$APP_DIR/.env"
)
chmod 0600 "$APP_DIR/.env"

compose() {
  docker compose --project-directory "$APP_DIR" "$@"
}

vm_compose_up "$APP_DIR"
vm_wait_http "http://127.0.0.1:11434/api/version" 90 || vm_die "Ollama did not start"

vm_log "pulling model $MODEL"
vm_retry 4 20 compose exec -T ollama ollama pull "$MODEL" >/dev/null 2>&1 || vm_die "could not pull the $MODEL model"

vm_wait_http "http://127.0.0.1:$UI_PORT/health" 300 || vm_die "Open WebUI did not start"

if [ -n "$OLD_PASS" ] && [ "$OLD_PASS" != "$ADMIN_PASS" ]; then
  python_script=$(cat <<'PY'
import os, sqlite3, bcrypt
db = sqlite3.connect("/app/backend/data/webui.db")
hashed = bcrypt.hashpw(os.environ["NEW_PASS"].encode(), bcrypt.gensalt()).decode()
db.execute("UPDATE auth SET password = ? WHERE email = ?", (hashed, os.environ["ADMIN_EMAIL"]))
db.commit()
raise SystemExit(0 if db.total_changes else 1)
PY
  )
  printf '%s\n' "$python_script" | ADMIN_EMAIL="$ADMIN_EMAIL" NEW_PASS="$ADMIN_PASS" \
    compose exec -T -e ADMIN_EMAIL -e NEW_PASS open-webui python - >/dev/null 2>&1 || vm_die "could not rotate the Open WebUI admin password"
  vm_log "admin password rotated"
fi

vm_caddy_proxy "127.0.0.1:$UI_PORT" https-ip

vm_output url "$(vm_base_url https)"
vm_output adminEmail "$ADMIN_EMAIL"
vm_output adminPassword "$ADMIN_PASS"
vm_log "Ollama and Open WebUI are ready"
