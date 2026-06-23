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
  forgejo = pkgs.forgejo;
  outline = pkgs.outline;
  rauthy = pkgs.rauthy;
  valkey = pkgs.valkey;

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

  imageForgejo = buildImage rec {
    label = "miniserver-fj";
    pkg = forgejo;
    extraBuildCommand =
      ''
      mkdir -p $out/var/lib/forgejo
      mkdir -p $out/var/log/forgejo
      mkdir -p $out/etc/forgejo
      mkdir -p $out/home/git
      ln -s ${pkg}/bin/forgejo $out/usr/bin
      ln -s ${pkgs.git}/bin/* $out/usr/bin
      ln -s ${pkgs.git-lfs}/bin/* $out/usr/bin

      # Forgejo creates .git/hooks that use `/usr/bin/env bash` as #! line,
      # and those scripts rely on `cat` and `basename`, so let's just pull in
      # the entire coreutils.
      ln -s ${pkgs.coreutils}/bin/* $out/usr/bin
      ln -s ${pkgs.bash}/bin/bash $out/usr/bin/bash
      '';

      extraPackages = with pkgs; [ bash coreutils git git-lfs ];
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

      # Outline binaries try to read /build. We make it available in
      # at /share/outline, so the working directory must point there. This is
      # also required for the migrations to work.
      ln -s ${pkg}/share/outline $out/usr/share

      # Migrations try to execute `/bin/sh`. `/bin` points to `/usr/bin`.
      ln -s ${pkgs.bash}/bin/bash $out/usr/bin/sh
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
        forgejo=${imageForgejo} \
        outline=${imageOutline} \
        postgres=${imagePostgres} \
        rauthy=${imageRauthy} \
        valkey=${imageValkey} \
        > $out
      '';
  }
