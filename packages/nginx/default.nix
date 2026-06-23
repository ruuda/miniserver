# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pkgs = (import ./nixpkgs-pinned.nix) {};
  erofs = (import ./../../build-erofs.nix) { inherit pkgs; };

  libressl = pkgs.libressl;
  lightNginx = pkgs.nginxMainline.override {
    # Remove dependency on libgd; It brings in a lot of transitive dependencies
    # that we don't need (fontconfig, image codecs, etc.). Also disable other
    # unnecessary dependencies.
    gd = null;
    withStream = false;
    withMail = false;
    modules = [];

    # Build Nginx against LibreSSL, rather than OpenSSL. This reduces the size
    # of the image, as we don't have to include both OpenSSL and LibreSSL. But
    # more importantly, I trust LibreSSL more than I trust OpenSSL.
    openssl = libressl;
  };

  ngxBrotli = pkgs.fetchFromGitHub {
    owner = "google";
    repo = "ngx_brotli";
    sha256 = "sha256-ks5Ae9gCscEX8TkqK3LGiRl2twUt+chGfkrRhMXS7uc=";
    rev = "6e975bcb015f62e1f303054897783355e2a877dc";
    fetchSubmodules = true;
  };

  defaultNginxConfig = pkgs.writeText "nginx.conf" ''
    # Don't daemonize. This makes it easier to run under systemd, especially
    # with RootImage=, as there are no pidfiles to juggle around, and no
    # directories that we need to create or mount for that. It also simplifies
    # stopping, because systemd sends the right signal to the process directly.
    # See also https://nginx.org/en/docs/faq/daemon_master_process_off.html.
    daemon off;
    error_log /var/log/nginx/error.log;

    worker_processes auto;

    events {
      worker_connections 1024;
    }

    http {
      # Same log format as the default "combined" format, but including the host.
      log_format vhosts '$host: $remote_addr - $remote_user [$time_local] "$request" $status $body_bytes_sent "$http_referer" "$http_user_agent"';
      access_log /var/log/nginx/access.log vhosts;

      include /etc/nginx/sites-enabled/*;
    }
  '';

  customNginx = lightNginx.overrideDerivation (oldAttrs: {
    # Override the light nginx package to cut down on the dependencies further.
    # I also want to get rid of geoip and all of the xml stuff, but the package
    # offers no options for that. Furthermore, enable the ngx_brotli module.
    configureFlags = [
      "--with-http_ssl_module"
      "--with-http_v2_module"
      "--with-http_v3_module"
      "--with-http_auth_request_module"
      "--with-http_gzip_static_module"
      "--with-threads"
      "--with-pcre-jit"
      "--with-ipv6"
      "--add-module=ngx_brotli"
      # If the group is not set explicitly, the configure script will first look
      # for a "nobody" group in /etc/group and then fall back to "nogroup". To
      # keep the build reproducible and independent of /etc/group on the host
      # system, set the group explicitly.
      "--group=nogroup"
      # Configure default paths. They default to /nix/store/...-nginx/logs/*,
      # but that is inconvenient because we would need to update the systemd
      # unit every time (or generate it with Nix, but it is delivered outside of
      # the image, so that is not really an option). We also provide a
      # customized default config file that does not write logs to these paths.
      "--conf-path=${defaultNginxConfig}"
      # We don't run in daemon mode; there is no need to write a pidfile.
      "--pid-path=/dev/null"
      "--error-log-path=stderr" #/var/log/nginx/error.log"
      #"--http-log-path=/var/log/nginx/access.log"

      # Nginx writes some times writes things to temporary files, by default in
      # /nix/store/...nginx/client_body_temp, but that fails on the immutable
      # file system, so point it to /tmp (which is a ramdisk), and private to
      # Nginx anyway because we use PrivateTmp= in the systemd unit. Note that
      # the subdirectories do not actually exist.
      "--http-client-body-temp-path=/tmp/client_body_temp"
      "--http-fastcgi-temp-path=/tmp/fastcgi_temp"
      "--http-proxy-temp-path=/tmp/proxy_temp"
      "--http-scgi-temp-path=/tmp/scgi_temp"
      "--http-uwsgi-temp-path=/tmp/uwsgi_temp"
    ];

    # The nginx binary embeds its configure command line. If we would pass the
    # ngx_brotli module store path directly to --add-module, the store path
    # would therefore end up in the binary. That triggers Nix to detect the
    # ngx_brotli source as a runtime dependency, even though it is not. Work
    # around this issue by creating a symlink to the store path in the build
    # directory. Then the configure flags no longer include the path itself.
    preConfigure = oldAttrs.preConfigure + ''
      ln -s ${ngxBrotli} ngx_brotli
    '';
  });
in
  erofs.buildImageManifest rec {
    name = "nginx";
    pkg = customNginx;
    extraBuildCommand =
      ''
      mkdir -p $out/etc/nginx
      mkdir -p $out/var/lib/lego/certificates
      mkdir -p $out/var/log/nginx
      mkdir -p $out/var/www
      ln -s ${pkg}/bin/nginx $out/usr/bin/nginx
      '';
    minimize = true;
  }
