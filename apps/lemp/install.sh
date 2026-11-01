#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"

DB_NAME=app
DB_USER=app
WEB_ROOT=/var/www/html
SITE_CONF=/etc/nginx/sites-available/vmarea-lemp.conf

vm_log "installing nginx, MariaDB and PHP-FPM"
vm_apt_install nginx mariadb-server php-fpm php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl php-bcmath unzip curl ca-certificates certbot python3-certbot-nginx
vm_enable_unattended_security_updates

if [ -n "${VMAREA_DOMAIN:-}" ]; then
  case "$VMAREA_DOMAIN" in *[!A-Za-z0-9.-]*) vm_die "invalid domain" ;; esac
fi

db_password=$(vm_rotating_secret lemp_db_password 24)

systemctl enable --now mariadb >/dev/null 2>&1
vm_retry 30 2 mariadb -e 'SELECT 1' >/dev/null 2>&1 || vm_die "MariaDB did not start"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$db_password';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$db_password';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

php_ver=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
php_sock="/run/php/php${php_ver}-fpm.sock"
cat >"/etc/php/${php_ver}/fpm/conf.d/99-vmarea.ini" <<INI
upload_max_filesize = 64M
post_max_size = 64M
expose_php = Off
INI
systemctl enable --now "php${php_ver}-fpm" >/dev/null 2>&1
systemctl restart "php${php_ver}-fpm"

install -d -m 0755 "$WEB_ROOT"
rm -f "$WEB_ROOT/index.nginx-debian.html"
if [ ! -e "$WEB_ROOT/index.html" ] && [ ! -e "$WEB_ROOT/index.php" ]; then
  cat >"$WEB_ROOT/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Your server is ready</title>
<style>body{font:16px/1.6 system-ui,sans-serif;max-width:40rem;margin:4rem auto;padding:0 1rem;color:#1f2937}code{background:#f3f4f6;padding:.1rem .35rem;border-radius:4px}</style>
</head>
<body>
<h1>Your server is ready</h1>
<p>nginx, MariaDB and PHP-FPM are running. Replace this page by uploading your site to <code>/var/www/html</code>.</p>
</body>
</html>
HTML
fi
chown -R www-data:www-data "$WEB_ROOT"

if [ ! -e "$SITE_CONF" ]; then
  if [ -n "${VMAREA_DOMAIN:-}" ]; then
    server_name="$VMAREA_DOMAIN"
  else
    server_name="_"
  fi
  cat >"$SITE_CONF" <<CONF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $server_name;
    root $WEB_ROOT;
    index index.php index.html;
    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$php_sock;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }
}
CONF
fi
rm -f /etc/nginx/sites-enabled/default
ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/vmarea-lemp.conf
nginx -t >/dev/null 2>&1 || vm_die "nginx configuration is invalid"
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

setup_certbot_retry() {
  [ -n "${VMAREA_DOMAIN:-}" ] || return 0
  printf '%s' "$VMAREA_DOMAIN" >/etc/vmarea-certbot-domain
  cat >/usr/local/sbin/vmarea-certbot-retry <<'SH'
#!/bin/bash
set -u
exec 9>/run/vmarea-certbot.lock
flock -n 9 || exit 0
domain=$(cat /etc/vmarea-certbot-domain)
if [ -d "/etc/letsencrypt/live/$domain" ] || certbot --nginx -d "$domain" --non-interactive --agree-tos --register-unsafely-without-email --redirect; then
  if [ -x /usr/local/sbin/vmarea-certbot-done ]; then
    /usr/local/sbin/vmarea-certbot-done || true
  fi
  if grep -q "return 404; # managed by Certbot" /etc/nginx/sites-enabled/*.conf; then
    sed -i --follow-symlinks 's|return 404; # managed by Certbot|return 301 https://$host$request_uri;|' /etc/nginx/sites-enabled/*.conf
    nginx -t >/dev/null 2>&1 && systemctl reload nginx
  fi
  systemctl disable --now vmarea-certbot-retry.timer
fi
SH
  chmod 0755 /usr/local/sbin/vmarea-certbot-retry
  cat >/etc/systemd/system/vmarea-certbot-retry.service <<'UNIT'
[Unit]
Description=Retry Let's Encrypt certificate issuance
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vmarea-certbot-retry
UNIT
  cat >/etc/systemd/system/vmarea-certbot-retry.timer <<'UNIT'
[Unit]
Description=Hourly Let's Encrypt retry until a certificate is issued

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  if [ -d "/etc/letsencrypt/live/$VMAREA_DOMAIN" ]; then
    return 0
  fi
  systemctl enable --now vmarea-certbot-retry.timer >/dev/null 2>&1
  vm_log "requesting a certificate for $VMAREA_DOMAIN"
  timeout 300 /usr/local/sbin/vmarea-certbot-retry || true
  if systemctl is-enabled --quiet vmarea-certbot-retry.timer; then
    vm_log "certificate not issued yet, retrying hourly until DNS resolves"
  fi
}
setup_certbot_retry

if [ -n "${VMAREA_DOMAIN:-}" ]; then
  url="https://$VMAREA_DOMAIN"
else
  url="http://$(vm_public_ip)"
fi
vm_wait_http http://127.0.0.1/ 30 || vm_die "nginx did not answer"

vm_output url "$url"
vm_output dbName "$DB_NAME"
vm_output dbUser "$DB_USER"
vm_output dbPassword "$db_password"
vm_log "LEMP stack is ready"
