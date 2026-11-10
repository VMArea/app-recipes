#!/bin/bash
VM_SECRETS_DIR=/var/lib/vmarea/recipe-secrets
VM_DOCKER_VERSION=29.9.2
VM_DOCKER_GPG_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
VM_CADDY_VERSION=2.11.7
VM_CADDY_SHA512=a7a433a1b133efc3c8d10eb0b99d52a24b5ef5c322dc77f5282182b1c0402139ab83f3a99f0c52409df77d20123fb0b523edad8a66d8f5e49136197bf61ef0e7

vm_log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

vm_die() {
  vm_log "error: $*"
  exit 1
}

vm_random() {
  local length="${1:-24}" value=""
  while [ "${#value}" -lt "$length" ]; do
    value="${value}$(head -c 256 /dev/urandom | tr -dc 'A-Za-z0-9')"
  done
  printf '%s' "${value:0:$length}"
}

vm_secret() {
  local name="$1" length="${2:-24}" file
  case "$name" in *[!A-Za-z0-9_]*|"") vm_die "invalid secret name" ;; esac
  install -d -m 0700 "$VM_SECRETS_DIR"
  file="$VM_SECRETS_DIR/$name"
  if [ ! -s "$file" ]; then
    (umask 077; vm_random "$length" >"$file.tmp" && mv "$file.tmp" "$file")
  fi
  cat "$file"
}

vm_rotating_secret() {
  local name="$1" length="${2:-24}" marker
  marker="$VM_SECRETS_DIR/.rotated-${VMAREA_RUN_ATTEMPT:-0}-$name"
  if [ "${VMAREA_RUN_PURPOSE:-}" = "REGENERATE" ] && [ ! -e "$marker" ]; then
    rm -f "$VM_SECRETS_DIR/$name"
    vm_secret "$name" "$length" >/dev/null
    touch "$marker"
  fi
  vm_secret "$name" "$length"
}

vm_is_regenerate() {
  [ "${VMAREA_RUN_PURPOSE:-}" = "REGENERATE" ]
}

vm_output() {
  local key="$1" value="$2"
  case "$value" in *$'\n'*) vm_die "output $key must be a single line" ;; esac
  printf '%s=%s\n' "$key" "$value" >>"$VMAREA_OUTPUT"
}

vm_public_ip() {
  if [ -n "${VMAREA_PUBLIC_IP:-}" ]; then
    printf '%s' "$VMAREA_PUBLIC_IP"
    return
  fi
  ip -4 route get 192.0.2.1 2>/dev/null | awk '!found {for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); found = 1 }}'
}

vm_base_url() {
  local scheme="${1:-http}"
  if [ -n "${VMAREA_DOMAIN:-}" ]; then
    printf 'https://%s' "$VMAREA_DOMAIN"
  else
    printf '%s://%s' "$scheme" "$(vm_public_ip)"
  fi
}

vm_retry() {
  local tries="$1" pause="$2" i=1
  shift 2
  until "$@"; do
    [ "$i" -ge "$tries" ] && return 1
    i=$((i + 1))
    sleep "$pause"
  done
}

vm_apt_update() {
  vm_retry 5 10 apt-get -o DPkg::Lock::Timeout=600 -q update
}

vm_apt_install() {
  vm_apt_update >/dev/null
  vm_retry 3 15 apt-get -o DPkg::Lock::Timeout=600 -y -q \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold \
    install --no-install-recommends "$@"
}

vm_wait_http() {
  local url="$1" tries="${2:-90}" i=0 code
  while [ "$i" -lt "$tries" ]; do
    code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 5 "$url" || true)
    if [ -n "$code" ] && [ "$code" != "000" ] && [ "$code" -lt 500 ]; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

vm_wait_tcp() {
  local port="$1" tries="${2:-90}" i=0
  while [ "$i" -lt "$tries" ]; do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

vm_install_docker() {
  if command -v docker >/dev/null 2>&1 && [ "$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)" = "$VM_DOCKER_VERSION" ]; then
    systemctl enable --now docker >/dev/null 2>&1 || true
    return 0
  fi
  vm_apt_install ca-certificates curl gnupg
  install -d -m 0755 /etc/apt/keyrings
  vm_retry 5 5 curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  local got
  got=$(gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc 2>/dev/null | awk -F: '$1=="fpr" && !found {print $10; found = 1}')
  [ "$got" = "$VM_DOCKER_GPG_FPR" ] || vm_die "Docker repository key fingerprint mismatch"
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" >/etc/apt/sources.list.d/docker.list
  vm_apt_update >/dev/null
  local ce cli
  ce=$(apt-cache madison docker-ce | awk -v v="$VM_DOCKER_VERSION" '$3 ~ ("5:" v "-") && !found {print $3; found = 1}')
  cli=$(apt-cache madison docker-ce-cli | awk -v v="$VM_DOCKER_VERSION" '$3 ~ ("5:" v "-") && !found {print $3; found = 1}')
  if [ -z "$ce" ] || [ -z "$cli" ]; then vm_die "Docker $VM_DOCKER_VERSION is not in the repository"; fi
  apt-mark unhold docker-ce docker-ce-cli >/dev/null 2>&1 || true
  vm_apt_install "docker-ce=$ce" "docker-ce-cli=$cli" containerd.io docker-compose-plugin docker-buildx-plugin
  apt-mark hold docker-ce docker-ce-cli >/dev/null
  install -d -m 0755 /etc/docker
  if [ ! -f /etc/docker/daemon.json ]; then
    printf '{\n  "log-driver": "json-file",\n  "log-opts": { "max-size": "10m", "max-file": "3" }\n}\n' >/etc/docker/daemon.json
  fi
  systemctl enable docker >/dev/null 2>&1
  systemctl restart docker
  vm_retry 30 2 docker info >/dev/null 2>&1 || vm_die "Docker did not start"
}

vm_compose_up() {
  local dir="$1"
  vm_retry 4 15 docker compose --project-directory "$dir" pull --quiet || vm_die "image pull failed"
  docker compose --project-directory "$dir" up -d --remove-orphans
}

vm_install_caddy() {
  if command -v caddy >/dev/null 2>&1 && case "$(caddy version 2>/dev/null || true)" in "v$VM_CADDY_VERSION"*) true ;; *) false ;; esac; then
    return 0
  fi
  local tmp
  tmp=$(mktemp -d)
  vm_retry 5 5 curl -fsSL -o "$tmp/caddy.tgz" "https://github.com/caddyserver/caddy/releases/download/v$VM_CADDY_VERSION/caddy_${VM_CADDY_VERSION}_linux_amd64.tar.gz"
  echo "$VM_CADDY_SHA512  $tmp/caddy.tgz" | sha512sum -c - >/dev/null || vm_die "Caddy checksum mismatch"
  tar -xzf "$tmp/caddy.tgz" -C "$tmp" caddy
  install -m 0755 "$tmp/caddy" /usr/local/bin/caddy
  rm -rf "$tmp"
  getent group caddy >/dev/null || groupadd --system caddy
  id caddy >/dev/null 2>&1 || useradd --system --gid caddy --create-home --home-dir /var/lib/caddy --shell /usr/sbin/nologin caddy
  install -d -m 0755 /etc/caddy
  cat >/etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
}

vm_caddy_proxy() {
  local upstream="$1" mode="${2:-http}"
  vm_install_caddy
  {
    printf '{
	admin localhost:2019
}

'
    if [ -n "${VMAREA_DOMAIN:-}" ]; then
      printf '%s {
	encode zstd gzip
	reverse_proxy %s
}
' "$VMAREA_DOMAIN" "$upstream"
    elif [ "$mode" = "https-ip" ]; then
      printf 'https://%s {
	tls internal
	encode zstd gzip
	reverse_proxy %s
}

' "$(vm_public_ip)" "$upstream"
      printf 'http://:80 {
	redir https://{host}{uri} permanent
}
'
    else
      printf ':80 {
	encode zstd gzip
	reverse_proxy %s
}
' "$upstream"
    fi
  } >/etc/caddy/Caddyfile
  chmod 0644 /etc/caddy/Caddyfile
  /usr/local/bin/caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 || vm_die "invalid Caddyfile"
  systemctl enable caddy >/dev/null 2>&1
  systemctl restart caddy
}

vm_enable_unattended_security_updates() {
  vm_apt_install unattended-upgrades >/dev/null
  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' >/etc/apt/apt.conf.d/20auto-upgrades
}
