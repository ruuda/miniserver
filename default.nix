{pkgs ? import <nixpkgs> {}}:
with pkgs;

let
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
      "--add-module=${ngxBrotli}"
    ];
  });

in
  stdenv.mkDerivation {
    name = "miniserver.img";

    nativeBuildInputs = [ squashfsKit ];
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
        # Generate the squashfs image. Pass the -no-fragments option to make
        # the build reproducible; apparently splitting fragments is a
        # nondeterministic multithreaded process. Also set processors to 1 for
        # the same reason.
        mksquashfs $(cat $closureInfo/store-paths) $out \
          -no-fragments      \
          -processors 1      \
          -keep-as-directory \
          -all-root          \
          -b 1048576         \
          -comp xz           \
          -Xdict-size 100%   \
      '';
  }
