#!/usr/bin/env nix-shell
#! nix-shell -i bash -p diffoscope
if ! nix-build --option build-repeat 5 -K; then
  path=$(nix-store -q $(nix-instantiate))
  diffoscope "${path}" "${path}.check"
fi

