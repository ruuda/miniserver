# Miniserver

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

The `build.sh` script builds the image as follows:

 * Install [Nix][nix], a purely functional package manager,
   if not installed already.
 * Build a custom version of Nginx, with [`ngx_brotli`][ngx-brotli] module
   enabeld, and build Acme-client. The packages are taken from a pinned
   stable version of [Nixpkgs][nixpkgs].
 * Build a self-contained squashfs image. [FIXME: symlinks.]
 * Copy the resulting image into the `out` directory.

[nix]:        https://nixos.org/nix/
[ngx-brotli]: https://github.com/google/ngx_brotli
[nixpkgs]:    https://github.com/NixOS/nixpkgs

Installing Nix is a pretty invasive operation that creates a `/nix/store`
directory in the root filesystem, and adds build users. If you don't want to do
this to your development machine, you can run `./build.sh` in a virtual machine,
or in a container:

    sudo machinectl pull-tar 'https://cloud-images.ubuntu.com/releases/16.04/release/ubuntu-16.04-server-cloudimg-amd64-root.tar.xz' xenial
    sudo systemd-nspawn           \
      --machine xenial            \
      --capability CAP_NET_ADMIN  \
      --bind-ro /etc/resolv.conf  \
      --bind $PWD:/build          \
      --chdir /build              \
      ./build.sh

I needed to mount my host's `/etc/resolv.conf` inside the container to get
networking to work. If you use `systemd-networkd`, networking might work out
of the box.

## License

The code in this repository is licensed under the
[GNU General Public License][gplv3], version 3.

[gplv3]: https://www.gnu.org/licenses/gpl-3.0.html
