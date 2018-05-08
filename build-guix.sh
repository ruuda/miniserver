#!/bin/bash

# Miniserver -- Nginx and Acme-client on CoreOS.
# Copyright 2018 Ruud van Asseldonk
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3. A copy
# of the License is available in the root of the repository.

# Stop if any command fails.
set -e

# The version of GuixSD to base the packages on. Should be updated periodically
# to get the latest version of all packages. The lock file stores the commit
# hash.
GUIXSD_VERSION=$(<guixsd-version.lock)

# Allow skipping past the expensive parts, directly to building the archive, by
# passing the `--no-install` flag. Useful for debugging.
if [[ "$1" != "--no-install" ]]; then

# This script mostly follows
# https://www.gnu.org/software/guix/manual/html_node/Binary-Installation.html.

printf ':: Downloading and verifying Guix binary ...\n\n'

mkdir -p downloads

wget --no-clobber --directory-prefix=downloads 'https://alpha.gnu.org/gnu/guix/guix-binary-0.14.0.x86_64-linux.tar.xz'
wget --no-clobber --directory-prefix=downloads 'https://alpha.gnu.org/gnu/guix/guix-binary-0.14.0.x86_64-linux.tar.xz.sig'

# Stored locally to avoid hitting the network every time; `gpg --import` will
# still try to download the key even if it has it locally. The key fingerprint
# is 3CE464558A84FDC69DB40CFB090B11993D9AEBB5.
gpg --import guix-signing-key.gpg
gpg --verify downloads/guix-binary-0.14.0.x86_64-linux.tar.xz.sig

printf '\n:: Setting up Guix ...\n\n'

tar -xJf downloads/guix-binary-0.14.0.x86_64-linux.tar.xz -C /tmp
mv --no-clobber /tmp/var/guix /var/
mv --no-clobber /tmp/gnu /
rm -fr /tmp/var/guix
rm -fr /tmp/gnu

ln -sf /var/guix/profiles/per-user/root/guix-profile ~root/.guix-profile

export GUIX_PROFILE=~root/.guix-profile
source $GUIX_PROFILE/etc/profile

# Add the current directory to the package path, so nginx-brotli.scm gets picked
# up, and we can install packages from there.
export GUIX_PACKAGE_PATH="$PWD"

# For some reason things started failing when running this script in an Ubuntu
# container, because /usr/sbin (which contains groupadd and useradd) was not in
# the path. So add it to the path.
export PATH="$PATH:/usr/sbin"

groupadd --force --system guixbuild
for i in `seq -w 1 10`; do
  useradd -g guixbuild -G guixbuild           \
          -d /var/empty -s `which nologin`    \
          -c "Guix build user $i" --system    \
          guixbuilder$i || true;
done

printf '\n:: Starting Guix build daemon ...\n\n'

guix-daemon --build-users-group=guixbuild &
guix archive --authorize < ~root/.guix-profile/share/guix/hydra.gnu.org.pub

printf ":: Pulling GuixSD version ${GUIXSD_VERSION} ... \n\n"

guix pull --commit=$GUIXSD_VERSION

printf '\n:: Building Nginx and Acme-client ...\n\n'

guix package --install acme-client nginx-brotli

# End of `--no-install` flag. But we do still want to start the build daemon.
else
export GUIX_PROFILE=~root/.guix-profile
source $GUIX_PROFILE/etc/profile
export GUIX_PACKAGE_PATH="$PWD"
guix-daemon --build-users-group=guixbuild &
fi

printf '\n:: Packing archive ...\n\n'

# Export the archive. Add a symlink to the binaries to the archive so we can
# access both binaries from /bin, without needing to know the hash.
archive_path=$(
  guix pack                                    \
    --format=tarball                           \
    --symlink=/bin/nginx=sbin/nginx            \
    --symlink=/bin/acme-client=bin/acme-client \
    --compression=gzip                         \
    acme-client nginx-brotli
)

printf "Archive is $archive_path.\n"

mkdir -p out
cp $archive_path out/

# GC a bit so we don't fill up the disk of the Guix machine, when the Guix
# machine is reused for builds.
guix gc --free-space=512MiB

printf "\n:: Archive written to out/$(basename $archive_path) ...\n"
