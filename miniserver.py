#!/usr/bin/env python3
# Copyright 2022 Ruud van Asseldonk

"""
Miniserver -- deploy a self-contained nginx and acme-client image.

USAGE

    miniserver.py deploy <host>
    miniserver.py status <host>

ARGUMENTS

    <host>    The host to deploy to, must be an ssh hostname.
"""

import os
import shutil
import subprocess
import sys
import time
import uuid

from datetime import datetime, timezone
from contextlib import contextmanager
from typing import Dict, Iterator

from nix_store import NIX_BIN, ensure_pinned_nix_version, run


def get_current_release_path() -> str:
    ensure_pinned_nix_version()
    return run(f'{NIX_BIN}/nix', 'path-info').rstrip('\n')


def copy_replace_file(
    src_fname: str,
    dst_fname: str,
    replaces: Dict[str, str],
) -> None:
    """
    Copy a text file from src to dst, replacing some strings while doing so.
    A rudimentary templating engine, if you like.
    """
    with open(src_fname, 'r', encoding='utf-8') as src:
        with open(dst_fname, 'w', encoding='utf-8') as dst:
            for line in src:
                for needle, replacement in replaces.items():
                    line = line.replace(needle, replacement)
                dst.write(line)


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


def deploy_image(
    release_name: str,
    release_path: str,
    tmp_path: str,
) -> None:
    target_dir = f'{tmp_path}/store/{release_name}'
    now = datetime.now(timezone.utc)

    os.makedirs(target_dir, exist_ok=True)
    shutil.copyfile(f'{release_path}/miniserver.img', f'{target_dir}/miniserver.img')
    shutil.copyfile(f'{release_path}/miniserver.img.verity', f'{target_dir}/miniserver.img.verity')

    roothash = open(f'{release_path}/miniserver.img.roothash', 'r', encoding='ascii').readline()

    copy_replace_file(
        'nginx.service',
        f'{target_dir}/nginx.service',
        {
            '{{ROOT_IMAGE}}': f'/var/lib/miniserver/store/{release_name}/miniserver.img',
            '{{ROOT_HASH}}': roothash,
        },
    )
    copy_replace_file(
        'acme-client.service',
        f'{target_dir}/acme-client.service',
        {
            '{{ROOT_IMAGE}}': f'/var/lib/miniserver/store/{release_name}/miniserver.img',
            '{{ROOT_HASH}}': roothash,
        },
    )

    # Record when we deployed this version.
    with open(f'{tmp_path}/deploy.log', 'a', encoding='utf-8') as deploylog:
        deploylog.write(f'{now.isoformat()} {release_name}\n')

    try:
        before_link = os.readlink(f'{tmp_path}/current')
        if before_link == f'store/{release_name}':
            print('Re-deploying, not updating "previous" link.')
            os.remove(f'{tmp_path}/current')
        else:
            print(f'Linked "previous" -> "{before_link}".')
            os.replace(f'{tmp_path}/current', f'{tmp_path}/previous')

    except FileNotFoundError:
        print('No current deployment found, not creating a "previous" link.')
        pass

    os.symlink(
        src=f'store/{release_name}',
        dst=f'{tmp_path}/current',
        target_is_directory=True,
    )
    print(f'Linked "current" -> "store/{release_name}".')

    # TODO: Delete old releases.


def main() -> None:
    args = sys.argv[1:]

    if len(args) == 0:
        print(__doc__)
        sys.exit(1)

    cmd, args = args[0], args[1:]
    if cmd not in ('deploy', 'status'):
        print('Invalid command:', cmd)
        print(__doc__)
        sys.exit(1)

    if len(args) == 0:
        print('Missing <host>')
        print(__doc__)
        sys.exit(1)

    host = args[0]

    release_path = get_current_release_path()
    release_name = os.path.basename(release_path).split('-')[0]

    if cmd == 'deploy':
        print('Deploying', release_path, '...')

        with sshfs(host) as tmp_path:
            deploy_image(release_name, release_path, tmp_path)

            print('Restarting nginx ...')
            subprocess.run([
                'ssh', host,
                'sudo systemctl daemon-reload && '
                'sudo systemctl restart nginx && '
                'sudo env SYSTEMD_COLORS=256 systemctl status nginx',
            ])

    if cmd == 'status':
        with sshfs(host) as tmp_path:
            current_link = os.readlink(f'{tmp_path}/current')
            print(f'Current local version:     {release_name}')
            print(f'Current remote deployment: {current_link.removeprefix("store/")}')
            print('Latest deployment log entries:')
            with open(f'{tmp_path}/deploy.log', 'r', encoding='utf-8') as f:
                for line in f.readlines()[-5:]:
                    print('  ', line, end='')

            print()
            subprocess.run([
                'ssh', host,
                'sudo env SYSTEMD_COLORS=256 systemctl status nginx',
            ])



if __name__ == '__main__':
    main()
