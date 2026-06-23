# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pkgs = (import ./nixpkgs-pinned.nix) {};
  erofs = (import ./../../build-erofs.nix) { inherit pkgs; };
in
  erofs.buildImageManifest rec {
    name = "rauthy";
    pkg = pkgs.rauthy;
    extraBuildCommand =
      ''
      mkdir -p $out/etc/rauthy
      mkdir -p $out/run/rauthy
      mkdir -p $out/var/lib/rauthy
      ln -s ${pkg}/bin/rauthy $out/usr/bin/rauthy
      '';
  }
