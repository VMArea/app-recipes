#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"

IMAGE='gitea/gitea:28.2.0@sha256:d154aee25ff14e9545e3e32ccbcf0c1bfd5654d12fb513f52d242e9202687d32'
APP_DIR=/opt/gitea
ADMIN_USER='gitadmin'
ADMIN_EMAIL=gitadmin@example.com

vm_log "installing Docker Engine $VM_DOCKER_VERSION"
vm_install_docker
vm_enable_unattended_security_updates

admin_password=$(vm_rotating_secret gitea_admin_password 24)
secret_key=$(vm_secret gitea_secret_key 64)

if [ -n "${VMAREA_DOMAIN:-}" ]; then
  host="$VMAREA_DOMAIN"
else
  host="$(vm_public_ip)"
fi

install -d -m 0700 "$APP_DIR"
cat >"$APP_DIR/docker-compose.yml" <<YML
services:
  gitea:
    image: $IMAGE
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - gitea_data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      USER_UID: "1000"
      USER_GID: "1000"
      GITEA__database__DB_TYPE: sqlite3
      GITEA__security__INSTALL_LOCK: "true"
      GITEA__security__SECRET_KEY: "$secret_key"
      GITEA__server__DOMAIN: "$host"
      GITEA__server__ROOT_URL: "https://$host/"
      GITEA__server__HTTP_PORT: "3000"
      GITEA__server__DISABLE_SSH: "true"
      GITEA__service__DISABLE_REGISTRATION: "true"
      GITEA__service__REQUIRE_SIGNIN_VIEW: "false"
      GITEA__service__ENABLE_NOTIFY_MAIL: "false"
      GITEA__openid__ENABLE_OPENID_SIGNUP: "false"
      GITEA__other__SHOW_FOOTER_VERSION: "false"
volumes:
  gitea_data:
YML
chmod 0600 "$APP_DIR/docker-compose.yml"

vm_log "starting Gitea"
vm_compose_up "$APP_DIR"
vm_wait_http http://127.0.0.1:3000/api/healthz 120 || vm_die "Gitea did not start"

gitea_cli() {
  docker compose --project-directory "$APP_DIR" exec -T -u git gitea gitea "$@"
}

vm_log "configuring the administrator account"
users=$(gitea_cli admin user list --admin 2>/dev/null || true)
if case "$users" in *"$ADMIN_USER"*) true ;; *) false ;; esac; then
  gitea_cli admin user change-password --username "$ADMIN_USER" --password "$admin_password" --must-change-password=false >/dev/null
else
  gitea_cli admin user create --admin --username "$ADMIN_USER" --email "$ADMIN_EMAIL" --password "$admin_password" --must-change-password=false >/dev/null
fi

vm_caddy_proxy 127.0.0.1:3000 https-ip

vm_output url "$(vm_base_url https)"
vm_output adminUser "$ADMIN_USER"
vm_output adminPassword "$admin_password"
vm_log "Gitea is ready"
