# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pin = import ./nixpkgs-pinned.nix;
  pkgs = import pin.tarball {
    # Outline is BSL-licensed, we need to explicitly acknowledge this.
    # We're only using it for internal use so it's okay.
    config.allowUnfree = true;
  };
  erofs = (import ./../../build-erofs.nix) { inherit pin; };
in
  erofs.buildImageManifest rec {
    name = "outline";
    pkg = pkgs.outline;
    extraPackages = [ pkgs.bash ];
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
  }
