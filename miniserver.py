#!/usr/bin/env python3
# Copyright 2021 Ruud van Asseldonk

"""
Miniserver -- deploy a self-contained nginx and acme-client image.

USAGE

    miniserver.py deploy <host>

ARGUMENTS

    <host>    The host to deploy to, must be an ssh hostname.
"""

import os
import subprocess
import sys
import time
import uuid

from contextlib import contextmanager
from typing import Iterator

from nix_store import NIX_BIN, ensure_pinned_nix_version, run

def get_current_image_path() -> str:
    ensure_pinned_nix_version()
    return run(f'{NIX_BIN}/nix', 'path-info').rstrip('\n')


@contextmanager
def sshfs(host: str) -> Iterator[str]:
    """
    Context manager that mounts /var/lib/miniserver through sshfs on a temporary
    directory. Returns the path of that temporary directory.
    """
    tmp_path = f'/tmp/miniserver-{uuid.uuid4()}'
    os.makedirs(tmp_path)
    proc = subprocess.Popen(
        ['sshfs', '-f', f'{host}:/var/lib/miniserver', tmp_path],
        stdout=subprocess.DEVNULL,
    )

    # Wait up to 10 seconds until the sshfs is mounted.
    for _ in range(100):
        fstype = run('stat', '--format', '%T', '--file-system', tmp_path).strip()
        if fstype == 'fuseblk':
            break
        sleep_seconds = 0.1
        time.sleep(sleep_seconds)

    yield tmp_path

    proc.terminate()
    timeout_seconds = 10
    proc.wait(timeout_seconds)
    os.rmdir(tmp_path)


def main() -> None:
    args = sys.argv[1:]

    if len(args) == 0:
        print(__doc__)
        sys.exit(1)

    cmd, args = args[0], args[1:]
    if cmd != 'deploy':
        print('Invalid command:', cmd)
        print(__doc__)
        sys.exit(1)

    if len(args) == 0:
        print('Missing <host>')
        print(__doc__)
        sys.exit(1)

    host = args[0]

    with sshfs(host) as tmp_path:
        print(tmp_path)


if __name__ == '__main__':
    main()
