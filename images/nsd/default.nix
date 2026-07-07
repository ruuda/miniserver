# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pin = import ./nixpkgs-pinned.nix;
  pkgs = import pin.tarball {};
  erofs = (import ./../../build-erofs.nix) { inherit pin; };

  # Libevent by default pulls in OpenSSL. For NSD we do not need TLS support in
  # libevent itself, so just disable it.
  libevent = (pkgs.libevent.override {
    sslSupport = false;
    openssl = null;
  });

  nsd = (pkgs.nsd.override {
    openssl = pkgs.libressl;
    libevent = libevent;
    withSystemd = false;
    withDnstap = false;
    bind8Stats = true;
    zoneStats = true;
  }).overrideAttrs {
    patches = [ ./inttypes.patch ];
  };
in
  erofs.buildImageManifest rec {
    name = "nsd";
    pkg = nsd;
    minimize = true;
    extraBuildCommand =
      ''
      mkdir -p $out/etc/nsd
      ln -s ${pkg}/bin/nsd $out/usr/bin/nsd
      '';
  }
