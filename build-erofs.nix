# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

{ pin }: rec {
  pkgs = import pin.tarball {};

  # Put together the filesystem by copying from and symlinking to the Nix store.
  # Later we build this into an image with `mkfs.erofs`. Symlinks are included
  # verbatim, so we place symlinks into `/nix/store`, not into `$out`. When the
  # resulting image is mounted, they link to the right places.
  buildImageDir = {
    # The main package to build the filesystem for.
    pkg,

    # Additional packages to include in the closure, for example a shell if the
    # program in the main package tries to exec a shell.
    extraPackages,

    # Commands to run to modify the filesystem at $out, for example to add
    # additional symlinks.
    extraBuildCommand,

    # Whether to reduce the filesystem size by deleting unneeded files such as
    # locales from the glibc store paths. This might break applications that
    # do need those files.
    minimize,
  }:
    let
      inputs = [ pkg ] ++ extraPackages;
    in
      pkgs.stdenv.mkDerivation {
        name = "${pkg.name}-fs";
        buildInputs = inputs;
        inherit minimize;
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

          # The steps below minimize the filesystem size. If that is not
          # requested, we are done here.
          if [ -z "$minimize" ]; then
            exit 0
          fi

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

  buildImage = {
    label,
    pkg,
    extraBuildCommand,
    extraPackages,
    minimize,
  }:
    # EROFS filesystem labels can be at most 15 characters long.
    assert builtins.stringLength label <= 15;
    pkgs.stdenv.mkDerivation rec {
      name = "${pkg.name}-image";
      imageName = "${pkg.name}.img";
      imageDir = buildImageDir { inherit pkg extraPackages extraBuildCommand minimize; };

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

  buildImageManifest = {
    name,
    pkg,
    extraBuildCommand,
    extraPackages ? [],
    minimize ? false,
  }:
    let
      image = buildImage {
        label = name;
        inherit pkg extraBuildCommand extraPackages minimize;
      };
    in
      pkgs.stdenv.mkDerivation {
        name = "${pkg.name}-image.json";
        nativeBuildInputs = [ pkgs.python3 ];
        buildCommand = ''
          python3 ${./build_manifest.py} \
            ${name} ${image} \
            ${pin.commit} ${pin.commit_date} > $out
        '';
      };
}
