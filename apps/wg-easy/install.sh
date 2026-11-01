#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"
umask 022

APP_DIR=/opt/wg-easy
UI_PORT=51821
WG_PORT=51820
ADMIN_USER='admin'

vm_log "installing wg-easy 15.4.0"
vm_install_docker
vm_enable_unattended_security_updates

WG_MODULES="wireguard ip_tables iptable_nat iptable_filter ip6_tables ip6table_nat ip6table_filter xt_MASQUERADE"
for module in $WG_MODULES; do
  modprobe "$module" 2>/dev/null || true
done
# shellcheck disable=SC2086
printf '%s\n' $WG_MODULES >/etc/modules-load.d/wg-easy.conf

OLD_PASS=""
if [ -s "$VM_SECRETS_DIR/wgeasy_admin_password" ]; then
  OLD_PASS=$(cat "$VM_SECRETS_DIR/wgeasy_admin_password")
fi
ADMIN_PASS=$(vm_rotating_secret wgeasy_admin_password 24)
if [ -n "${VMAREA_DOMAIN:-}" ]; then
  WG_HOST="$VMAREA_DOMAIN"
else
  WG_HOST=$(vm_public_ip)
fi

install -d -m 0755 "$APP_DIR"

cat >"$APP_DIR/docker-compose.yml" <<'YML'
volumes:
  etc_wireguard:

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15.4.0@sha256:0e7bc9d34e86ddcaa92bc700d4d7dc9b33291dbc07ac8d13382f7c2095f949ec
    container_name: wg-easy
    restart: unless-stopped
    env_file: .env
    networks:
      wg:
        ipv4_address: 10.42.42.42
        ipv6_address: fdcc:ad94:bacf:61a3::2a
    volumes:
      - etc_wireguard:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "51820:51820/udp"
      - "127.0.0.1:51821:51821/tcp"
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.default.forwarding=1

networks:
  wg:
    driver: bridge
    enable_ipv6: true
    ipam:
      driver: default
      config:
        - subnet: 10.42.42.0/24
        - subnet: fdcc:ad94:bacf:61a3::/64
YML

(
  umask 077
  {
    printf 'PORT=%s\n' "$UI_PORT"
    printf 'DISABLE_VERSION_CHECK=true\n'
    printf 'INIT_ENABLED=true\n'
    printf 'INIT_USERNAME=%s\n' "$ADMIN_USER"
    printf 'INIT_PASSWORD=%s\n' "$ADMIN_PASS"
    printf 'INIT_HOST=%s\n' "$WG_HOST"
    printf 'INIT_PORT=%s\n' "$WG_PORT"
  } >"$APP_DIR/.env.tmp"
  mv "$APP_DIR/.env.tmp" "$APP_DIR/.env"
)
chmod 0600 "$APP_DIR/.env"

vm_compose_up "$APP_DIR"
vm_wait_http "http://127.0.0.1:$UI_PORT/" 120 || vm_die "wg-easy did not start"

wg_up=false
for _ in $(seq 1 30); do
  interfaces=$(docker compose --project-directory "$APP_DIR" exec -T wg-easy wg show interfaces 2>/dev/null || true)
  case "$interfaces" in
    *wg0*) wg_up=true; break ;;
  esac
  sleep 2
done
[ "$wg_up" = true ] || vm_die "the WireGuard interface did not come up"

if [ -n "$OLD_PASS" ] && [ "$OLD_PASS" != "$ADMIN_PASS" ]; then
  docker compose --project-directory "$APP_DIR" exec -T wg-easy cli db:admin:reset --password "$ADMIN_PASS" >/dev/null 2>&1 || vm_die "could not rotate the wg-easy admin password"
  vm_log "admin password rotated"
fi

vm_caddy_proxy "127.0.0.1:$UI_PORT" https-ip

vm_output url "$(vm_base_url https)"
vm_output adminUser "$ADMIN_USER"
vm_output adminPassword "$ADMIN_PASS"
vm_log "wg-easy is ready"
