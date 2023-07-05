#!/usr/bin/env python3
# Copyright 2022 Ruud van Asseldonk

"""
Compute a blake2bsum but format it as UUID. Used to set the dm-verity volume
UUID and salt in a reproducible manner.
"""

import sys
from hashlib import blake2b
from uuid import UUID

with open(sys.argv[2], "rb") as f:
    if sys.argv[1] == "uuid":
        print(UUID(blake2b(f.read(), digest_size=16).hexdigest()))

    elif sys.argv[1] == "salt":
        print(blake2b(f.read(), digest_size=32).hexdigest())

    else:
        print("Usage: ./deterministic_uuid.py <uuid|salt> <file>")
