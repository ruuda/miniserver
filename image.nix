{pkgs ? import <nixpkgs> {}}:
with pkgs;

let
  lightNginx = nginx.override {
    # Remove dependency on libgd; It brings in a lot of transitive dependencies
    # that we don't need (fontconfig, image codecs, etc.). Also disable other
    # unnecessary dependencies.
    gd = null;
    withStream = false;
    withMail = false;
  };
  customNginx = lightNginx.overrideDerivation (oldAttrs: {
    # Override the light nginx package to cut down on the dependencies further.
    # I also want to get rid of geoip and all of the xml stuff, but the package
    # offers no options for that.
    configureFlags = [
      "--with-http_ssl_module"
      "--with-http_v2_module"
      "--with-http_gzip_static_module"
      "--with-threads"
      "--with-pcre-jit"
    ];
  });
in
  stdenv.mkDerivation {
    name = "miniserver.img";

    nativeBuildInputs = [ squashfsTools ];
    buildInputs = [ customNginx acme-client ];

    buildCommand =
      ''
        closureInfo=${closureInfo { rootPaths = [ customNginx acme-client ]; }}

        # Uncomment to print dependencies in the build log.
        # This is the easiest way I've found to do this.
        # echo "BEGIN DEPS"
        # cat $closureInfo/store-paths
        # echo "END DEPS"

        # TODO: Put symlinks binaries in /usr/bin.
        # Generate the squashfs image.
        mksquashfs $(cat $closureInfo/store-paths) $out \
          -keep-as-directory -all-root -b 1048576 -comp xz -Xdict-size 100%
      '';
  }
