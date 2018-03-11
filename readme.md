# Miniserver

Tools to build a minimal webserver, as a self-contained archive that contains
Nginx and Acme-client, with configuration to run it under systemd on CoreOS
Container Linux. A secure and simple way to host a static site.

Features:

 * A recent Nginx, with Brotli support.
 * Acme-client to refresh your Letsencrypt certificates.
 * Systemd units to run both, using systemd's isolation features where it makes
   sense, without the bloat of container runtimes.
 * Declarative configuration without moving parts.
 * Bit by bit reproducible.

## Building

The `build.sh` script builds the archive as follows:

 * Install [Guix][guix], a purely functional package manager.
 * Upgrade to a pinned version of the Guix System Distribution.
 * Build a custom version of Nginx, with [`ngx_brotli`][ngx-brotli] module
   enabeld, and install Acme-client.
 * Export a self-contained archive with `guix pack`.

[guix]:       https://www.gnu.org/software/guix/
[ngx-brotli]: https://github.com/google/ngx_brotli

Installing Guix is a pretty invasive operation that creates a `/gnu/store`
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
