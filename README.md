# Miniserver

Tools to build self-contained EROFS images for packages from Nixpkgs, in
particular Nginx, Lego, and NSD to run a webserver. These images are suitable
for running under systemd on [Flatcar Container Linux][flatcar] (formerly
[CoreOS][coreos]). A secure and simple way to host a static site.

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

    $ nix build --out-link result images/nginx
    $ systemd-nspawn --ephemeral --image $(rcl rq result '
      f"{input.nix_store_path}/{input.image_file}"
    ') -- /usr/bin/nginx -V

    $ nix build --out-link result images/lego
    $ systemd-nspawn --ephemeral --image $(rcl rq result '
      f"{input.nix_store_path}/{input.image_file}"
    ') -- /usr/bin/lego --version

    $ nix build --out-link result images/nsd
    $ systemd-nspawn --ephemeral --image $(rcl rq result '
      f"{input.nix_store_path}/{input.image_file}"
    ') -- /usr/bin/nsd -v

An example manifest, the output of the build which describes the image built,
and its metadata:

```json
{
  "name": "nginx",
  "id": "hsr674bfgqcmzdiw46jjpa99jxfkgn14",
  "nix_store_path": "/nix/store/hsr674bfgqcmzdiw46jjpa99jxfkgn14-nginx-1.31.0-image",
  "img_store_path": "/var/lib/images/nginx/hsr674",
  "image_file": "nginx-1.31.0.img",
  "image_size_bytes": 9658368,
  "verity_file": "nginx-1.31.0.img.verity",
  "verity_roothash": "1f0657688222cc231bbc6749da005dec7b9a6833e8cf82472b42153c24e45304",
  "nixpkgs_commit": "69d860e0e0e115deecf32e235e279cca0bb67545",
  "nixpkgs_date": "2026-05-15T09:23:15Z"
}
```

The build of the webserver components involves the following:

 * Take the package definitions for `nginx`, `lego`, and `nsd`, and any other
   packages from a pinned version of [Nixpkgs][nixpkgs].
 * Override `nginx` package to disable unused features (to reduce the number
   of dependencies, and thereby attack surface and image size). Add the
   [`ngx_brotli`][ngx-brotli] module for `brotli_static` support.
 * Build a self-contained Erofs image for every package.

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

    ./miniserver.py deploy --image=<image>... <hostname>...

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
