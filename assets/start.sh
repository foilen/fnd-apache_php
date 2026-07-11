#!/usr/bin/env bash
# Launch Apache + PHP-FPM. Run via `nix run github:foilen/fnd-apache_php` or
# an installed `fnd-apache_php` (from `nix profile install`).
set -euo pipefail

# ASSETS_DIR holds the (read-only) templates - defaults to the directory
# this script lives in (a git checkout or nix store copy).
# PROJECT_DIR is the (read-write) directory holding site files and
# generated state - defaults to the current directory, so this can be run
# from any project folder without being colocated with the assets.
ASSETS_DIR="${ASSETS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_DIR="${PROJECT_DIR:-$PWD}"

for var in APACHE_HTTPD PHP_PACKAGE SENDMAIL_TO_MSMTP MSMTP_PATH APACHE_MODULES_CONF SERVICES_EXECUTION; do
  if [ -z "${!var:-}" ]; then
    echo "\$$var is not set - run this via 'nix run'" >&2
    exit 1
  fi
done

# --- Configuration (env vars, with defaults) ---------------------------------

STATE_DIR="${STATE_DIR:-$PROJECT_DIR/_run}"
HTTP_PORT="${HTTP_PORT:-}"
HTTPS_PORT="${HTTPS_PORT:-}"
SITES_AVAILABLE_DIR="${SITES_AVAILABLE_DIR:-$STATE_DIR/sites-available}"
SITES_ENABLED_DIR="${SITES_ENABLED_DIR:-$STATE_DIR/sites-enabled}"

if [ -z "$HTTP_PORT" ] && [ -z "$HTTPS_PORT" ]; then
  echo "At least one of \$HTTP_PORT or \$HTTPS_PORT must be set" >&2
  exit 1
fi

LISTEN_DIRECTIVES=""
[ -n "$HTTP_PORT" ] && LISTEN_DIRECTIVES="${LISTEN_DIRECTIVES}Listen $HTTP_PORT"$'\n'
[ -n "$HTTPS_PORT" ] && LISTEN_DIRECTIVES="${LISTEN_DIRECTIVES}Listen $HTTPS_PORT"$'\n'

PHP_MAX_EXECUTION_TIME_SEC="${PHP_MAX_EXECUTION_TIME_SEC:-300}"
PHP_MAX_UPLOAD_FILESIZE_MB="${PHP_MAX_UPLOAD_FILESIZE_MB:-64}"
PHP_MAX_MEMORY_LIMIT_MB="${PHP_MAX_MEMORY_LIMIT_MB:-192}"

EMAIL_DEFAULT_FROM_ADDRESS="${EMAIL_DEFAULT_FROM_ADDRESS:-}"
EMAIL_HOSTNAME="${EMAIL_HOSTNAME:-}"
EMAIL_PORT="${EMAIL_PORT:-}"
EMAIL_USER="${EMAIL_USER:-}"
EMAIL_PASSWORD="${EMAIL_PASSWORD:-}"

echo "STATE_DIR : $STATE_DIR"
echo "HTTP_PORT : ${HTTP_PORT:---not set, port not opened--}"
echo "HTTPS_PORT : ${HTTPS_PORT:---not set, port not opened--}"
echo "PHP_MAX_EXECUTION_TIME_SEC : $PHP_MAX_EXECUTION_TIME_SEC"
echo "PHP_MAX_UPLOAD_FILESIZE_MB : $PHP_MAX_UPLOAD_FILESIZE_MB"
echo "PHP_MAX_MEMORY_LIMIT_MB (must be at least 3 times PHP_MAX_UPLOAD_FILESIZE_MB) : $PHP_MAX_MEMORY_LIMIT_MB"
echo "EMAIL_HOSTNAME : $EMAIL_HOSTNAME"
echo "EMAIL_PORT : $EMAIL_PORT"
echo "EMAIL_USER : $EMAIL_USER"
if [ -n "$EMAIL_PASSWORD" ]; then
  echo "EMAIL_PASSWORD : --IS SET--"
else
  echo "EMAIL_PASSWORD : --IS NOT SET--"
fi

# --- Render templates into the (mutable) state dir ---------------------------

mkdir -p \
  "$STATE_DIR/home" \
  "$STATE_DIR/php-ini" \
  "$SITES_AVAILABLE_DIR" \
  "$SITES_ENABLED_DIR"

render() {
  local template="$1" output="$2"
  shift 2
  local content
  content="$(cat "$template")"
  while [ "$#" -gt 0 ]; do
    content="${content//@@$1@@/$2}"
    shift 2
  done
  printf '%s' "$content" > "$output"
}

PHP_FPM_SOCK="$STATE_DIR/php-fpm.sock"

render "$ASSETS_DIR/php-ini.template" "$STATE_DIR/php-ini/99-cloud.ini" \
  PHP_MAX_EXECUTION_TIME_SEC "$PHP_MAX_EXECUTION_TIME_SEC" \
  PHP_MAX_UPLOAD_FILESIZE_MB "$PHP_MAX_UPLOAD_FILESIZE_MB" \
  PHP_MAX_MEMORY_LIMIT_MB "$PHP_MAX_MEMORY_LIMIT_MB"

render "$ASSETS_DIR/php-fpm.conf.template" "$STATE_DIR/php-fpm.conf" \
  STATE_DIR "$STATE_DIR" \
  PHP_FPM_SOCK "$PHP_FPM_SOCK"

render "$ASSETS_DIR/httpd.conf.template" "$STATE_DIR/httpd.conf" \
  APACHE_HTTPD "$APACHE_HTTPD" \
  STATE_DIR "$STATE_DIR" \
  LISTEN_DIRECTIVES "$LISTEN_DIRECTIVES" \
  APACHE_MODULES_CONF "$STATE_DIR/apache-modules.conf" \
  SITES_ENABLED_DIR "$SITES_ENABLED_DIR"

render "$APACHE_MODULES_CONF" "$STATE_DIR/apache-modules.conf" \
  PHP_FPM_SOCK "$PHP_FPM_SOCK"

render "$ASSETS_DIR/msmtprc.template" "$STATE_DIR/msmtprc" \
  EMAIL_HOSTNAME "$EMAIL_HOSTNAME" \
  EMAIL_PORT "$EMAIL_PORT" \
  EMAIL_USER "$EMAIL_USER" \
  EMAIL_PASSWORD "$EMAIL_PASSWORD"
chmod 600 "$STATE_DIR/msmtprc"

if [ -n "$EMAIL_DEFAULT_FROM_ADDRESS" ]; then
  render "$ASSETS_DIR/sendmail-to-msmtp.json.template" "$STATE_DIR/sendmail-to-msmtp.json" \
    EMAIL_DEFAULT_FROM_ADDRESS "$EMAIL_DEFAULT_FROM_ADDRESS"
fi
export SENDMAIL_TO_MSMTP_CONFIG_PATH="$STATE_DIR/sendmail-to-msmtp.json"
export SENDMAIL_TO_MSMTP_MSMTP_PATH="$MSMTP_PATH"

# CRON_* env vars become a plain crontab file for supercronic (no user column -
# everything runs as the one invoking user).
: > "$STATE_DIR/crontab"
for cronname in "${!CRON_@}"; do
  echo "${!cronname}" >> "$STATE_DIR/crontab"
done

service_json() {
  local command="$1"
  cat <<EOF
    {
      "workingDirectory": "$STATE_DIR",
      "command": "$command"
    }
EOF
}

{
  echo '{'
  echo '  "services": ['
  service_json "php-fpm -F -O -y '$STATE_DIR/php-fpm.conf'"
  if [ -s "$STATE_DIR/crontab" ]; then
    echo '    ,'
    service_json "supercronic '$STATE_DIR/crontab'"
  fi
  echo '    ,'
  service_json "httpd -X -f '$STATE_DIR/httpd.conf'"
  echo '  ]'
  echo '}'
} > "$STATE_DIR/config.json"

export STATE_DIR
export HOME="$STATE_DIR/home"
export SENDMAIL_TO_MSMTP_MSMTPRC_PATH="$STATE_DIR/msmtprc"
# $PHP_PACKAGE/lib is where php.withExtensions puts the generated ini that
# actually loads gd/intl/mbstring/etc - PHP_INI_SCAN_DIR must include it or
# those extensions silently stop loading.
export PHP_INI_SCAN_DIR="$PHP_PACKAGE/lib:$STATE_DIR/php-ini"
export MAGICK_CONFIGURE_PATH="$ASSETS_DIR"

echo "[start] starting php-fpm, apache$( [ -s "$STATE_DIR/crontab" ] && echo ", supercronic" ) via services-execution"
exec "$SERVICES_EXECUTION" "$STATE_DIR/config.json"
