# Miniserver -- EROFS webserver packages for Flatcar Linux.
# Copyright 2026 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

let
  pkgs = (import ./nixpkgs-pinned.nix) {};
  erofs = (import ./../../build-erofs.nix) { inherit pkgs; };

  # Reconfigure Postgres to not be so heavy, we don't use all this stuff anyway.
  # With extensions or JIT, initdb cannot find the postgres binary, but we don't
  # care so much about JIT at this point.
  postgres = (pkgs.postgresql_18.override {
    curlSupport = false;
    gssSupport = false;
    jitSupport = false;
    ldapSupport = false;
    nlsSupport = false;
    numaSupport = false;
    pamSupport = false;
    perlSupport = false;
    pythonSupport = false;
    tclSupport = false;
    selinuxSupport = false;
    # We could slim it down further by omitting systemd support, but alright,
    # this is fairly heavy already, let's just have it.
    systemdSupport = true;
    uringSupport = true;
  });
in
  erofs.buildImageManifest rec {
    name = "postgres";
    pkg = postgres;
    extraBuildCommand =
      ''
      mkdir -p $out/var/lib/postgres/data
      mkdir -p $out/var/log/postgres
      mkdir -p $out/run/postgres
      mkdir -p $out/usr/lib
      touch $out/var/lib/postgres/data/pg_hba.conf
      touch $out/var/lib/postgres/data/postgresql.conf
      ln -s ${pkg}/bin/* $out/usr/bin
      ln -s ${pkg}/lib/* $out/usr/lib
      ln -s ${pkg}/share/postgresql $out/usr/share
      ln -s ${pkgs.bash}/bin/bash $out/usr/bin/sh
      '';

    # Unfortunately, initdb invokes /bin/sh, so we need a shell.
    extraPackages = [ pkgs.bash ];
  }
