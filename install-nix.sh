#!/bin/bash

# This script installs Nix. It uses a hard-coded key for verification. It does
# not use the default method of piping a website into sh.

# Stop if any command fails.
set -e

# Print commands themselves.
set -x

# Download nix binaries, but only if they haven't been downloaded before.
nixv="nix-2.2.2-x86_64-linux"
mkdir -p downloads
wget --no-clobber --directory-prefix=downloads 'https://nixos.org/nix/install'
wget --no-clobber --directory-prefix=downloads 'https://nixos.org/nix/install.sig'
wget --no-clobber --directory-prefix=downloads "https://nixos.org/releases/nix/nix-2.2.2/$nixv.tar.bz2"

# Stored locally to avoid hitting the network every time; `gpg --import` will
# still try to download the key even if it has it locally. The key fingerprint
# is B541 D553 0127 0E0B CF15 CA5D 8170 B472 6D71 98DE.
gpg --import nix-signing-key.gpg
gpg --verify downloads/install.sig

# For some reason things started failing when running this script in an Ubuntu
# container, because /usr/sbin (which contains groupadd and useradd) was not
# in the path. So add it to the path.
export PATH="$PATH:/usr/sbin"

# Add build users.
sudo groupadd --force --system nixbld
for i in `seq -w 1 10`; do
  sudo useradd -g nixbld -G nixbld              \
          -d /var/empty -s `which nologin` \
          -c "Nix build user $i" --system  \
          nixbuilder$i || true;
done

mkdir -p /tmp/nix-unpack
tar -xjf "downloads/$nixv.tar.bz2" -C /tmp/nix-unpack
/tmp/nix-unpack/$nixv/install
rm -fr /tmp/nix-unpack

source "$HOME/.nix-profile/etc/profile.d/nix.sh"

# Nix does not remain on the path after sourcing that file, once we leave this
# script. Place a symlink in /usr/local/bin to ensure we can access it later.
sudo ln -s $(which nix) "/usr/local/bin/nix"
