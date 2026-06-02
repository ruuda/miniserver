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
  (import ./nixpkgs-pinned.nix) {
    # Outline is BSL-licensed, we need to explicitly acknowledge this.
    # We're only using it for internal use so it's okay.
    config.allowUnfree = true;
  }
}:

let
  # NixOS ships multiple versions of LibreSSL at the same time, and the default
  # one is not always the latest one. However, if we pick one explicitly, we
  # also have to update it explicitly. I'll take the default and submit a PR for
  # Nixpkgs when it is outdated, or update here when needed.
  libressl = pkgs.libressl;

  outline = pkgs.outline;
  rauthy = pkgs.rauthy;
  valkey = pkgs.valkey;

  lego = pkgs.lego.overrideAttrs (old: {
    patches = [ ./patches/0001-Allow-group-owner-to-read-certificates.patch ];
  });

  nsd = (pkgs.nsd.override {
    openssl = libressl;
    withSystemd = false;
    bind8Stats = true;
    zoneStats = true;
  }).overrideDerivation (oldAttrs: {
    # Until https://github.com/NixOS/nixpkgs/pull/489566 is merged.
    nativeBuildInputs = [ pkgs.pkg-config ];
  });

  # Reconfigure Postgres to not be so heavy, we don't use all this stuff anyway.
  # With extensions or JIT, initdb cannot find the postgres binary, but we don't
  # care so much about JIT at this point.
  postgres = (pkgs.postgresql_18.override {
    curlSupport = false;
    gssSupport = false;
    jitSupport = false;
    ldapSupport = false;
    nlsSupport = false;
    numaSupport = false;
    pamSupport = false;
    perlSupport = false;
    pythonSupport = false;
    tclSupport = false;
    selinuxSupport = false;
    # We could slim it down further by omitting systemd support, but alright,
    # this is fairly heavy already, let's just have it.
    systemdSupport = true;
    uringSupport = true;
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

  # Put together the filesystem by copying from and symlinking to the Nix store.
  # Later we build this into an image with `mkfs.erofs`. Symlinks are included
  # verbatim, so we place symlinks into `/nix/store`, not into `$out`. When the
  # resulting image is mounted, they link to the right places.
  buildImageDir = { pkg, extraPackages, extraBuildCommand }:
    let
      inputs = [ pkg ] ++ extraPackages;
    in
      pkgs.stdenv.mkDerivation {
        name = "miniserver-${pkg.name}.fs";
        buildInputs = inputs;
        buildCommand = ''
          # Although we only need /nix/store and /usr/bin, we need to create the
          # other directories too so systemd can mount the API virtual filesystems
          # there, when the image is used. For /var, for systemd-nspawn only /var is
          # sufficient, but in a unit with PrivateTmp=true, we also need /var/tmp,
          # because systemd mounts a tmpfs there. /run is not needed by the systemd
          # unit, but it is required by systemd-nspawn, so we add it too.
          mkdir -p $out/dev
          mkdir -p $out/etc/ssl/certs
          mkdir -p $out/nix/store
          mkdir -p $out/proc
          mkdir -p $out/run
          mkdir -p $out/sys
          mkdir -p $out/tmp
          mkdir -p $out/usr/bin
          mkdir -p $out/usr/share/ca-certificates
          mkdir -p $out/var/log/journal
          mkdir -p $out/var/tmp

          touch $out/etc/resolv.conf
          touch $out/etc/passwd
          touch $out/etc/group
          ln -s /usr/bin $out/bin

          ${extraBuildCommand}

          closureInfo=${pkgs.closureInfo { rootPaths = inputs; }}
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

          # Also for libidn2, we don't need those locales, we are only running Nginx.
          cd $out${pkgs.libidn2.out}/share/locale
          chmod --recursive +w .
          rm -r *
          chmod -w .
        '';
      };

  buildImage = { label, pkg, extraBuildCommand, extraPackages ? [] }:
  assert builtins.stringLength label <= 15;
  pkgs.stdenv.mkDerivation rec {
    name = "${pkg.name}-verity";
    imageName = "${pkg.name}.img";
    imageDir = buildImageDir { inherit pkg extraPackages extraBuildCommand; };

    nativeBuildInputs = [ pkgs.cryptsetup pkgs.erofs-utils pkgs.jq pkgs.python3 ];
    buildInputs = [ imageDir ];

    # Make Nix dump the details of the closure of the packages as part of the
    # NIX_ATTRS_JSON_FILE.
    __structuredAttrs = true;
    exportReferencesGraph.pkgClosure = [ pkg ] ++ extraPackages;

    # There is no significant size difference between level=6 and level=12,
    # though there is a significant difference in compression time. So we opt
    # for the faster mode.
    buildCommand =
      ''
      mkdir -p $out
      mkfs.erofs $out/${imageName} ${imageDir} -L ${label} -zlz4hc,level=6
      veritysetup format \
        --uuid=$(python3 ${./deterministic_uuid.py} uuid $out/${imageName}) \
        --salt=$(python3 ${./deterministic_uuid.py} salt $out/${imageName}) \
        --root-hash-file=$out/${imageName}.roothash \
        $out/${imageName} $out/${imageName}.verity

      # Include closure information about the packages stored in the filesystem
      # image. We can use this to detect changes between version bumps, and to
      # build an SBOM.
      jq .pkgClosure $NIX_ATTRS_JSON_FILE > $out/packages.json
      '';
  };

  imageNginx = buildImage rec {
    label = "miniserver-ngx";
    pkg = customNginx;
    extraBuildCommand =
      ''
      mkdir -p $out/etc/nginx
      mkdir -p $out/var/lib/lego/certificates
      mkdir -p $out/var/log/nginx
      mkdir -p $out/var/www
      ln -s ${pkg}/bin/nginx $out/usr/bin/nginx
      '';
  };

  imageLego = buildImage rec {
    label = "miniserver-lego";
    pkg = lego;
    extraBuildCommand =
      ''
      mkdir -p $out/var/lib/lego/certificates
      mkdir -p $out/var/www/acme
      touch $out/etc/lego.conf
      ln -s ${pkg}/bin/lego $out/usr/bin/lego
      '';
  };

  # TODO: This package brings in OpenSSL in addition to LibreSSL, and also Bash!
  # Need to get rid of that!
  imageNsd = buildImage rec {
    label = "miniserver-nsd";
    pkg = nsd;
    extraBuildCommand =
      ''
      mkdir -p $out/etc/nsd
      ln -s ${pkg}/bin/nsd $out/usr/bin/nsd
      '';
  };

  imagePostgres = buildImage rec {
    label = "miniserver-pg";
    pkg = postgres;
    extraBuildCommand =
      ''
      mkdir -p $out/var/lib/postgres/data
      mkdir -p $out/var/log/postgres
      mkdir -p $out/run/postgres
      mkdir -p $out/usr/lib
      touch $out/var/lib/postgres/data/pg_hba.conf
      touch $out/var/lib/postgres/data/postgresql.conf
      ln -s ${pkg}/bin/* $out/usr/bin
      ln -s ${pkg}/lib/* $out/usr/lib
      ln -s ${pkg}/share/postgresql $out/usr/share
      ln -s ${pkgs.bash}/bin/bash $out/usr/bin/sh
      '';

    # Unfortunately, initdb invokes /bin/sh, so we need a shell.
    extraPackages = [ pkgs.bash ];
  };

  imageOutline = buildImage rec {
    label = "miniserver-otln";
    pkg = outline;
    extraBuildCommand =
      ''
      mkdir -p $out/etc/outline
      mkdir -p $out/run/outline
      mkdir -p $out/var/lib/outline
      ln -s ${pkg}/bin/outline-server $out/usr/bin/outline-server

      # Outline binaries try to read /build, ensure it exists inside the chroot.
      ln -s ${pkg}/share/outline/build $out/build
      '';
  };

  imageRauthy = buildImage rec {
    label = "miniserver-rth";
    pkg = rauthy;
    extraBuildCommand =
      ''
      mkdir -p $out/etc/rauthy
      mkdir -p $out/run/rauthy
      mkdir -p $out/var/lib/rauthy
      ln -s ${pkg}/bin/rauthy $out/usr/bin/rauthy
      '';
  };

  # TODO: I would really prefer to run Redict, but it's been abandoned in Nixpkgs.
  # It's trivial to build, so maybe I can revive and adopt the package.
  imageValkey = buildImage {
    label = "miniserver-vkey";
    pkg = valkey;
    extraBuildCommand =
      ''
      mkdir -p $out/etc/valkey
      mkdir -p $out/var/lib/valkey
      ln -s ${valkey}/bin/valkey-server $out/usr/bin/valkey-server
      '';
  };
in
  pkgs.stdenv.mkDerivation {
    name = "miniserver.json";
    nativeBuildInputs = [ pkgs.python3 ];
    buildCommand =
      ''
      python3 ${./build_manifest.py} \
        lego=${imageLego} \
        nginx=${imageNginx} \
        nsd=${imageNsd} \
        outline=${imageOutline} \
        postgres=${imagePostgres} \
        rauthy=${imageRauthy} \
        valkey=${imageValkey} \
        > $out
      '';
  }
