# Miniserver

Tools to build a minimal webserver, as a self-contained archive that contains
Nginx and Lego, with configuration to run it under systemd on
[Flatcar Container Linux][flatcar] (formerly [CoreOS][coreos]).
A secure and simple way to host a static site.

Features:

 * A recent Nginx, with Brotli support.
 * [Lego][lego] to refresh your Letsencrypt certificates.
 * Bit by bit reproducible.
 * Packaged as a squashfs file system, runs using systemd's isolation features.

[lego]: https://go-acme.github.io/lego/

## Building

Building of the image is automated using [Nix][nix], a purely functional
package manager:

    nix build --out-link result
    systemd-nspawn --image result/miniserver.img --ephemeral -- /usr/bin/nginx -V

The build involves the following:

 * Take the package definitions for `nginx` and `lego` from a pinned version
   of [Nixpkgs][nixpkgs].
 * Override `nginx` package to disable unused features (to reduce the number
   of dependencies, and thereby attack surface and image size). Add the
   [`ngx_brotli`][ngx-brotli] module for `brotli_static` support.
 * Build a self-contained squashfs image.

[nix]:        https://nixos.org/nix/
[nixpkgs]:    https://github.com/NixOS/nixpkgs
[ngx-brotli]: https://github.com/google/ngx_brotli

## Deploying

This repository includes a simple deployment tool, `miniserver.py` for updating
an existing installation. It will:

 * Create a `/var/lib/miniserver` on a target machine to hold deployed images.
 * Copy the current image to the server over `sshfs` into a directory named
   after the current version's Nix hash.
 * Put systemd units `nginx.service` and `lego.service` next to the image.
 * Symlink `/var/lib/miniserver/current` to the latest version.
 * Daemon-reload `systemd` and restart `nginx.service`.

Before the first deployment, perform the following initial setup.
It is recommended to encode these steps in your Ignition config.

 * Create a `www` system group.
 * Create `nginx` and `lego` system users with their own group,
   and also part of the `www` group.
 * Create `/var/log/nginx` and `chown` it to `nginx:nginx`.
   This directory will be mounted read-write inside the unit's chroot.
 * Create `/var/www`, chown it to `$USER:www`, and put your static site in
   there. This directory will be mounted read-only inside the unit's chroot.
 * Create `/etc/nginx/sites-enabled/` and put at least one Nginx configuration
   file in there. `/etc/nginx` will be mounted read-only inside the unit's
   chroot. Files in `sites-enabled` will be loaded by the master config.
 * Create `/var/lib/lego/certificates` and chown it and its parent to `lego:www`.
   Set the file mode on `/var/lib/lego/certificates` to 0750, to enable the
   `www` group to enter the directory.
 * Put your Lego flags environment file at `/etc/lego.conf`.

Then to install or update:

    ./miniserver.py install <hostname>

You need to have built the image before it can be deployed. The `install`
command will symlink `/etc/systemd/system/{nginx,lego}.service` to the
ones in the installation directory, and enable and start the `nginx` unit. The
installation command is idempotent, it is safe to run it multiple times. (Each
time will create an entry in the deploy log, however.)

After the initial installation, you can update with:

    ./miniserver.py deploy <hostname>

This will restart `nginx.service` after uploading a new version.

## License

The code in this repository is licensed under the
[GNU General Public License][gplv3], version 3.

[flatcar]: https://www.flatcar.org/
[coreos]:  https://www.redhat.com/en/technologies/cloud-computing/openshift/what-was-coreos
[gplv3]:   https://www.gnu.org/licenses/gpl-3.0.html
