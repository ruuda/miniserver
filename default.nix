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
  # NixOS 18.03 ships both LibreSSL 2.5 and 2.6, but sets 2.5 as the default.
  # We go for 2.6 instead. At the time of writing, 2.7 is released already,
  # but 2.6 is still supported.
  acme-client = pkgs.acme-client.override {
    libressl = libressl_2_6;
  };

  # Use the squashfskit fork, it produces reproducible images, unlike the
  # squashfs-tools shipped with NixOS.
  squashfsKit = squashfsTools.overrideDerivation (oldAttrs: {
    src = fetchFromGitHub {
      owner = "squashfskit";
      repo = "squashfskit";
      sha256 = "1qampwl0ywiy9g2abv4jxnq33kddzdsq742ng5apkmn3gn12njqd";
      rev = "3f97efa7d88b2b3deb6d37ac7a5ddfc517e9ce98";
    };
  });

  lightNginx = nginx.override {
    # Remove dependency on libgd; It brings in a lot of transitive dependencies
    # that we don't need (fontconfig, image codecs, etc.). Also disable other
    # unnecessary dependencies.
    gd = null;
    withStream = false;
    withMail = false;

    # Build Nginx against LibreSSL, rather than OpenSSL. This reduces the size
    # of the image, as we don't have to include both OpenSSL and LibreSSL. But
    # more importantly, I trust LibreSSL more than I trust OpenSSL.
    openssl = libressl_2_6;
  };

  ngxBrotli = fetchFromGitHub {
    owner = "google";
    repo = "ngx_brotli";
    sha256 = "04yx1n0wi3l2x37jd1ynl9951qxkn8xp42yv0mfp1qz9svips81n";
    rev = "bfd2885b2da4d763fed18f49216bb935223cd34b";
    fetchSubmodules = true;
  };

  customNginx = lightNginx.overrideDerivation (oldAttrs: {
    # Override the light nginx package to cut down on the dependencies further.
    # I also want to get rid of geoip and all of the xml stuff, but the package
    # offers no options for that. Furthermore, enable the ngx_brotli module.
    configureFlags = [
      "--with-http_ssl_module"
      "--with-http_v2_module"
      "--with-http_gzip_static_module"
      "--with-threads"
      "--with-pcre-jit"
      "--add-module=ngx_brotli"
    ];

    # The nginx binary embeds its configure command line. If we would pass the
    # ngx_brotli module store path directly to --add-module, the store path
    # would therefore end up in the binary. That triggers Nix to detect the
    # ngx_brotli source as a runtime dependency, even though it is not. Work
    # around this issue by creating a symlink to the store path in the build
    # directory. Then the configure flags no longer include the path itself.
    preConfigure = oldAttrs.preConfigure + ''
      ln -s ${ngxBrotli} ngx_brotli
    '';
  });

  # Put together the filesystem by copying from and symlinking to the Nix store.
  # We need to do this, because unfortunately, "mksquashfs /foo/bar" will create
  # a file system with bar in the root. So we cannot pass absolute paths to the
  # store. To work around this, copy all of them, so we can run mksquashfs on
  # the properly prepared directory. Then for symlinks, they are copied
  # verbatim, with the path inside the $out directory. So these we symlink
  # directly to the store, not to the copies in $out. So in the resulting image,
  # those links will point to the right places.
  imageDir = stdenv.mkDerivation {
    name = "miniserver-filesystem";
    buildInputs = [ customNginx acme-client ];
    buildCommand = ''
      # Although we only need /nix/store and /usr/bin, we need to create the
      # other directories too so systemd can mount the API virtual filesystems
      # there, when the image is used.
      mkdir -p $out/dev
      mkdir -p $out/etc
      mkdir -p $out/nix/store
      mkdir -p $out/proc
      mkdir -p $out/run
      mkdir -p $out/sys
      mkdir -p $out/tmp
      mkdir -p $out/usr/bin
      mkdir -p $out/var
      ln -s /usr/bin $out/bin
      ln -s ${customNginx}/bin/nginx $out/usr/bin/nginx
      ln -s ${acme-client}/bin/acme-client $out/usr/bin/acme-client
      closureInfo=${closureInfo { rootPaths = [ customNginx acme-client ]; }}
      for file in $(cat $closureInfo/store-paths); do
        echo "copying $file"
        cp --archive $file $out/nix/store
      done
    '';
  };
  miniserver = stdenv.mkDerivation {
    name = "miniserver.img";

    nativeBuildInputs = [ squashfsKit ];
    buildInputs = [ imageDir ];

    buildCommand =
      ''
        # Generate the squashfs image. Pass the -no-fragments option to make
        # the build reproducible; apparently splitting fragments is a
        # nondeterministic multithreaded process. Also set processors to 1 for
        # the same reason.
        mksquashfs ${imageDir} $out \
          -no-fragments      \
          -processors 1      \
          -all-root          \
          -b 1048576         \
          -comp xz           \
          -Xdict-size 100%   \
      '';
  };
in {
  miniserver = miniserver;
  nginx = customNginx;
  acme-client = acme-client;
}
