#!/usr/bin/env python3
# Copyright 2026 Ruud van Asseldonk

"""
Write metadata about an EROFS image into a json manifest.

Usage:
    build_manifest.py <name> <version> /nix/store/... <nixpkgs-commit> <nixpkgs-date> $out
"""

import json
import os
import os.path
import sys

from typing import Dict

name = sys.argv[1]
version = sys.argv[2]
store_path = sys.argv[3]

id_ = store_path.removeprefix("/nix/store/").split("-")[0]
entry: Dict[str, str | int] = {
    "name": name,
    "version": version,
    "id": id_,
    "nix_store_path": store_path,
    # For convenience, also output the path on the server where we store the
    # image and verity file. To keep paths in e.g. systemd units and process
    # explorers readable, truncate the id to 6 characters (30 bits base32),
    # which is plenty to avoid collisions because we already scope the name.
    "img_store_path": f"/var/lib/images/{name}/{id_[:6]}",
}

for fname in os.listdir(store_path):
    full_path = os.path.join(store_path, fname)

    if fname.endswith(".img"):
        entry["image_file"] = fname
        entry["image_size_bytes"] = os.stat(full_path).st_size

    if fname.endswith(".verity"):
        entry["verity_file"] = fname

    if fname.endswith(".roothash"):
        with open(full_path, "r", encoding="ascii") as f:
            entry["verity_roothash"] = f.read().strip()

entry["nixpkgs_commit"] = sys.argv[4]
entry["nixpkgs_date"] = sys.argv[5]

json.dump(entry, sys.stdout, indent=2)
sys.stdout.write("\n")
