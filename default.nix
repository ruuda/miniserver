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
    libressl = libressl_2_8;
  };

  h2o = pkgs.h2o.override {
    libressl = libressl_2_8;
  };

  # Put together the filesystem by copying from and symlinking to the Nix store.
  # We need to do this, because unfortunately, "mksquashfs /foo/bar" will create
  # a file system with bar in the root. So we cannot pass absolute paths to the
  # store. To work around this, copy all of them, so we can run mksquashfs on
  # the properly prepared directory. Then for symlinks, they are copied
  # verbatim, with the path inside the $out directory. So these we symlink
  # directly to the store, not to the copies in $out. So in the resulting image,
  # those links will point to the right places.
  imageDir = stdenv.mkDerivation {
    name = "miniserver-filesystem";
    buildInputs = [ h2o acme-client ];
    buildCommand = ''
      # Although we only need /nix/store and /usr/bin, we need to create the
      # other directories too so systemd can mount the API virtual filesystems
      # there, when the image is used. For /var, for systemd-nspawn only /var is
      # sufficient, but in a unit with PrivateTmp=true, we also need /var/tmp,
      # because systemd mounts a tmpfs there. /run is not needed by the systemd
      # unit, but it is required by systemd-nspawn, so we add it too.
      mkdir -p $out/dev
      mkdir -p $out/etc/h2o
      mkdir -p $out/nix/store
      mkdir -p $out/proc
      mkdir -p $out/run
      mkdir -p $out/sys
      mkdir -p $out/tmp
      mkdir -p $out/usr/bin
      mkdir -p $out/var/log/h2o
      mkdir -p $out/var/tmp
      mkdir -p $out/var/www
      ln -s /usr/bin $out/bin
      ln -s ${h2o}/bin/h2o $out/usr/bin/h2o
      ln -s ${acme-client}/bin/acme-client $out/usr/bin/acme-client
      closureInfo=${closureInfo { rootPaths = [ h2o acme-client ]; }}
      for file in $(cat $closureInfo/store-paths); do
        echo "copying $file"
        cp --archive $file $out/nix/store
      done
    '';
  };
in
  stdenv.mkDerivation {
    name = "miniserver.img";

    nativeBuildInputs = [ squashfsTools ];
    buildInputs = [ imageDir ];

    buildCommand =
      ''
        # Generate the squashfs image. Pass the -no-fragments option to make
        # the build reproducible; apparently splitting fragments is a
        # nondeterministic multithreaded process. Also set processors to 1 for
        # the same reason.
        mksquashfs ${imageDir} $out \
          -no-fragments      \
          -processors 1      \
          -all-root          \
          -b 1048576         \
          -comp xz           \
          -Xdict-size 100%   \
      '';
  }
