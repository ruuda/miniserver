# Miniserver

Tools to build ingredients for a minimal webserver: EROFS images that contain
Nginx, Lego, and NSD. These images are suitable for running under systemd on
[Flatcar Container Linux][flatcar] (formerly [CoreOS][coreos]). A secure and
simple way to host a static site.

Features:

 * A recent Nginx, with Brotli support.
 * [Lego][lego] to refresh your Letsencrypt certificates.
 * Bit by bit reproducible.
 * Packaged as Erofs file system, runs using systemd's isolation features.

[lego]: https://go-acme.github.io/lego/

## Building

Building of the images is automated using [Nix][nix], a purely functional
package manager. Nix outputs a single json file, the _manifest_, which contains
information about the images built.

    $ nix build --out-link result

    $ systemd-nspawn --ephemeral --image $(rcl rq result '
      let pkg = input.nginx;
      f"{pkg.nix_store_path}/{pkg.image_file}"
    ') -- /usr/bin/nginx -V

    $ systemd-nspawn --ephemeral --image $(rcl rq result '
      let pkg = input.lego;
      f"{pkg.nix_store_path}/{pkg.image_file}"
    ') -- /usr/bin/lego --version

    $ systemd-nspawn --ephemeral --image $(rcl rq result '
      let pkg = input.nsd;
      f"{pkg.nix_store_path}/{pkg.image_file}"
    ') -- /usr/bin/nsd -v

An example manifest, the output of the build which describes the images built,
and their metadata:

```json
{
  "nginx": {
    "id": "49dz2afiyczwygx8c29bviisch88gyja",
    "nix_store_path": "/nix/store/49dz2afiyczwygx8c29bviisch88gyja-nginx-1.29.7-verity",
    "img_store_path": "/var/lib/images/nginx/49dz2a",
    "image_file": "nginx-1.29.7.img",
    "verity_file": "nginx-1.29.7.img.verity",
    "verity_roothash": "543bf10a927fadf8966d6da5f8dced25fc90cd743ce7e7ce5ce0b7e6cea272f0"
  },
  "lego": {
    "id": "jn8afm7bsvsq5q10xdrs03g1dh549g1m",
    "nix_store_path": "/nix/store/jn8afm7bsvsq5q10xdrs03g1dh549g1m-lego-4.31.0-verity",
    "img_store_path": "/var/lib/images/lego/jn8afm",
    "image_file": "lego-4.31.0.img",
    "verity_file": "lego-4.31.0.img.verity",
    "verity_roothash": "b2206c36768b472bcd0843ab47af609c0222fa4a5ac23358614864473f8d41e1"
  },
  "nsd": {
    "id": "xp4v36hk2rq1a6cxy5q34h58prdf9rp3",
    "nix_store_path": "/nix/store/xp4v36hk2rq1a6cxy5q34h58prdf9rp3-nsd-4.12.0-verity",
    "img_store_path": "/var/lib/images/nsd/xp4v36",
    "image_file": "nsd-4.12.0.img",
    "verity_file": "nsd-4.12.0.img.verity",
    "verity_roothash": "5bd0d78e9187147c9bb26256e5cd116659dc8cb89e288dc568c2b75898618edc"
  }
}
```

The build involves the following:

 * Take the package definitions for `nginx`, `lego`, and `nsd` from a pinned
   version of [Nixpkgs][nixpkgs].
 * Override `nginx` package to disable unused features (to reduce the number
   of dependencies, and thereby attack surface and image size). Add the
   [`ngx_brotli`][ngx-brotli] module for `brotli_static` support.
 * Build a self-contained Erofs image.

[nix]:        https://nixos.org/nix/
[nixpkgs]:    https://github.com/NixOS/nixpkgs
[ngx-brotli]: https://github.com/google/ngx_brotli

## Deploying

This repository includes a simple deployment tool, `miniserver.py` for pushing
images to servers. It will:

 * Create `/var/lib/images` on a target machine to hold deployed images.
 * Copy the current images to the server over `sshfs` into a directories named
   after the current version's Nix hash.
 * The target paths on the hosts are part of the manifest, at `img_store_path`.

To install or update:

    ./miniserver.py deploy <hostname>...

You need to have built the images before it can be deployed, but because
`miniserver.py` reads the json manifest, this is automatically enforced.

## Running

In the past this repository also contained templates for systemd units, and
more logic to start and restart units. As of the April 2026 revision, this
responsibility is out of scope. Miniserver builds and pushes images, but a
separate tool should manage the unit lifecycle. [Deptool][deptool] is
particularly well-suited for this. Example systemd units are still available
in the `example_units` directory.

## License

The code in this repository is licensed under the
[GNU General Public License][gplv3], version 3.

[flatcar]: https://www.flatcar.org/
[coreos]:  https://www.redhat.com/en/technologies/cloud-computing/openshift/what-was-coreos
[gplv3]:   https://www.gnu.org/licenses/gpl-3.0.html
[deptool]: https://codeberg.org/ruuda/deptool
