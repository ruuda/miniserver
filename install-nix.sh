#!/bin/bash

# This script installs Nix. It uses a hard-coded key for verification. It does
# not use the default method of piping a website into sh.

# Stop if any command fails.
set -e

# Print commands themselves.
set -x

# Download nix binaries, but only if they haven't been downloaded before.
nixv="nix-2.3.4"
system="x86_64-linux"
mkdir -p downloads
wget --no-clobber --directory-prefix=downloads "https://nixos.org/releases/nix/${nixv}/${nixv}-${system}.tar.xz"
wget --no-clobber --directory-prefix=downloads "https://nixos.org/releases/nix/${nixv}/${nixv}-${system}.tar.xz.asc"

# Stored locally to avoid hitting the network every time; `gpg --import` will
# still try to download the key even if it has it locally. The key fingerprint
# is B541 D553 0127 0E0B CF15 CA5D 8170 B472 6D71 98DE.
gpg --import nix-signing-key.gpg
gpg --verify "downloads/${nixv}-${system}.tar.xz.asc"

mkdir -p /tmp/nix-unpack
tar -xf "downloads/${nixv}-${system}.tar.xz" -C /tmp/nix-unpack

"/tmp/nix-unpack/${nixv}-${system}/install"
rm -fr /tmp/nix-unpack

source "$HOME/.nix-profile/etc/profile.d/nix.sh"

# Nix does not remain on the path after sourcing that file, once we leave this
# script. Place a symlink in /usr/local/bin to ensure we can access it later.
sudo ln -s $(which nix) "/usr/local/bin/nix"
