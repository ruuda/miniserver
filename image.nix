{pkgs ? import <nixpkgs> {}}:
with pkgs;

let
  customNginx = nginx.overrideDerivation (oldAttrs: {
    # Override the nginx package to cut down on the dependencies. It does expose
    # *some* parameters that make a smaller Nginx, but that is not enough for my
    # taste. I also want to disable geoip and all the xml stuff, I don't use it.
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
