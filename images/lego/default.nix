# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pin = import ./nixpkgs-pinned.nix;
  pkgs = import pin.tarball {};
  erofs = (import ./../../build-erofs.nix) { inherit pin; };

  lego = pkgs.lego.overrideAttrs (old: {
    patches = [ ./0001-Allow-group-owner-to-read-certificates.patch ];
  });
in
  erofs.buildImageManifest rec {
    name = "lego";
    pkg = lego;
    minimize = true;
    extraBuildCommand =
      ''
      mkdir -p $out/var/lib/lego/certificates
      mkdir -p $out/var/www/acme
      touch $out/etc/lego.conf
      ln -s ${pkg}/bin/lego $out/usr/bin/lego
      '';
  }
