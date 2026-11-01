#!/bin/bash
set -euo pipefail
# shellcheck source=../../lib/recipe-lib.sh
. "$VMAREA_LIB"

WP_VERSION=7.1.3
WP_SHA1=13eb1d042b1ca39224e44906cd84fe203112210c
WPCLI_VERSION=2.12.0
WPCLI_SHA512=be928f6b8ca1e8dfb9d2f4b75a13aa4aee0896f8a9a0a1c45cd5d2c98605e6172e6d014dda2e27f88c98befc16c040cbb2bd1bfa121510ea5cdf5f6a30fe8832
WP_DIR=/var/www/wordpress
WP_ADMIN=wpadmin
DB_NAME=wordpress
DB_USER=wordpress
SITE_CONF=/etc/nginx/sites-available/vmarea-wordpress.conf

vm_log "installing nginx, MariaDB and PHP-FPM"
vm_apt_install nginx mariadb-server php-fpm php-cli php-mysql php-curl php-gd php-mbstring php-xml php-zip php-intl php-bcmath php-imagick unzip curl ca-certificates certbot python3-certbot-nginx
vm_enable_unattended_security_updates

if [ -n "${VMAREA_DOMAIN:-}" ]; then
  case "$VMAREA_DOMAIN" in *[!A-Za-z0-9.-]*) vm_die "invalid domain" ;; esac
  admin_email="admin@$VMAREA_DOMAIN"
  install_url="http://$VMAREA_DOMAIN"
  final_url="https://$VMAREA_DOMAIN"
else
  admin_email="admin@example.com"
  install_url="http://$(vm_public_ip)"
  final_url="$install_url"
fi

db_password=$(vm_secret wordpress_db_password 24)
admin_password=$(vm_rotating_secret wordpress_admin_password 24)

systemctl enable --now mariadb >/dev/null 2>&1
vm_retry 30 2 mariadb -e 'SELECT 1' >/dev/null 2>&1 || vm_die "MariaDB did not start"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$db_password';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$db_password';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

wpcli_version=""
if [ -x /usr/local/bin/wp ]; then
  wpcli_version=$(php /usr/local/bin/wp --allow-root --version 2>/dev/null || true)
fi
if [ "$wpcli_version" != "WP-CLI $WPCLI_VERSION" ]; then
  vm_log "installing WP-CLI $WPCLI_VERSION"
  tmp=$(mktemp -d)
  vm_retry 5 5 curl -fsSL -o "$tmp/wp-cli.phar" "https://github.com/wp-cli/wp-cli/releases/download/v$WPCLI_VERSION/wp-cli-$WPCLI_VERSION.phar"
  echo "$WPCLI_SHA512  $tmp/wp-cli.phar" | sha512sum -c - >/dev/null || vm_die "WP-CLI checksum mismatch"
  install -m 0755 "$tmp/wp-cli.phar" /usr/local/bin/wp
  rm -rf "$tmp"
fi

if [ ! -f "$WP_DIR/wp-includes/version.php" ]; then
  vm_log "downloading WordPress $WP_VERSION"
  tmp=$(mktemp -d)
  vm_retry 5 5 curl -fsSL -o "$tmp/wordpress.zip" "https://downloads.wordpress.org/release/wordpress-$WP_VERSION.zip"
  echo "$WP_SHA1  $tmp/wordpress.zip" | sha1sum -c - >/dev/null || vm_die "WordPress checksum mismatch"
  unzip -q "$tmp/wordpress.zip" -d "$tmp"
  install -d -m 0755 /var/www
  rm -rf "$WP_DIR"
  mv "$tmp/wordpress" "$WP_DIR"
  rm -rf "$tmp"
  chown -R www-data:www-data "$WP_DIR"
fi

wpcli() {
  runuser -u www-data -- php -d memory_limit=512M /usr/local/bin/wp --path="$WP_DIR" "$@"
}

if [ ! -f "$WP_DIR/wp-config.php" ]; then
  wpcli config create --dbname="$DB_NAME" --dbuser="$DB_USER" --dbpass="$db_password" --dbcharset=utf8mb4 --skip-check >/dev/null
fi

if ! wpcli core is-installed >/dev/null 2>&1; then
  vm_log "installing WordPress"
  wpcli core install --url="$install_url" --title="My WordPress site" --admin_user="$WP_ADMIN" --admin_password="$admin_password" --admin_email="$admin_email" --skip-email >/dev/null
else
  wpcli user update "$WP_ADMIN" --user_pass="$admin_password" >/dev/null
fi

php_ver=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
php_sock="/run/php/php${php_ver}-fpm.sock"
cat >"/etc/php/${php_ver}/fpm/conf.d/99-vmarea.ini" <<INI
upload_max_filesize = 64M
post_max_size = 64M
memory_limit = 256M
expose_php = Off
INI
systemctl enable --now "php${php_ver}-fpm" >/dev/null 2>&1
systemctl restart "php${php_ver}-fpm"

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
    root $WP_DIR;
    index index.php;
    client_max_body_size 64M;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$php_sock;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }

    location = /xmlrpc.php {
        deny all;
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|ico|webp|woff2?)\$ {
        expires 30d;
        access_log off;
    }
}
CONF
fi
rm -f /etc/nginx/sites-enabled/default
ln -sf "$SITE_CONF" /etc/nginx/sites-enabled/vmarea-wordpress.conf
nginx -t >/dev/null 2>&1 || vm_die "nginx configuration is invalid"
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

setup_certbot_retry() {
  [ -n "${VMAREA_DOMAIN:-}" ] || return 0
  printf '%s' "$VMAREA_DOMAIN" >/etc/vmarea-certbot-domain
  cat >/usr/local/sbin/vmarea-certbot-done <<'SH'
#!/bin/bash
set -u
domain=$(cat /etc/vmarea-certbot-domain)
for option in home siteurl; do
  runuser -u www-data -- php /usr/local/bin/wp --path=/var/www/wordpress option update "$option" "https://$domain" >/dev/null
done
SH
  chmod 0755 /usr/local/sbin/vmarea-certbot-done
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
Description=Retry Lets Encrypt certificate issuance
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/vmarea-certbot-retry
UNIT
  cat >/etc/systemd/system/vmarea-certbot-retry.timer <<'UNIT'
[Unit]
Description=Hourly Lets Encrypt retry until a certificate is issued

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

vm_wait_http http://127.0.0.1/wp-login.php 60 || vm_die "WordPress did not answer"

vm_output url "$final_url"
vm_output adminUser "$WP_ADMIN"
vm_output adminPassword "$admin_password"
vm_log "WordPress is ready"
