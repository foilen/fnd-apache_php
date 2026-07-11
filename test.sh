#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

mkdir -p _test/log _test/sites-available _test/sites-enabled _test/www-1

cat > _test/sites-available/localhost-1.conf << _EOF
<VirtualHost *:8080>
    ServerName localhost-1.foilen.com

    DocumentRoot $PWD/_test/www-1
    <Directory $PWD/_test/www-1/>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog "|/bin/sh -c 'exec rotatelogs -n 1 $PWD/_test/log/localhost-1.foilen.com-error.log 100M'"
    CustomLog "|/bin/sh -c 'exec rotatelogs -n 1 $PWD/_test/log/localhost-1.foilen.com-access.log 100M'" combined
</VirtualHost>
_EOF

cat > _test/www-1/index.php << _EOF
<?php
echo phpversion();
_EOF

ln -sf ../sites-available/localhost-1.conf _test/sites-enabled/

cleanup() {
    if [ -n "${APP_PID:-}" ] && kill -0 "$APP_PID" 2>/dev/null; then
        kill "$APP_PID"
        wait "$APP_PID" 2>/dev/null || true
    fi
    rm -rf _test
}
trap cleanup EXIT

SITES_AVAILABLE_DIR=$PWD/_test/sites-available \
SITES_ENABLED_DIR=$PWD/_test/sites-enabled \
HTTP_PORT=8080 \
nix --extra-experimental-features 'nix-command flakes' run . &
APP_PID=$!

for i in $(seq 1 60); do
    if curl -s -o /dev/null http://127.0.0.1:8080/; then
        break
    fi
    sleep 1
done

echo "Response:"
curl -sf http://127.0.0.1:8080/
echo
