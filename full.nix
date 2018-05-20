# Miniserver -- Nginx and Acme-client on CoreOS.
# Copyright 2018 Ruud van Asseldonk

# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.
let
  overlay = self: super: {
    pam = null;
    notlogin = self.stdenv.mkDerivation {
      name = "notlogin";
      src = ./notlogin.c;
      buildCommand = ''
        mkdir -p $out/bin
        # Compile the simple C file, optimize for size (-Os).
        ${self.gcc}/bin/gcc -o $out/bin/notlogin -Wall -Werror -Os $src
        strip $out/bin/notlogin
      '';
    };
    utillinuxMinimal = super.utillinuxMinimal.overrideDerivation (oldAttrs: {
      # Replace the upstream patch phase with our own, because the upstream one
      # depends on the shadow package, that we like to get rid of. This does
      # mean that we have no /bin/login any more, but if we have no Bash, that
      # is not terribly useful anyway. The only way to run something is through
      # ssh.
      # TODO: I could write a small C program as alternative to /bin/login, that
      # just prints a message and never returns.
      postPatch = ''
        substituteInPlace include/pathnames.h \
          --replace "/bin/login" "${self.notlogin}/bin/notlogin"
        substituteInPlace sys-utils/eject.c \
          --replace "/bin/umount" "$out/bin/umount"
      '';
      postInstall = ''
        rm -fr $out/share/{locale,doc,bash-completion}
      '';
    });
    systemd = super.systemd.override {
      # Use light versions of dependencies.
      kbd = super.kbdlight;

      # We could opt for Busybox rather than coreutils, because it is smaller.
      # But even with enableMinimal, it provides *many* more binaries, which
      # increase attack surface. So opt for the traditional coreutils then.
      # coreutils = super.busybox.override {
      #   enableMinimal = true;
      # };
      coreutils = self.coreutilsMinimal;

      # Disable unneeded dependencies.
      acl = null;
      audit = null;
      bzip2 = null;
      kmod = null;
      libapparmor = null;
      libgpgerror = null;
      libidn2 = null;
      libmicrohttpd = null;
      lz4 = null;
      pam = null;
      xz = null;
    };
    openssh =
      let
        pkg = super.openssh.override {
          withKerberos = false;
          libedit = null;
          openssl = super.libressl_2_6;
        };
      in
        pkg.overrideDerivation (oldAttrs: rec {
          configureFlags = (
            super.lib.remove "--with-libedit=yes" oldAttrs.configureFlags
          ) ++ [ "--with-libedit=no" ];
          # Remove the upstream postinstall step that copies in ssh-copy-id.
          # This is a shell script that depends on Bash, and we want to remove
          # all dependencies on Bash. It is not useful on the server anyway,
          # so get rid of it.
          postInstall = "";
        });
    rsync = super.rsync.override {
      enableACLs = false;
      acl = null;
    };
    coreutilsMinimal = super.coreutils.override {
      aclSupport = false;
      attrSupport = false;
      acl = null;
      attr = null;
      gmp = null;
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
      "-Dlibidn2=true"
      "-Dlz4=true"
    ];
    mesonFlags = (lib.foldr lib.remove oldAttrs.mesonFlags removeFlags) ++ [
      "-Dacl=false"
      "-Dapparmor=false"
      "-Daudit=false"
      "-Dbzip2=false"
      "-Didn=false"
      "-Dkmod=false"
      "-Dlibidn2=false"
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
        substituteInPlace $i --replace /bin/false ${coreutilsMinimal}/bin/false
      done
      find $out -name "*kernel-install*" -exec rm {} \;

      # The following directories are used by kernel-install apparently, these
      # scripts get executed when a Kernel is replaced. But NixOS does not use
      # that system anyway, and it deletes kernel-install. So delete these
      # scripts as well.
      rm -fr $out/lib/kernel

      # This is a server, no need for X11 stuff. Remove it, because a script in
      # there references Bash, and we would like to get rid of bash.
      rm -fr $out/share/factory/etc/X11

      # While we're at it, delete useless completions for things that we don't
      # use anyway. And the PAM dir, because we removed PAM.
      rm -fr $out/share/bash-completion
      rm -fr $out/share/zsh
      rm -fr $out/share/factory/etc/pam.d

      # Keep only libudev and libsystemd in the lib output.
      mkdir -p $out/lib
      mv $lib/lib/libnss* $out/lib/
    '';
  });
in {
  systemd = systemd;
  openssh = openssh;
  rsync = rsync;
  nginx = userland.nginx;
  acme-client = userland.acme-client;
  notlogin = notlogin;
}
