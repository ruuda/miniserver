#!/usr/bin/env python3
# Copyright 2026 Ruud van Asseldonk

"""
Combine metadata about multiple images into a single json manifest.

Usage:
    build_manifest.py img1=/nix/store/... img2=/nix/store/... > $out
"""

import json
import os
import sys

from typing import Dict

result: Dict[str, Dict[str, str]] = {}

for arg in sys.argv[1:]:
    name, store_path = arg.split("=", maxsplit=1)

    id_ = store_path.removeprefix("/nix/store/").split("-")[0]
    entry: Dict[str, str] = {
        "id": id_,
        "nix_store_path": store_path,
        # For convenience, also output the path on the server where we store the
        # image and verity file. To keep paths in e.g. systemd units and process
        # explorers readable, truncate the id to 6 characters (30 bits base32),
        # which is plenty to avoid collisions because we already scope the name.
        "img_store_path": f"/var/lib/images/{name}/{id_[:6]}",
    }

    for fname in os.listdir(store_path):
        if fname.endswith(".img"):
            entry["image_file"] = fname

        if fname.endswith(".verity"):
            entry["verity_file"] = fname

        if fname.endswith(".roothash"):
            with open(os.path.join(store_path, fname), "r", encoding="ascii") as f:
                entry["verity_roothash"] = f.read().strip()

        result[name] = entry


json.dump(result, sys.stdout, indent=2)
sys.stdout.write("\n")
