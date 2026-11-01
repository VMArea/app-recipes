#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
APPS_DIR="$ROOT/apps"
META="$ROOT/lib/recipe-meta.py"
LOG=/var/log/vmarea-app-install.log
OUT_DIR=/run/vmarea
OUT="$OUT_DIR/app-outputs"
HEALTH_WAIT_SEC=180

usage() {
  cat <<'USAGE'
Usage: sudo ./install.sh <app> [options]
       ./install.sh --list

Installs one app on this server (Ubuntu 24.04, x86_64) and prints the
generated credentials once at the end.

Options:
  --domain <name>             serve the app on this domain with Let's Encrypt
                              HTTPS (the DNS record must already point here)
  --public-ip <ipv4>          address to advertise when the server sits behind
                              NAT (default: the primary IPv4 address)
  --credentials-file <path>   write the credentials to this file (mode 0600)
                              instead of printing them
  --list                      list the available apps
  -h, --help                  show this help

Set VMAREA_ALLOW_UNSUPPORTED=1 to skip the OS and architecture check.
USAGE
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

app=""
domain=""
public_ip=""
creds_file=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --list) python3 "$META" list "$APPS_DIR"; exit 0 ;;
    --domain) [ "$#" -ge 2 ] || die "--domain needs a value"; domain="$2"; shift 2 ;;
    --public-ip) [ "$#" -ge 2 ] || die "--public-ip needs a value"; public_ip="$2"; shift 2 ;;
    --credentials-file) [ "$#" -ge 2 ] || die "--credentials-file needs a value"; creds_file="$2"; shift 2 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) [ -z "$app" ] || die "only one app can be installed per run"; app="$1"; shift ;;
  esac
done

[ -n "$app" ] || { usage >&2; exit 2; }
case "$app" in *[!a-z0-9-]*) die "invalid app name: $app" ;; esac
recipe_dir="$APPS_DIR/$app"
recipe_json="$recipe_dir/recipe.json"
if [ ! -f "$recipe_dir/install.sh" ] || [ ! -f "$recipe_json" ]; then
  python3 "$META" list "$APPS_DIR" >&2
  die "unknown app: $app"
fi

[ "$(id -u)" -eq 0 ] || die "run as root (use sudo)"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

if [ "${VMAREA_ALLOW_UNSUPPORTED:-}" != "1" ]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "24.04" ] || die "Ubuntu 24.04 is required (found ${PRETTY_NAME:-unknown})"
  [ "$(uname -m)" = "x86_64" ] || die "an x86_64 server is required (found $(uname -m))"
fi

if [ -n "$domain" ]; then
  domain=$(printf '%s' "$domain" | tr "[:upper:]" "[:lower:]")
  printf '%s' "$domain" | grep -Eq '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' || die "invalid domain: $domain"
  [ "$(python3 "$META" field "$recipe_json" supportsDomain)" = "true" ] || die "$app does not support --domain"
fi
if [ -n "$public_ip" ]; then
  printf '%s' "$public_ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || die "invalid IPv4 address: $public_ip"
fi

min_cpu=$(python3 "$META" field "$recipe_json" minVcpu)
min_ram=$(python3 "$META" field "$recipe_json" minRamMb)
have_cpu=$(nproc)
have_ram=$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo)
if [ "$have_cpu" -lt "$min_cpu" ] || [ "$have_ram" -lt $((min_ram * 9 / 10)) ]; then
  warn "$app needs at least $min_cpu vCPU and $min_ram MB RAM; this server has $have_cpu vCPU and $have_ram MB"
fi

umask 077
install -d -m 0700 "$OUT_DIR"
: >"$OUT"
touch "$LOG"
chmod 0600 "$LOG"

cleanup() {
  shred -u -f "$OUT" 2>/dev/null || rm -f "$OUT"
}
trap cleanup EXIT

limit_min=$(python3 "$META" field "$recipe_json" firstRunTimeoutMinutes)
name=$(python3 "$META" field "$recipe_json" name)
printf 'Installing %s (log: %s)\n' "$name" "$LOG"

set +e
timeout -k 10 "$((limit_min * 60))" env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root \
  LANG=C.UTF-8 \
  LC_ALL=C.UTF-8 \
  DEBIAN_FRONTEND=noninteractive \
  NEEDRESTART_MODE=a \
  VMAREA_LIB="$ROOT/lib/recipe-lib.sh" \
  VMAREA_OUTPUT="$OUT" \
  VMAREA_RUN_PURPOSE=FIRST_RUN \
  VMAREA_RUN_ATTEMPT=1 \
  VMAREA_DOMAIN="$domain" \
  VMAREA_PUBLIC_IP="$public_ip" \
  /bin/bash "$recipe_dir/install.sh" </dev/null 2>&1 | tee -a "$LOG"
status=${PIPESTATUS[0]}
set -e

[ "$status" -eq 0 ] || die "install failed (exit status $status); see $LOG"

printf 'Waiting for the health check\n'
python3 "$META" health "$recipe_json" "$HEALTH_WAIT_SEC" || die "health check did not pass within ${HEALTH_WAIT_SEC}s; see $LOG"

printf '\n%s is ready.\n\n' "$name"
python3 "$META" outputs "$recipe_json" "$OUT" "$creds_file" || die "the installer did not produce its declared outputs; see $LOG"
if [ -z "$creds_file" ] && [ -s "$OUT" ]; then
  printf '\nThe credentials above are shown once. Store them now.\n'
fi
