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
      src = ./notlogin;
    };
    utillinuxMinimal = super.utillinuxMinimal.overrideDerivation (oldAttrs: {
      # Replace the upstream patch phase with our own, because the upstream one
      # depends on the shadow package, that we like to get rid of. This does
      # mean that we have no /bin/login any more, but if we have no Bash, that
      # is not terribly useful anyway. The only way to run something is through
      # ssh. Replace /bin/login with our own /bin/notlogin.
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
      "-Dlocaled=true"
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

      # Disable the tools that we don't use anyway. Machinectl controls VMs and
      # containers, but we just write our own unit files. Rfkill has  something
      # to do with wireless networks not useful on a server. Localed allows
      # changing the locale -- we hardcode en_US.UTF8.
      "-Dmachined=false"
      "-Drfkill=false"
      "-Dlocaled=false"
      "-Dpolkit=false"
      "-Dbashcompletiondir=no"
      "-Dzshcompletiondir=no"
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
  imageDir = stdenv.mkDerivation rec {
    name = "miniserver-${version}-rootfs";
    version = "0.0.0";
    buildInputs = [
      notlogin
      openssh
      rsync
      systemd
      userland.acme-client
      userland.nginx
    ];
    osRelease = ''
      NAME="Miniserver"
      VERSION="${version}"
      ID=miniserver
      ID_LIKE=nixos
      PRETTY_NAME="Miniserver ${version}"
      HOME_URL="https://github.com/ruuda/miniserver"
    '';
    buildCommand = ''
      # Although we only need /nix/store and /usr/bin, we need to create the
      # other directories too so the API virtual filesystems can be mounted
      # there.
      mkdir -p $out/dev
      mkdir -p $out/etc
      mkdir -p $out/nix/store
      mkdir -p $out/proc
      mkdir -p $out/run
      mkdir -p $out/sys
      mkdir -p $out/tmp
      mkdir -p $out/usr/bin
      mkdir -p $out/usr/lib
      mkdir -p $out/var
      ln -s /usr/bin $out/bin
      ln -s ${notlogin}/bin/notlogin $out/usr/bin/notlogin
      ln -s ${openssh}/bin/sshd $out/usr/bin/sshd
      ln -s ${rsync}/bin/rsync $out/usr/bin/rsync
      ln -s ${systemd}/bin/journalctl $out/usr/bin/journalctl
      ln -s ${systemd}/bin/systemctl $out/usr/bin/systemctl
      ln -s ${systemd}/lib/systemd/systemd $out/usr/bin/init
      ln -s ${userland.acme-client}/bin/acme-client $out/usr/bin/acme-client
      ln -s ${userland.nginx}/bin/nginx $out/usr/bin/nginx

      # For systemd-nspawn to boot the rootfs (with --boot), it needs an
      # os-release file.
      echo '${osRelease}' > $out/usr/lib/os-release

      closureInfo=${closureInfo { rootPaths = buildInputs; }}
      for file in $(cat $closureInfo/store-paths); do
        echo "copying $file"
        cp --archive $file $out/nix/store
      done
    '';
  };
in {
  systemd = systemd;
  openssh = openssh;
  rsync = rsync;
  nginx = userland.nginx;
  acme-client = userland.acme-client;
  notlogin = notlogin;
  imageDir = imageDir;
}
