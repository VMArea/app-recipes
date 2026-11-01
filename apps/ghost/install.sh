#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"

GHOST_IMAGE='ghost:6.72.0-alpine@sha256:40832480edb92ffa318a69cfd36ea69d3c6a475c78b39113b55f15d8dc240b6e'
MYSQL_IMAGE='mysql:8.4.13@sha256:2068651a18ac6048578647ea57b940ca2daed3f504ebe7fba6a93beeb39aaa1f'
APP_DIR=/opt/ghost
ADMIN_EMAIL=owner@example.com

vm_log "installing Docker Engine $VM_DOCKER_VERSION"
vm_install_docker
vm_enable_unattended_security_updates

db_root_password=$(vm_secret ghost_db_root_password 32)
db_password=$(vm_secret ghost_db_password 32)
admin_password=$(vm_secret ghost_admin_password 24)

if [ -n "${VMAREA_DOMAIN:-}" ]; then
  host="$VMAREA_DOMAIN"
  ADMIN_EMAIL="owner@$VMAREA_DOMAIN"
else
  host="$(vm_public_ip)"
fi
site_url="https://$host"

install -d -m 0700 "$APP_DIR"
(umask 077; cat >"$APP_DIR/.env" <<ENV
MYSQL_ROOT_PASSWORD=$db_root_password
MYSQL_PASSWORD=$db_password
GHOST_URL=$site_url
ENV
)
cat >"$APP_DIR/docker-compose.yml" <<YML
services:
  db:
    image: $MYSQL_IMAGE
    restart: unless-stopped
    command:
      - --innodb-buffer-pool-size=256M
      - --performance-schema=OFF
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ghost
      MYSQL_USER: ghost
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - ghost_db:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p\$\$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 30
  ghost:
    image: $GHOST_IMAGE
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "127.0.0.1:2368:2368"
    environment:
      NODE_ENV: production
      url: \${GHOST_URL}
      database__client: mysql
      database__connection__host: db
      database__connection__user: ghost
      database__connection__password: \${MYSQL_PASSWORD}
      database__connection__database: ghost
      security__staffDeviceVerification: "false"
    volumes:
      - ghost_content:/var/lib/ghost/content
volumes:
  ghost_db:
  ghost_content:
YML
chmod 0600 "$APP_DIR/docker-compose.yml"

vm_log "starting Ghost and MySQL"
vm_compose_up "$APP_DIR"
vm_wait_http http://127.0.0.1:2368/ 180 || vm_die "Ghost did not start"

vm_log "creating the owner account"
GHOST_URL="$site_url" GHOST_HOST="$host" OWNER_EMAIL="$ADMIN_EMAIL" OWNER_PASSWORD="$admin_password" python3 - <<'PY'
import json, os, sys, time, urllib.request, urllib.error

url = os.environ["GHOST_URL"]
headers = {
    "Content-Type": "application/json",
    "Accept-Version": "v5.0",
    "Host": os.environ["GHOST_HOST"],
    "Origin": url,
    "X-Forwarded-Proto": "https",
}
endpoint = "http://127.0.0.1:2368/ghost/api/admin/authentication/setup/"


def call(method, body=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(endpoint, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            raw = response.read()
            return response.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as err:
        return err.code, {}
    except Exception:
        return 0, {}


for _ in range(30):
    status, body = call("GET")
    if status == 200:
        break
    time.sleep(5)
else:
    print("Ghost setup endpoint did not answer")
    sys.exit(1)

if body["setup"][0]["status"]:
    sys.exit(0)

payload = {"setup": [{
    "name": "Site owner",
    "email": os.environ["OWNER_EMAIL"],
    "password": os.environ["OWNER_PASSWORD"],
    "blogTitle": "My Ghost site",
}]}
status, _ = call("POST", payload)
if status not in (200, 201):
    print("Ghost owner setup failed with HTTP %s" % status)
    sys.exit(1)
PY

vm_caddy_proxy 127.0.0.1:2368 https-ip

vm_output url "$site_url"
vm_output adminEmail "$ADMIN_EMAIL"
vm_output adminPassword "$admin_password"
vm_log "Ghost is ready"
