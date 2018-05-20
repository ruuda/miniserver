# Miniserver -- Nginx and Acme-client on CoreOS.
# Copyright 2018 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.
let
  overlay = self: super: {
    pam = null;
    utillinuxMinimal = super.utillinuxMinimal.overrideDerivation (oldAttrs: {
      postInstall = ''
        rm -fr $out/share/{locale,doc,bash-completion}
      '';
    });
    systemd = super.systemd.override {
      # Use light versions of dependencies.
      kbd = super.kbdlight;

      # Disable unneeded dependencies.
      bzip2 = null;
      kmod = null;
      libgpgerror = null;
      libmicrohttpd = null;
      lz4 = null;
      pam = null;
      xz = null;
    };
  };
in
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
      import pinnedNixpkgs {
        overlays = [ overlay ];
      }
  }:

with pkgs;
let
  userland = import ./default.nix { inherit pkgs; };
  systemd = pkgs.systemd.overrideDerivation (oldAttrs: rec {
      removeFlags = [
        # "-Dkmod-path=${null}/bin/kmod"
        "-Dlz4=true"
      ];
      mesonFlags = (lib.foldr lib.remove oldAttrs.mesonFlags removeFlags) ++ [
        "-Dbzip2=false"
        "-Dkmod=false"
        "-Dkmod=false"
        "-Dlz4=false"
        "-Dmicrohttpd=false"
        "-Dpam=false"
        "-Dxz=false"
      ];
      # Adapted from the postinstall in the systemd package.
      postInstall = ''
        rm -fr $out/lib/{modules-load.d,binfmt.d,sysctl.d,tmpfiles.d}
        rm -fr $out/lib/systemd/{system,user}
        rm -fr $out/etc/systemd/system
        rm -fr $out/etc/rpm
        for i in $out/share/dbus-1/system-services/*.service; do
          substituteInPlace $i --replace /bin/false ${coreutils}/bin/false
        done
        find $out -name "*kernel-install*" -exec rm {} \;

        # Keep only libudev and libsystemd in the lib output.
        mkdir -p $out/lib
        mv $lib/lib/libnss* $out/lib/
      '';
    });
in {
  systemd = systemd;
  utilLinux = pkgs.utillinuxMinimal;
  # sshd = openssh;
  # nginx = userland.nginx;
  # acme-client = userland.acme-client;
}
