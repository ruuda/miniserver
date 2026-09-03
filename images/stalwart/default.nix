# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pin = import ./nixpkgs-pinned.nix;
  pkgs = import pin.tarball {};
  erofs = (import ./../../build-erofs.nix) { inherit pin; };

  # TODO: We could shrink the closure a bit by removing the storage backends
  # that we don't use. E.g. it has Rocksdb in the closure, but if we only use
  # SQLite, we could drop it. We could also disable the Rust feature, which
  # might save a bit in code size.
  stalwart = pkgs.stalwart_0_16;
in
  erofs.buildImageManifest rec {
    name = "stalwart";
    pkg = stalwart;
    minimize = false;
    extraBuildCommand =
      ''
      mkdir -p $out/var/lib/stalwart
      mkdir -p $out/run/stalwart
      ln -s ${pkg}/bin/stalwart $out/usr/bin/stalwart
      '';
  }
