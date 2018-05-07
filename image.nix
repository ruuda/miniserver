{pkgs ? import <nixpkgs> {}}:
with pkgs;

let
  customNginx = nginx.override {
    # Remove dependency on libgd; It brings in a lot of transitive dependencies
    # that we don't need (fontconfig, image codecs, etc.).
    gd = null;

    # Also disable other things we don't need.
    withStream = false;
    withMail = false;
  };
in
  stdenv.mkDerivation {
    name = "miniserver.img";

    nativeBuildInputs = [ squashfsTools ];

    buildCommand =
      ''
        closureInfo=${closureInfo { rootPaths = [ customNginx acme-client ]; }}
        # TODO: Put symlinks binaries in /usr/bin.
        # TODO: Diagnose the bloat. Why do I have dejavu-fonts-minimal,
        # libpng, libwebp, freetype, giflib, libtiff, gcc, xz fontconfig?
        # Generate the squashfs image.
        echo "STORE PATHS"
        cat $closureInfo/store-paths
        echo "SQUASH"
        mksquashfs $(cat $closureInfo/store-paths) $out \
          -keep-as-directory -all-root -b 1048576 -comp xz -Xdict-size 100%
      '';
  }
