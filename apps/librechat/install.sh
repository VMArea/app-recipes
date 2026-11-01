#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"
umask 022

APP_DIR=/opt/librechat
APP_PORT=3080
ADMIN_EMAIL=admin@librechat.local

vm_log "installing LibreChat v0.8.8 on FerretDB 2.7.0"
vm_install_docker
vm_enable_unattended_security_updates

ADMIN_PASS=$(vm_rotating_secret librechat_admin_password 24)
DB_PASS=$(vm_secret librechat_db_password 32)
JWT_SECRET=$(vm_secret librechat_jwt_secret 48)
JWT_REFRESH_SECRET=$(vm_secret librechat_jwt_refresh_secret 48)
CREDS_KEY=$(printf '%s' "$(vm_secret librechat_creds_key 48)" | sha256sum | cut -c1-64)
CREDS_IV=$(printf '%s' "$(vm_secret librechat_creds_iv 48)" | sha256sum | cut -c1-32)
BASE_URL=$(vm_base_url https)

install -d -m 0755 "$APP_DIR"

cat >"$APP_DIR/docker-compose.yml" <<'YML'
services:
  api:
    image: ghcr.io/librechat-ai/librechat:v0.8.8@sha256:5b706bcee1ca154a1e2987303aaeca0eb27f97919cccee4bb604226c2f8abf61
    restart: unless-stopped
    depends_on: [ferretdb]
    env_file: .env
    ports:
      - "127.0.0.1:3080:3080"
    volumes:
      - librechat-uploads:/app/uploads
      - librechat-logs:/app/logs
      - librechat-images:/app/client/public/images
    networks: [internal]
  ferretdb:
    image: ghcr.io/ferretdb/ferretdb:2.7.0@sha256:5706414241eb84f0515512c37b46db0f1b1eac9e5ceb7e4c2523211c184b1985
    restart: unless-stopped
    depends_on: [postgres]
    env_file: .env
    networks: [internal]
  postgres:
    image: ghcr.io/ferretdb/postgres-documentdb:17-0.107.0-ferretdb-2.7.0@sha256:2386795ec2aa7ae559304361979f1dc5708d383ee9020ae63dadc2940dfe58f7
    restart: unless-stopped
    env_file: .env
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks: [internal]
volumes:
  librechat-uploads:
  librechat-logs:
  librechat-images:
  postgres-data:
networks:
  internal:
YML

(
  umask 077
  {
    printf 'POSTGRES_USER=librechat\n'
    printf 'POSTGRES_PASSWORD=%s\n' "$DB_PASS"
    printf 'POSTGRES_DB=postgres\n'
    printf 'FERRETDB_POSTGRESQL_URL=postgres://librechat:%s@postgres:5432/postgres\n' "$DB_PASS"
    printf 'MONGO_URI=mongodb://librechat:%s@ferretdb:27017/LibreChat\n' "$DB_PASS"
    printf 'HOST=0.0.0.0\n'
    printf 'PORT=3080\n'
    printf 'DOMAIN_CLIENT=%s\n' "$BASE_URL"
    printf 'DOMAIN_SERVER=%s\n' "$BASE_URL"
    printf 'JWT_SECRET=%s\n' "$JWT_SECRET"
    printf 'JWT_REFRESH_SECRET=%s\n' "$JWT_REFRESH_SECRET"
    printf 'CREDS_KEY=%s\n' "$CREDS_KEY"
    printf 'CREDS_IV=%s\n' "$CREDS_IV"
    printf 'ALLOW_REGISTRATION=false\n'
    printf 'ALLOW_SOCIAL_LOGIN=false\n'
    printf 'ALLOW_SOCIAL_REGISTRATION=false\n'
    printf 'ALLOW_EMAIL_LOGIN=true\n'
    printf 'ALLOW_UNVERIFIED_EMAIL_LOGIN=true\n'
    printf 'SEARCH=false\n'
    printf 'NO_INDEX=true\n'
    printf 'TRUST_PROXY=1\n'
    printf 'OPENAI_API_KEY=user_provided\n'
    printf 'ANTHROPIC_API_KEY=user_provided\n'
    printf 'GOOGLE_KEY=user_provided\n'
  } >"$APP_DIR/.env.tmp"
  mv "$APP_DIR/.env.tmp" "$APP_DIR/.env"
)
chmod 0600 "$APP_DIR/.env"

vm_compose_up "$APP_DIR"
vm_wait_http "http://127.0.0.1:$APP_PORT/health" 150 || vm_die "LibreChat did not start"

compose() {
  docker compose --project-directory "$APP_DIR" "$@"
}

user_script=$(cat <<'JS'
const mongoose = require('mongoose');
const bcrypt = require('bcryptjs');
(async () => {
  await mongoose.connect(process.env.MONGO_URI, { serverSelectionTimeoutMS: 20000 });
  const users = mongoose.connection.collection('users');
  const email = process.env.ADMIN_EMAIL;
  const existing = await users.findOne({ email });
  if (!existing) {
    process.exit(3);
  }
  if (process.env.SET_PASSWORD === 'yes') {
    const hash = await bcrypt.hash(process.env.NEW_PASS, 10);
    await users.updateOne({ email }, { $set: { password: hash, passwordVersion: Date.now() } });
  }
  process.exit(0);
})().catch(() => process.exit(1));
JS
)

run_user_script() {
  printf '%s\n' "$user_script" | ADMIN_EMAIL="$ADMIN_EMAIL" NEW_PASS="$ADMIN_PASS" SET_PASSWORD="$1" \
    compose exec -T -e ADMIN_EMAIL -e NEW_PASS -e SET_PASSWORD api node - >/dev/null 2>&1
}

rc=0
run_user_script no || rc=$?
if [ "$rc" -eq 3 ]; then
  compose exec -T api npm run create-user -- "$ADMIN_EMAIL" Admin admin "$ADMIN_PASS" --email-verified=true >/dev/null 2>&1 || vm_die "could not create the LibreChat admin user"
  vm_log "admin user created"
elif [ "$rc" -ne 0 ]; then
  vm_die "could not reach the LibreChat user store"
fi
run_user_script yes || vm_die "could not set the LibreChat admin password"

vm_caddy_proxy "127.0.0.1:$APP_PORT" https-ip

vm_output url "$BASE_URL"
vm_output adminEmail "$ADMIN_EMAIL"
vm_output adminPassword "$ADMIN_PASS"
vm_log "LibreChat is ready"
