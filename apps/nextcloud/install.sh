#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"
umask 022

APP_DIR=/opt/nextcloud
ADMIN_USER='admin'
NC_PORT=8080

vm_log "installing Nextcloud 35.0.2"
vm_install_docker
vm_enable_unattended_security_updates

ADMIN_PASS=$(vm_rotating_secret nextcloud_admin_password 24)
DB_PASS=$(vm_secret nextcloud_db_password 32)
DB_ROOT_PASS=$(vm_secret nextcloud_db_root_password 32)
REDIS_PASS=$(vm_secret nextcloud_redis_password 32)
PUBLIC_IP=$(vm_public_ip)
BASE_URL=$(vm_base_url https)
if [ -n "${VMAREA_DOMAIN:-}" ]; then
  PUBLIC_HOST="$VMAREA_DOMAIN"
  TRUSTED="$VMAREA_DOMAIN $PUBLIC_IP 127.0.0.1"
else
  PUBLIC_HOST="$PUBLIC_IP"
  TRUSTED="$PUBLIC_IP 127.0.0.1"
fi

install -d -m 0755 "$APP_DIR"

cat >"$APP_DIR/docker-compose.yml" <<'YML'
services:
  db:
    image: mariadb:11.8.9@sha256:f16d7a344413e519dff518f27bdb221388f84b0d274c97c4fb5f2cb0dc1b34fa
    restart: unless-stopped
    command: --transaction-isolation=READ-COMMITTED --log-bin=binlog --binlog-format=ROW --innodb-file-per-table=1 --skip-innodb-read-only-compressed
    env_file: .env
    volumes:
      - db-data:/var/lib/mysql
    networks: [internal]
  redis:
    image: redis:7.2.9-alpine@sha256:fce236b99c58ef7196c4e243e43f533b404d5c17239cae4e6e262b729a1952b3
    restart: unless-stopped
    env_file: .env
    command: ["sh", "-c", "exec redis-server --requirepass \"$$REDIS_HOST_PASSWORD\" --save '' --appendonly no"]
    networks: [internal]
  app:
    image: nextcloud:35.0.2-apache@sha256:89af7ee7a96ff5e9668280566209268ae6b2d02327f6ef6d56f6d68228cf9431
    restart: unless-stopped
    depends_on: [db, redis]
    env_file: .env
    ports:
      - "127.0.0.1:8080:80"
    volumes:
      - nextcloud-html:/var/www/html
    networks: [internal]
  cron:
    image: nextcloud:35.0.2-apache@sha256:89af7ee7a96ff5e9668280566209268ae6b2d02327f6ef6d56f6d68228cf9431
    restart: unless-stopped
    depends_on: [app]
    entrypoint: /cron.sh
    env_file: .env
    volumes:
      - nextcloud-html:/var/www/html
    networks: [internal]
volumes:
  db-data:
  nextcloud-html:
networks:
  internal:
    ipam:
      config:
        - subnet: 172.29.250.0/24
YML

(
  umask 077
  {
    printf 'MARIADB_ROOT_PASSWORD=%s\n' "$DB_ROOT_PASS"
    printf 'MARIADB_DATABASE=nextcloud\n'
    printf 'MARIADB_USER=nextcloud\n'
    printf 'MARIADB_PASSWORD=%s\n' "$DB_PASS"
    printf 'MYSQL_HOST=db\n'
    printf 'MYSQL_DATABASE=nextcloud\n'
    printf 'MYSQL_USER=nextcloud\n'
    printf 'MYSQL_PASSWORD=%s\n' "$DB_PASS"
    printf 'REDIS_HOST=redis\n'
    printf 'REDIS_HOST_PASSWORD=%s\n' "$REDIS_PASS"
    printf 'NEXTCLOUD_ADMIN_USER=%s\n' "$ADMIN_USER"
    printf 'NEXTCLOUD_ADMIN_PASSWORD=%s\n' "$ADMIN_PASS"
    printf 'NEXTCLOUD_TRUSTED_DOMAINS=%s\n' "$TRUSTED"
    printf 'OVERWRITEPROTOCOL=https\n'
    printf 'OVERWRITEHOST=%s\n' "$PUBLIC_HOST"
    printf 'OVERWRITECLIURL=%s\n' "$BASE_URL"
    printf 'TRUSTED_PROXIES=172.29.250.1\n'
    printf 'PHP_MEMORY_LIMIT=512M\n'
    printf 'PHP_UPLOAD_LIMIT=1G\n'
  } >"$APP_DIR/.env.tmp"
  mv "$APP_DIR/.env.tmp" "$APP_DIR/.env"
)
chmod 0600 "$APP_DIR/.env"

vm_compose_up "$APP_DIR"

occ() {
  docker compose --project-directory "$APP_DIR" exec -T -u www-data app php occ "$@"
}

installed=false
for _ in $(seq 1 120); do
  status=$(occ status 2>/dev/null || true)
  case "$status" in
    *"installed: true"*) installed=true; break ;;
  esac
  sleep 5
done
[ "$installed" = true ] || vm_die "Nextcloud did not finish installing"

index=0
for domain in $TRUSTED; do
  occ config:system:set trusted_domains "$index" --value="$domain" >/dev/null
  index=$((index + 1))
done
occ config:system:set overwritehost --value="$PUBLIC_HOST" >/dev/null
occ config:system:set overwriteprotocol --value=https >/dev/null
occ config:system:set overwrite.cli.url --value="$BASE_URL" >/dev/null
occ config:system:set maintenance_window_start --type=integer --value=1 >/dev/null
occ background:cron >/dev/null

OC_PASS="$ADMIN_PASS" docker compose --project-directory "$APP_DIR" exec -T -u www-data -e OC_PASS app php occ user:resetpassword --password-from-env "$ADMIN_USER" >/dev/null || vm_die "could not set the Nextcloud admin password"

vm_wait_http "http://127.0.0.1:$NC_PORT/status.php" 60 || vm_die "Nextcloud is not answering"
vm_caddy_proxy "127.0.0.1:$NC_PORT" https-ip

vm_output url "$BASE_URL"
vm_output adminUser "$ADMIN_USER"
vm_output adminPassword "$ADMIN_PASS"
vm_log "Nextcloud is ready"
