{
  description = "Apache + PHP environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
    sendmail-to-msmtp-src = {
      url = "github:foilen/sendmail-to-msmtp";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    services-execution-src = {
      url = "github:foilen/services-execution";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, flake-utils, sendmail-to-msmtp-src, services-execution-src }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        # PHP with the extensions needed by this project.
        php = pkgs.php.withExtensions (
          { enabled, all }:
          enabled
          ++ (with all; [
            gd
            intl
            mbstring
            opcache
            pdo
            pdo_mysql
            mysqli
            xml
            zip
          ])
        );

        # Sendmail replacement that bridges to msmtp: https://github.com/foilen/sendmail-to-msmtp
        sendmail-to-msmtp = sendmail-to-msmtp-src.packages.${system}.default;

        # Process supervisor that runs php-fpm/supercronic/apache from a
        # generated config.json: https://github.com/foilen/services-execution
        services-execution = services-execution-src.packages.${system}.default;

        # Static part of the Apache config: modules to load and the global
        # PHP-FPM handler, so vhost confs in sites-available/ need no
        # PHP-specific directives.
        apacheModulesConf = pkgs.writeText "apache-modules.conf" ''
          LoadModule mpm_event_module ${pkgs.apacheHttpd}/modules/mod_mpm_event.so
          LoadModule authz_core_module ${pkgs.apacheHttpd}/modules/mod_authz_core.so
          LoadModule authz_host_module ${pkgs.apacheHttpd}/modules/mod_authz_host.so
          LoadModule authn_core_module ${pkgs.apacheHttpd}/modules/mod_authn_core.so
          LoadModule dir_module ${pkgs.apacheHttpd}/modules/mod_dir.so
          LoadModule mime_module ${pkgs.apacheHttpd}/modules/mod_mime.so
          LoadModule log_config_module ${pkgs.apacheHttpd}/modules/mod_log_config.so
          LoadModule unixd_module ${pkgs.apacheHttpd}/modules/mod_unixd.so
          LoadModule alias_module ${pkgs.apacheHttpd}/modules/mod_alias.so
          LoadModule autoindex_module ${pkgs.apacheHttpd}/modules/mod_autoindex.so
          LoadModule env_module ${pkgs.apacheHttpd}/modules/mod_env.so
          LoadModule setenvif_module ${pkgs.apacheHttpd}/modules/mod_setenvif.so
          LoadModule headers_module ${pkgs.apacheHttpd}/modules/mod_headers.so
          LoadModule http2_module ${pkgs.apacheHttpd}/modules/mod_http2.so
          LoadModule proxy_module ${pkgs.apacheHttpd}/modules/mod_proxy.so
          LoadModule proxy_fcgi_module ${pkgs.apacheHttpd}/modules/mod_proxy_fcgi.so
          LoadModule rewrite_module ${pkgs.apacheHttpd}/modules/mod_rewrite.so
          LoadModule ssl_module ${pkgs.apacheHttpd}/modules/mod_ssl.so
          LoadModule allowmethods_module ${pkgs.apacheHttpd}/modules/mod_allowmethods.so
          LoadModule access_compat_module ${pkgs.apacheHttpd}/modules/mod_access_compat.so

          TypesConfig ${pkgs.apacheHttpd}/conf/mime.types

          DirectoryIndex index.php index.html

          <FilesMatch \.php$>
              SetHandler "proxy:unix:@@PHP_FPM_SOCK@@|fcgi://localhost/"
          </FilesMatch>
        '';
      in
      let
        # Binaries that must be reachable on PATH by server.sh. sendmail-to-msmtp
        # must come before msmtp: both ship a `sendmail` binary and callers
        # should get ours.
        runtimePath = pkgs.lib.makeBinPath [
          pkgs.apacheHttpd
          php
          pkgs.supercronic
          sendmail-to-msmtp
          pkgs.msmtp
          pkgs.imagemagick
        ];
      in
      {
        packages = {
          inherit sendmail-to-msmtp apacheModulesConf services-execution;

          # Runnable/installable app: `nix run github:foilen/fnd-apache_php` or
          # `nix profile install github:foilen/fnd-apache_php`. Serves whatever
          # site config is found relative to the current directory (same
          # defaults as assets/start.sh), without needing a local checkout.
          default = pkgs.writeShellApplication {
            name = "fnd-apache_php";
            text = ''
              export APACHE_HTTPD="${pkgs.apacheHttpd}"
              export PHP_PACKAGE="${php}"
              export SENDMAIL_TO_MSMTP="${sendmail-to-msmtp}"
              export MSMTP_PATH="${pkgs.msmtp}/bin/msmtp"
              export APACHE_MODULES_CONF="${apacheModulesConf}"
              export SERVICES_EXECUTION="${services-execution}/bin/execution"
              export PATH="${runtimePath}:$PATH"
              exec "${self}/assets/start.sh" "$@"
            '';
          };
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/fnd-apache_php";
        };
      }
    );
}
