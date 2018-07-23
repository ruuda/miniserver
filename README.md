# Miniserver

[![Build Status][ci-img]][ci]

Tools to build a minimal webserver, as a self-contained archive that contains
Nginx and Acme-client, with configuration to run it under systemd on CoreOS
Container Linux. A secure and simple way to host a static site.

Features:

 * A recent Nginx, with Brotli support.
 * Acme-client to refresh your Letsencrypt certificates.
 * Bit by bit reproducible.

Planned features:

 * Systemd units to run both, using systemd's isolation features where it
   makes sense, without the bloat of container runtimes.
 * Declarative configuration without moving parts.

## Building

Building of the image is automated using [Nix][nix], a purely functional
package manager:

    nix build --out-link miniserver.img
    systemd-nspawn --image miniserver.img --ephemeral -- /usr/bin/nginx -V

The build involves the following:

 * Take the package definitions for `nginx` and `acme-client` from a pinned
   version of [Nixpkgs][nixpkgs].
 * Override `nginx` package to disable unused features (to reduce the number
   of dependencies, and thereby attack surface and image size). Add the
   [`ngx_brotli`][ngx-brotli] module for `brotli_static` support.
 * Build a self-contained squashfs image.

[nix]:        https://nixos.org/nix/
[nixpkgs]:    https://github.com/NixOS/nixpkgs
[ngx-brotli]: https://github.com/google/ngx_brotli

Installing Nix is a pretty invasive operation that creates a `/nix/store`
directory in the root filesystem, and adds build users. If you don't want to do
this to your development machine, you can run `./install-nix.sh` in a virtual
machine, or in a container:

    sudo machinectl pull-tar 'https://cloud-images.ubuntu.com/releases/16.04/release/ubuntu-16.04-server-cloudimg-amd64-root.tar.xz' xenial
    sudo systemd-nspawn           \
      --machine xenial            \
      --capability CAP_NET_ADMIN  \
      --bind-ro /etc/resolv.conf  \
      --bind $PWD:/build          \
      --chdir /build              \
      /bin/bash -c "
        source ./install-nix.sh
        nix build
        cp $(nix path-info) miniserver.img
      "
    sudo systemd-nspawn --image miniserver.img --ephemeral -- /usr/bin/nginx -V

I needed to mount my host's `/etc/resolv.conf` inside the container to get
networking to work. If you use `systemd-networkd`, networking might work out
of the box.

## Deploying

Steps for manual deployment to a CoreOS server. It is recommended to instead
encode these steps in your Ignition config.

 * Copy `miniserver.img` to `/var/lib/images/miniserver/latest`. This path will
   allow for automatic updates using [Tako][tako] later.
 * Copy `nginx.service` to `/etc/systemd/system/nginx.service`.
 * Create `/var/log/nginx` and `chown` it to `nobody:nobody`. This directory
   will be mounted read-write inside the unit's chroot.
 * Create `/var/www` and put your static site in there. This directory will be
   mounted read-only inside the unit's chroot.
 * Create `/etc/nginx/sites-enabled/` and put at least one Nginx configuration
   file in there. Files in that directory will be loaded by the master config.
 * `systemctl start nginx`.

## License

The code in this repository is licensed under the
[GNU General Public License][gplv3], version 3.

[ci-img]: https://travis-ci.org/ruuda/miniserver.svg?branch=master
[ci]:     https://travis-ci.org/ruuda/miniserver
[tako]:   https://github.com/ruuda/tako
[gplv3]:  https://www.gnu.org/licenses/gpl-3.0.html
