#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"

IMAGE='portainer/portainer-ce:2.45.3@sha256:1c9fd7e7a19941c15bec2c915298a5c95c7d2fab9882772bdb4dbe57a4d019f1'
APP_DIR=/opt/portainer
ADMIN_USER='admin'
PASSWORD_FILE="$VM_SECRETS_DIR/portainer_admin_password"

vm_log "installing Docker Engine $VM_DOCKER_VERSION"
vm_install_docker
vm_enable_unattended_security_updates

old_password=""
if vm_is_regenerate && [ -s "$PASSWORD_FILE" ]; then
  old_password=$(cat "$PASSWORD_FILE")
fi
admin_password=$(vm_rotating_secret portainer_admin_password 24)

install -d -m 0700 "$APP_DIR"
cat >"$APP_DIR/docker-compose.yml" <<YML
services:
  portainer:
    image: $IMAGE
    restart: unless-stopped
    command:
      - --http-enabled
      - --admin-password-file
      - /run/secrets/portainer-admin-password
    ports:
      - "127.0.0.1:9000:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - portainer_data:/data
      - $PASSWORD_FILE:/run/secrets/portainer-admin-password:ro
volumes:
  portainer_data:
YML
chmod 0600 "$APP_DIR/docker-compose.yml"

vm_log "starting Portainer CE"
vm_compose_up "$APP_DIR"
vm_wait_http http://127.0.0.1:9000/api/system/status 120 || vm_die "Portainer did not start"

vm_log "confirming the administrator credential"
OLD_PW="$old_password" NEW_PW="$admin_password" ADMIN_USER="$ADMIN_USER" python3 - <<'PY'
import json, os, sys, time, urllib.request, urllib.error

BASE = "http://127.0.0.1:9000/api"


def call(method, path, body=None, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(BASE + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as err:
        return err.code, {}


def login(user, password):
    for _ in range(10):
        status, body = call("POST", "/auth", {"username": user, "password": password})
        if status == 200 and body.get("jwt"):
            return body["jwt"]
        if status in (401, 422):
            return None
        time.sleep(3)
    return None


user = os.environ["ADMIN_USER"]
new = os.environ["NEW_PW"]
old = os.environ.get("OLD_PW", "")

if login(user, new):
    sys.exit(0)
if old:
    token = login(user, old)
    if token:
        status, _ = call("PUT", "/users/1/passwd", {"password": old, "newPassword": new}, token)
        if status in (200, 204):
            sys.exit(0)
print("could not confirm the Portainer administrator credential")
sys.exit(1)
PY

vm_caddy_proxy 127.0.0.1:9000 https-ip

vm_output url "$(vm_base_url https)"
vm_output adminUser "$ADMIN_USER"
vm_output adminPassword "$admin_password"
vm_log "Portainer CE is ready"
