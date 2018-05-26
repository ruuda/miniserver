#!/bin/bash

# Update the pinned Nixpkgs version to the latest commit in the specified
# channel. Uses the Github API to resolve the channel ref to a commit hash.
# The pin file contains the hash between quotes, but fortunately jq prints
# it like that.

channel='nixos-18.03'
curl --silent "https://api.github.com/repos/NixOS/nixpkgs-channels/git/refs/heads/$channel" | jq .object.sha > nixpkgs-pinned.nix

git add nixpkgs-pinned.nix
git commit -m "Upgrade to latest commit in $channel channel"
