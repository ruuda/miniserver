{ pkgs ? import <nixpkgs> {}}:
with pkgs;

stdenv.mkDerivation {
  name = "miniserver.img";

  nativeBuildInputs = [ squashfsTools ];

  buildCommand =
    ''
      closureInfo=${closureInfo { rootPaths = [ nginx acme-client ]; }}
      # TODO: Put symlinks binaries in /usr/bin.
      # TODO: Diagnose the bloat. Why do I have dejavu-fonts-minimal,
      # libpng, libwebp, freetype, giflib, libtiff, gcc, xz fontconfig?
      # Generate the squashfs image.
      mksquashfs $(cat $closureInfo/store-paths) $out \
        -keep-as-directory -all-root -b 1048576 -comp xz -Xdict-size 100%
    '';
}
