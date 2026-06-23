# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pin = import ./nixpkgs-pinned.nix;
  pkgs = import pin.tarball {};
  erofs = (import ./../../build-erofs.nix) { inherit pin; };
in
  # TODO: I would really prefer to run Redict, but it's been abandoned in Nixpkgs.
  # It's trivial to build, so maybe I can revive and adopt the package.
  erofs.buildImageManifest rec {
    name = "valkey";
    pkg = pkgs.valkey;
    extraBuildCommand =
      ''
      mkdir -p $out/etc/valkey
      mkdir -p $out/var/lib/valkey
      ln -s ${pkg}/bin/valkey-server $out/usr/bin/valkey-server
      '';
  }
