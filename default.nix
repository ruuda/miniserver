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
  (import ./nixpkgs-pinned.nix) {}
}:

let
  # NixOS ships multiple versions of LibreSSL at the same time, and the default
  # one is not always the latest one. However, if we pick one explicitly, we
  # also have to update it explicitly. I'll take the default and submit a PR for
  # Nixpkgs when it is outdated, or update here when needed.
  libressl = pkgs.libressl;

  lego = pkgs.lego.overrideAttrs (old: {
    patches = [ ./patches/0001-Allow-group-owner-to-read-certificates.patch ];
  });

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

  # Put together the filesystem by copying from and symlinking to the Nix store.
  # We need to do this, because unfortunately, "mksquashfs /foo/bar" will create
  # a file system with bar in the root. So we cannot pass absolute paths to the
  # store. To work around this, copy all of them, so we can run mksquashfs on
  # the properly prepared directory. Then for symlinks, they are copied
  # verbatim, with the path inside the $out directory. So these we symlink
  # directly to the store, not to the copies in $out. So in the resulting image,
  # those links will point to the right places.
  imageDir = pkgs.stdenv.mkDerivation {
    name = "miniserver-filesystem";
    buildInputs = [ customNginx lego ];
    buildCommand = ''
      # Although we only need /nix/store and /usr/bin, we need to create the
      # other directories too so systemd can mount the API virtual filesystems
      # there, when the image is used. For /var, for systemd-nspawn only /var is
      # sufficient, but in a unit with PrivateTmp=true, we also need /var/tmp,
      # because systemd mounts a tmpfs there. /run is not needed by the systemd
      # unit, but it is required by systemd-nspawn, so we add it too.
      mkdir -p $out/dev
      mkdir -p $out/etc/nginx
      mkdir -p $out/etc/ssl/certs
      mkdir -p $out/nix/store
      mkdir -p $out/proc
      mkdir -p $out/run
      mkdir -p $out/sys
      mkdir -p $out/tmp
      mkdir -p $out/usr/bin
      mkdir -p $out/usr/share/ca-certificates
      mkdir -p $out/var/lib/lego/certificates
      mkdir -p $out/var/log/journal
      mkdir -p $out/var/log/nginx
      mkdir -p $out/var/tmp
      mkdir -p $out/var/www/acme
      touch $out/etc/lego.conf
      touch $out/etc/resolv.conf
      ln -s /usr/bin $out/bin
      ln -s ${customNginx}/bin/nginx $out/usr/bin/nginx
      ln -s ${lego}/bin/lego $out/usr/bin/lego
      closureInfo=${pkgs.closureInfo { rootPaths = [ customNginx lego ]; }}
      for file in $(cat $closureInfo/store-paths); do
        echo "copying $file"
        cp --archive $file $out/nix/store
      done

      # Slim down the glibc installation by removing unused locale data. We do
      # this here, and not in the glibc package, to avoid rebuilding everything
      # that depends on glibc. We need to make the containing directories
      # writable to be able to remove files from them.
      cd $out${pkgs.glibc}/share
      chmod --recursive +w .

      rm -fr locale
      mv i18n/locales/C i18n/locales_C
      rm i18n/locales/*
      mv i18n/locales_C i18n/locales/C

      # Delete all the charmaps, they consume a lot of space, and we do not use
      # them.
      rm i18n/charmaps/*.gz

      chmod --recursive -w .

      # Delete the gconv shared objects related to locales, the programs we run
      # do not use iconv.
      cd $out${pkgs.glibc}/lib/gconv
      chmod +w .
      rm *.so
      chmod -w .

      # Also for libidn2, we don't need those locales, we are only running
      # Nginx.
      cd $out${pkgs.libidn2.out}/share/locale
      chmod --recursive +w .
      rm -r *
      chmod -w .
    '';
  };

  image = pkgs.stdenv.mkDerivation {
    name = "miniserver.img";

    nativeBuildInputs = [ pkgs.squashfsTools pkgs.cryptsetup ];
    buildInputs = [ imageDir ];

    buildCommand =
      ''
        # Generate the squashfs image. Pass the -no-fragments option to make
        # the build reproducible; apparently splitting fragments is a
        # nondeterministic multithreaded process. Also set processors to 1 for
        # the same reason. Do not compress the inode table (-noI), nor the files
        # themselves (-noD), compression defeats sharing through chunking.
        # Disabling compression makes parts more likely to be shared across
        # updates. The xz compressed image is about 1/3 the size of the
        # uncompressed image, but we can do chunking first and compression later
        # to get bigger savings. Do use padding, omit the -nopad option. Without
        # it, systemd-nspawn on CoreOS would not mount the image, failing with
        # "short read while reading cgroup mode", which is probably a misleading
        # error message.
        mksquashfs ${imageDir} $out \
          -no-fragments      \
          -processors 1      \
          -all-root          \
          -noI               \
          -noD               \
          -b 1048576         \
      '';
  };


in
  pkgs.stdenv.mkDerivation {
    name = "miniserver";
    nativeBuildInputs = [ pkgs.cryptsetup pkgs.python3 ];
    buildCommand =
      ''
        mkdir -p $out
        cp ${image} $out/miniserver.img
        veritysetup format \
          --uuid=$(python3 ${./deterministic_uuid.py} uuid $out/miniserver.img) \
          --salt=$(python3 ${./deterministic_uuid.py} salt $out/miniserver.img) \
          --root-hash-file=$out/miniserver.img.roothash \
          $out/miniserver.img $out/miniserver.img.verity
      '';
  }
