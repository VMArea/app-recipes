#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"
umask 022

APP_DIR=/opt/grafana-prometheus
GRAFANA_USER='admin'

vm_log "installing Grafana 13.2.4 with Prometheus 3.15.1 and node-exporter 1.12.1"
vm_install_docker
vm_enable_unattended_security_updates

ADMIN_PASS=$(vm_rotating_secret grafana_admin_password 24)
ROOT_URL=$(vm_base_url https)

install -d -m 0755 "$APP_DIR" "$APP_DIR/provisioning/datasources"

cat >"$APP_DIR/docker-compose.yml" <<'YML'
services:
  grafana:
    image: grafana/grafana:13.2.4@sha256:dbbc38ea21103cefb50396340cd88afec779c7e070b0a7bf5a75b4ce46651d3f
    restart: unless-stopped
    network_mode: host
    env_file: .env
    volumes:
      - grafana-data:/var/lib/grafana
      - ./provisioning:/etc/grafana/provisioning:ro
  prometheus:
    image: prom/prometheus:v3.15.1@sha256:fa3302279710be2f21a8301ec17a8b4f2301fd829bd113839b3b6b02b6f191a2
    restart: unless-stopped
    network_mode: host
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d
      - --web.listen-address=127.0.0.1:9090
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
  node-exporter:
    image: prom/node-exporter:v1.12.1@sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0
    restart: unless-stopped
    network_mode: host
    pid: host
    command:
      - --path.rootfs=/host
      - --web.listen-address=127.0.0.1:9100
    volumes:
      - /:/host:ro,rslave
volumes:
  grafana-data:
  prometheus-data:
YML

cat >"$APP_DIR/prometheus.yml" <<'YML'
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["127.0.0.1:9090"]
  - job_name: node
    static_configs:
      - targets: ["127.0.0.1:9100"]
YML

cat >"$APP_DIR/provisioning/datasources/prometheus.yml" <<'YML'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
YML

(
  umask 077
  {
    printf 'GF_SECURITY_ADMIN_USER=%s\n' "$GRAFANA_USER"
    printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$ADMIN_PASS"
    printf 'GF_USERS_ALLOW_SIGN_UP=false\n'
    printf 'GF_USERS_ALLOW_ORG_CREATE=false\n'
    printf 'GF_AUTH_ANONYMOUS_ENABLED=false\n'
    printf 'GF_SERVER_HTTP_ADDR=127.0.0.1\n'
    printf 'GF_SERVER_HTTP_PORT=3000\n'
    printf 'GF_SERVER_ROOT_URL=%s/\n' "$ROOT_URL"
    printf 'GF_SECURITY_COOKIE_SECURE=true\n'
    printf 'GF_ANALYTICS_REPORTING_ENABLED=false\n'
    printf 'GF_ANALYTICS_CHECK_FOR_UPDATES=false\n'
  } >"$APP_DIR/.env.tmp"
  mv "$APP_DIR/.env.tmp" "$APP_DIR/.env"
)
chmod 0600 "$APP_DIR/.env"

vm_compose_up "$APP_DIR"
vm_wait_http "http://127.0.0.1:3000/api/health" 120 || vm_die "Grafana did not start"
vm_wait_http "http://127.0.0.1:9090/-/ready" 60 || vm_die "Prometheus did not start"

printf '%s' "$ADMIN_PASS" | docker compose --project-directory "$APP_DIR" exec -T grafana grafana cli admin reset-admin-password --password-from-stdin >/dev/null 2>&1 || vm_die "could not set the Grafana admin password"

vm_caddy_proxy "127.0.0.1:3000" https-ip

vm_output url "$ROOT_URL"
vm_output adminUser "$GRAFANA_USER"
vm_output adminPassword "$ADMIN_PASS"
vm_log "Grafana and Prometheus are ready"
