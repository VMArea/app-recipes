#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"

IMAGE='vaultwarden/server:1.37.4@sha256:2bb2e0344616c62a6d76ea10558497499f8ed3f731400e143dc7bf17b757b5b9'
APP_DIR=/opt/vaultwarden
TOKEN_FILE="$VM_SECRETS_DIR/vaultwarden_admin_token"
HASH_FILE="$VM_SECRETS_DIR/vaultwarden_admin_token_hash"

vm_log "installing Docker Engine $VM_DOCKER_VERSION"
vm_install_docker
vm_apt_install argon2
vm_enable_unattended_security_updates

admin_token=$(vm_rotating_secret vaultwarden_admin_token 48)

if [ ! -s "$HASH_FILE" ] || [ "$TOKEN_FILE" -nt "$HASH_FILE" ]; then
  salt=$(vm_random 16)
  (umask 077; printf '%s' "$admin_token" | argon2 "$salt" -id -t 3 -m 16 -p 4 -l 32 -e >"$HASH_FILE.tmp" && mv "$HASH_FILE.tmp" "$HASH_FILE")
fi
admin_hash=$(cat "$HASH_FILE")
# shellcheck disable=SC2016
case "$admin_hash" in '$argon2id$'*) ;; *) vm_die "admin token hash was not produced" ;; esac

if [ -n "${VMAREA_DOMAIN:-}" ]; then
  host="$VMAREA_DOMAIN"
else
  host="$(vm_public_ip)"
fi

install -d -m 0700 "$APP_DIR"
(umask 077; cat >"$APP_DIR/vaultwarden.env" <<ENV
DOMAIN=https://$host
SIGNUPS_ALLOWED=false
INVITATIONS_ALLOWED=true
SHOW_PASSWORD_HINT=false
ADMIN_TOKEN='$admin_hash'
ENV
)
cat >"$APP_DIR/docker-compose.yml" <<YML
services:
  vaultwarden:
    image: $IMAGE
    restart: unless-stopped
    env_file:
      - vaultwarden.env
    ports:
      - "127.0.0.1:8080:80"
    volumes:
      - vw_data:/data
volumes:
  vw_data:
YML
chmod 0600 "$APP_DIR/docker-compose.yml"

vm_log "starting Vaultwarden"
vm_compose_up "$APP_DIR"
vm_wait_http http://127.0.0.1:8080/alive 90 || vm_die "Vaultwarden did not start"

vm_caddy_proxy 127.0.0.1:8080 https-ip

vm_output url "$(vm_base_url https)"
vm_output adminToken "$admin_token"
vm_log "Vaultwarden is ready"
