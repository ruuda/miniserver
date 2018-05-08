#!/bin/bash

# Stop if any command fails.
set -e

printf ':: Downloading and verifying Nix binary ...\n\n'

mkdir -p downloads

nixv="nix-2.0.2-x86_64-linux"

wget --no-clobber --directory-prefix=downloads 'https://nixos.org/nix/install'
wget --no-clobber --directory-prefix=downloads 'https://nixos.org/nix/install.sig'
wget --no-clobber --directory-prefix=downloads "https://nixos.org/releases/nix/nix-2.0.2/$nixv.tar.bz2"

# Stored locally to avoid hitting the network every time; `gpg --import` will
# still try to download the key even if it has it locally. The key fingerprint
# is B541 D553 0127 0E0B CF15 CA5D 8170 B472 6D71 98DE.
gpg --import nix-signing-key.gpg
gpg --verify downloads/install.sig

printf ':: Adding build users\n\n'

# For some reason things started failing when running this script in an Ubuntu
# container, because /usr/sbin (which contains groupadd and useradd) was not in
# the path. So add it to the path.
export PATH="$PATH:/usr/sbin"

groupadd --force --system nixbld
for i in `seq -w 1 10`; do
  useradd -g nixbld -G nixbld              \
          -d /var/empty -s `which nologin` \
          -c "Nix build user $i" --system  \
          nixbuilder$i || true;
done

printf ':: Extracting and installing Nix ...\n\n'

mkdir -p /tmp/nix-unpack
tar -xjf "downloads/$nixv.tar.bz2" -C /tmp/nix-unpack
/tmp/nix-unpack/$nixv/install
rm -fr /tmp/nix-unpack

source "$HOME/.nix-profile/etc/profile.d/nix.sh"

printf ':: Building Nginx and acme-client ...\n\n'

nix build -f channel:nixos-18.03 nginx acme-client brotli

printf ':: Building image ...\n\n'

nix build
image_path=$(nix path-info -f default.nix)

mkdir -p out
cp $image_path out/

printf "\n:: Image written to out/$(basename $image_path) ...\n"
