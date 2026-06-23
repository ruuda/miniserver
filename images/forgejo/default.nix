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
  erofs.buildImageManifest rec {
    name = "forgejo";
    pkg = pkgs.forgejo;
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
  }
