# Miniserver -- Nginx and Acme-client on CoreOS.
# Copyright 2018 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

{ pkgs ?
  # Default to a pinned version of Nixpkgs. The actual revision of the Nixpkgs
  # repository is stored in a separate file (as a fetchTarball Nix expression).
  # We then fetch that revision from Github and import it. The revision should
  # periodically be updated to be the last commit of Nixpkgs.
  import (import ./nixpkgs-pinned.nix) {}
}:

with pkgs;
let
  # NixOS ships multiple versions of LibreSSL at the same time, and the default
  # one is not always the latest one. So opt for the latest one explicitly.
  acme-client = pkgs.acme-client.override {
    libressl = libressl_2_9;
  };

  lightNginx = nginxMainline.override {
    # Remove dependency on libgd; It brings in a lot of transitive dependencies
    # that we don't need (fontconfig, image codecs, etc.). Also disable other
    # unnecessary dependencies.
    gd = null;
    withStream = false;
    withMail = false;

    # Build Nginx against LibreSSL, rather than OpenSSL. This reduces the size
    # of the image, as we don't have to include both OpenSSL and LibreSSL. But
    # more importantly, I trust LibreSSL more than I trust OpenSSL. Take the
    # latest LibreSSL (2.9 at the time of writing), the default in NixOS is
    # often an older version, but the latest one is generally available as
    # opt-in.
    openssl = libressl_2_9;
  };

  ngxBrotli = fetchFromGitHub {
    owner = "google";
    repo = "ngx_brotli";
    sha256 = "04yx1n0wi3l2x37jd1ynl9951qxkn8xp42yv0mfp1qz9svips81n";
    rev = "bfd2885b2da4d763fed18f49216bb935223cd34b";
    fetchSubmodules = true;
  };

  defaultPage = writeText "about.html" ''
    <!DOCTYPE html>
    <html>
    <head>
    <title>Welcome to Miniserver!</title>
    <style>body { width: 35em; margin: 0 auto; font-family: sans-serif; }</style>
    </head>
    <body>
    <h1>Welcome to Miniserver!</h1>
    <p>If you see this page, the nginx web server is successfully installed and
    working. Further configuration is required.</p>
    <p>For online documentation and support please refer to
    <a href="http://nginx.org/">nginx.org</a>.<br/>
    </body>
    </html>
  '';

  defaultNginxConfig = writeText "nginx.conf" ''
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
      access_log /var/log/nginx/access.log combined;

      server {
        listen 80;
        server_name localhost;
        location / {
          root html;
          index index.html;
        }
      }

      # TODO: include /etc/nginx/conf.d/*;
      # TODO: include /etc/nginx/sites-enabled/*;
    }
  '';

  customNginx = lightNginx.overrideDerivation (oldAttrs: {
    # Override the light nginx package to cut down on the dependencies further.
    # I also want to get rid of geoip and all of the xml stuff, but the package
    # offers no options for that. Furthermore, enable the ngx_brotli module.
    configureFlags = [
      "--with-http_ssl_module"
      "--with-http_v2_module"
      "--with-http_gzip_static_module"
      "--with-threads"
      "--with-pcre-jit"
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

  dockerImage = pkgs.dockerTools.buildImage {
    name = "miniserver";
    tag = "latest";
    contents = customNginx;
    config.ExposedPorts = {
      "80/tcp" = {};
      "443/tcp" = {};
    };
    config.EntryPoint = "${customNginx}/bin/nginx";
  };
in
  stdenv.mkDerivation {
    name = "miniserver.aci";
    nativeBuildInputs = [ skopeo ];
    buildCommand =
      ''
        # Use Skopeo to convert the Docker image that Nix generates into an OCI
        # image that rkt can run natively.
        skopeo copy --format=oci "tarball:${dockerImage}" "oci-archive:$out"
      '';
  }
