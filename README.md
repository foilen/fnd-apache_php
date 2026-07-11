# Description

An Apache + PHP environment with a lot of PHP extensions installed and also a sendmail replacement that supports a lot of different ways of sending emails with PHP.

The sendmail replacement is https://github.com/foilen/sendmail-to-msmtp .

The PHP header to tell the application that it is protected by HTTPS is set when the load-balancer tells it that it is protected.

`nix run` provides Apache, PHP-FPM, msmtp, cron (via supercronic), ImageMagick, etc, and runs them directly on the host.

PHP is served through PHP-FPM over a unix socket via `mod_proxy_fcgi`, wired up globally in the generated Apache config - vhost confs in `sites-available`/`sites-enabled` don't need any PHP-specific directives.

# Quick start

This project uses [Nix flakes](https://nixos.wiki/wiki/Flakes), so all the tools (Apache, PHP-FPM, etc) are provided by `nix run` - nothing else needs to be installed, and no local checkout is needed.

```
mkdir -p _run/sites-available _run/sites-enabled site-1
echo '<?php echo "Hello, World!";' > site-1/index.php

export HTTP_PORT=8080
cat > _run/sites-available/site-1.conf << _EOF
<VirtualHost *:$HTTP_PORT>
    ServerName site-1.localhost

    DocumentRoot $PWD/site-1
    <Directory $PWD/site-1/>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
_EOF

ln -s ../sites-available/site-1.conf _run/sites-enabled/

nix run github:foilen/fnd-apache_php
```

Then, in another terminal:

```
curl http://127.0.0.1:8080/
```

should print `Hello, World!`. See the sections below for all the available environment config (ports, extra bind paths, PHP limits, email, cron, etc).

To install it once and run it as a regular command (e.g. on a server), use `nix profile install` instead - this puts `fnd-apache_php` on your `PATH` via the Nix store:

```
nix profile install github:foilen/fnd-apache_php

fnd-apache_php
```

# Build and test

Run from a checkout with `nix run .`:

```
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
phpinfo();
_EOF

ln -s ../sites-available/localhost-1.conf _test/sites-enabled/

SITES_AVAILABLE_DIR=$PWD/_test/sites-available \
SITES_ENABLED_DIR=$PWD/_test/sites-enabled \
HTTP_PORT=8080 \
nix run .

curl http://127.0.0.1:8080/
```

Note: Apache's piped-log spawn doesn't search `$PATH`, so `rotatelogs` can't be called by bare name directly - wrap it in `/bin/sh -c '...'` so the shell (which inherits `nix run`'s `$PATH`) resolves it.

# Available environment config and their defaults

- STATE_DIR=./_run
    - Where generated runtime config (httpd.conf, php-fpm.conf, msmtprc, crontab, etc) is written. Must be writable.
- HTTP_PORT
- HTTPS_PORT
    - No defaults - each port is only opened (a `Listen` directive is added) if its env var is set. At least one of the two must be set.
    - Binding 80/443 needs root or `cap_net_bind_service`. Put a reverse proxy in front if you need the standard ports.
- SITES_AVAILABLE_DIR=$STATE_DIR/sites-available
- SITES_ENABLED_DIR=$STATE_DIR/sites-enabled

- PHP_MAX_EXECUTION_TIME_SEC=300
- PHP_MAX_UPLOAD_FILESIZE_MB=64
- PHP_MAX_MEMORY_LIMIT_MB=192
    - must be at least 3 times PHP_MAX_UPLOAD_FILESIZE_MB

- EMAIL_DEFAULT_FROM_ADDRESS
- EMAIL_HOSTNAME
- EMAIL_PORT
- EMAIL_USER
- EMAIL_PASSWORD

## Cron

You can provide cron lines with environment variables starting with "CRON_". Unlike a system-cron setup, there is no user column - everything runs as the one invoking user, and jobs are run by [supercronic](https://github.com/aptible/supercronic). Eg:
- 'CRON_1=* * * * * echo yay | tee /tmp/yay_cron.log'

## TLS / Let's Encrypt

Not automated. There's no `certbot` Apache plugin in nixpkgs, so provisioning certificates (e.g. via `certbot certonly --webroot`) and wiring up an SSL vhost is left to you - point it at whatever cert/key paths you obtained, same as any other Apache SSL vhost.

# Release

```
./step-git-tag.sh 8.4.11
git push --tags
```
