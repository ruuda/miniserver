# Miniserver -- Nginx and Acme-client on CoreOS.
# Copyright 2018 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

{ pkgs ?
  let
    # Default to a pinned version of Nixpkgs. The actual revision of the
    # Nixpkgs repository is stored in a separate file (as a string literal).
    # We then fetch that revision from Github and import it. The revision
    # should periodically be updated to be the last commit of NixOS stable.
    nixpkgsRev = import ./nixpkgs-pinned.nix;
    pinnedNixpkgs = fetchTarball {
      url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsRev}.tar.gz";
    };
  in
    import pinnedNixpkgs {}
}:

with pkgs;
let
  userland = import ./default.nix { inherit pkgs; };
  lightKmod = pkgs.kmod.override {
    xz = null;
  };
  customKmod = lightKmod.overrideDerivation (oldAttrs: {
    configureFlags = lib.remove "--with-xz" oldAttrs.configureFlags;
  });
  lightSystemd = pkgs.systemd.override {
    # withSelinux = false;
    # withLibseccomp = false;
    # withKexectools = false;
    libmicrohttpd = null;
    libgpgerror = null;
    xz = null;
    lz4 = null;
    bzip2 = null;
    kmod = customKmod;
  };
  disableLz4 = mflag: if mflag == "-Dlz4=true" then "-Dlz4=false" else mflag;
  customSystemd = lightSystemd.overrideDerivation (oldAttrs: {
    mesonFlags = map disableLz4 oldAttrs.mesonFlags;
  });
in {
  systemd = customSystemd;
  sshd = openssh;
  nginx = userland.nginx;
  acme-client = userland.acme-client;
}
