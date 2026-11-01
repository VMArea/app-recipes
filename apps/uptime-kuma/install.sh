#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"
umask 022

APP_DIR=/opt/uptime-kuma
APP_PORT=3001
KUMA_USER='admin'

vm_log "installing Uptime Kuma 2.5.7"
vm_install_docker
vm_enable_unattended_security_updates

install -d -m 0755 "$APP_DIR" "$APP_DIR/data"
cat >"$APP_DIR/docker-compose.yml" <<'YML'
services:
  uptime-kuma:
    image: louislam/uptime-kuma:2.5.7@sha256:4b95dbe7ac5343b768f8e04e3035ccd59997872b1a35ab9b0f082d2cc279070e
    restart: unless-stopped
    environment:
      UPTIME_KUMA_DB_TYPE: sqlite
    volumes:
      - ./data:/app/data
    ports:
      - "127.0.0.1:3001:3001"
YML

OLD_PASS=""
if [ -s "$VM_SECRETS_DIR/kuma_admin_password" ]; then
  OLD_PASS=$(cat "$VM_SECRETS_DIR/kuma_admin_password")
fi
ADMIN_PASS=$(vm_rotating_secret kuma_admin_password 24)

vm_compose_up "$APP_DIR"
vm_wait_http "http://127.0.0.1:$APP_PORT/" 120 || vm_die "Uptime Kuma did not start"

KUMA_URL="http://127.0.0.1:$APP_PORT" KUMA_USER="$KUMA_USER" KUMA_PASS="$ADMIN_PASS" KUMA_OLD_PASS="$OLD_PASS" python3 -I - <<'PY'
import json, os, sys, urllib.request

BASE = os.environ["KUMA_URL"] + "/socket.io/?EIO=4&transport=polling"


def http(url, data=None):
    req = urllib.request.Request(
        url,
        data=None if data is None else data.encode(),
        headers={"Content-Type": "text/plain;charset=UTF-8"},
    )
    with urllib.request.urlopen(req, timeout=40) as resp:
        return resp.read().decode()


class Client:
    def __init__(self):
        hello = http(BASE)
        self.url = BASE + "&sid=" + json.loads(hello[1:])["sid"]
        self.counter = 0
        self.buffer = []
        http(self.url, "40")
        self.wait(lambda p: p.startswith("40"))

    def poll(self):
        for packet in http(self.url).split("\x1e"):
            if packet == "2":
                http(self.url, "3")
            elif packet:
                self.buffer.append(packet)

    def wait(self, match, tries=20):
        for _ in range(tries):
            for index, packet in enumerate(self.buffer):
                if match(packet):
                    del self.buffer[index]
                    return packet
            self.poll()
        raise SystemExit("socket timeout")

    def call(self, event, *args):
        self.counter += 1
        ident = self.counter
        http(self.url, "42%d%s" % (ident, json.dumps([event, *args])))
        prefix = "43%d[" % ident
        packet = self.wait(lambda p: p.startswith(prefix))
        return json.loads(packet[len(prefix) - 1:])[0]


user = os.environ["KUMA_USER"]
password = os.environ["KUMA_PASS"]
old = os.environ.get("KUMA_OLD_PASS", "")


def login(client, secret):
    reply = client.call("login", {"username": user, "password": secret, "token": ""})
    return bool(reply.get("ok"))


client = Client()
if client.call("needSetup"):
    reply = client.call("setup", user, password)
    if not reply.get("ok"):
        raise SystemExit("setup failed")
    print("admin account created")
elif login(client, password):
    print("admin account present")
elif old and old != password and login(client, old):
    reply = client.call("changePassword", {"currentPassword": old, "newPassword": password})
    if not reply.get("ok"):
        raise SystemExit("password change failed")
    print("admin password rotated")
else:
    raise SystemExit("cannot authenticate the existing admin account")
PY

vm_caddy_proxy "127.0.0.1:$APP_PORT" https-ip

vm_output url "$(vm_base_url https)"
vm_output adminUser "$KUMA_USER"
vm_output adminPassword "$ADMIN_PASS"
vm_log "Uptime Kuma is ready"
