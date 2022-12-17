#!/usr/bin/env python3
# Copyright 2022 Ruud van Asseldonk

"""
Miniserver -- deploy a self-contained nginx and lego image.

USAGE

    miniserver.py <command> <host>

COMMANDS

   deploy     Deploy the currently checked-out version.
   status     Print currently deployed version and status of the nginx unit.
   install    Perform first-time installation on a fresh host.
   gc         Remove old versions from the store.
              Note, gc also happens automatically after deploy, the manual
              command is here mostly for testing purposes.

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
from typing import Dict, Iterator, Tuple

from nix_store import NIX_BIN, ensure_pinned_nix_version, run


def get_current_release_path() -> str:
    ensure_pinned_nix_version()
    return run(f"{NIX_BIN}/nix", "path-info").rstrip("\n")


def copy_replace_file(
    src_fname: str,
    dst_fname: str,
    replaces: Dict[str, str],
) -> None:
    """
    Copy a text file from src to dst, replacing some strings while doing so.
    A rudimentary templating engine, if you like.
    """
    with open(src_fname, "r", encoding="utf-8") as src:
        with open(dst_fname, "w", encoding="utf-8") as dst:
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
    tmp_path = f"/tmp/miniserver-{uuid.uuid4()}"
    os.makedirs(tmp_path)
    proc = subprocess.Popen(
        ["sshfs", "-f", f"{host}:/var/lib/miniserver", tmp_path],
        stdout=subprocess.DEVNULL,
    )

    # Wait up to 10 seconds until the sshfs is mounted.
    for _ in range(100):
        fstype = run("stat", "--format", "%T", "--file-system", tmp_path).strip()
        if fstype == "fuseblk":
            break
        sleep_seconds = 0.1
        time.sleep(sleep_seconds)

    yield tmp_path

    proc.terminate()
    timeout_seconds = 10
    proc.wait(timeout_seconds)
    os.rmdir(tmp_path)


def get_renew_time(host: str) -> str:
    """
    Pick a time of the day at which certificats should be renewed, based on the
    hostname. This function is deterministic, so a given hostname will always
    renew at the same time of the day, but across all servers that run this, the
    load will be spread out.
    """
    from random import Random

    rng = Random(host)
    minutes_since_midnight = rng.randrange(0, 60 * 24)
    hh, mm = minutes_since_midnight // 60, minutes_since_midnight % 60
    return f"{hh:02}:{mm:02}"


def deploy_image(
    release_name: str,
    release_path: str,
    tmp_path: str,
    renew_time: str,
) -> None:
    target_dir = f"{tmp_path}/store/{release_name}"
    now = datetime.now(timezone.utc)

    os.makedirs(target_dir, exist_ok=True)
    shutil.copyfile(f"{release_path}/miniserver.img", f"{target_dir}/miniserver.img")
    shutil.copyfile(
        f"{release_path}/miniserver.img.verity", f"{target_dir}/miniserver.img.verity"
    )

    roothash = open(
        f"{release_path}/miniserver.img.roothash", "r", encoding="ascii"
    ).readline()

    copy_replace_file(
        "nginx.service",
        f"{target_dir}/nginx.service",
        {
            "{{ROOT_IMAGE}}": f"/var/lib/miniserver/store/{release_name}/miniserver.img",
            "{{ROOT_HASH}}": roothash,
        },
    )
    copy_replace_file(
        "lego.service",
        f"{target_dir}/lego.service",
        {
            "{{ROOT_IMAGE}}": f"/var/lib/miniserver/store/{release_name}/miniserver.img",
            "{{ROOT_HASH}}": roothash,
        },
    )
    copy_replace_file(
        "lego.timer",
        f"{target_dir}/lego.timer",
        {
            "{{RENEW_TIME}}": renew_time,
        },
    )
    copy_replace_file(
        "nginx-reload-config.service",
        f"{target_dir}/nginx-reload-config.service",
        {},
    )

    # Record when we deployed this version.
    with open(f"{tmp_path}/deploy.log", "a", encoding="utf-8") as deploylog:
        deploylog.write(f"{now.isoformat()} {release_name}\n")

    try:
        before_link = os.readlink(f"{tmp_path}/current")
        if before_link == f"store/{release_name}":
            print('Re-deploying, not updating "previous" link.')
            os.remove(f"{tmp_path}/current")
        else:
            print(f'Linked "previous" -> "{before_link}".')
            os.replace(f"{tmp_path}/current", f"{tmp_path}/previous")

    except FileNotFoundError:
        print('No current deployment found, not creating a "previous" link.')
        pass

    os.symlink(
        src=f"store/{release_name}",
        dst=f"{tmp_path}/current",
        target_is_directory=True,
    )
    print(f'Linked "current" -> "store/{release_name}".')
    gc_store(tmp_path, max_size_bytes=550_000_000)


def get_store_size_bytes(tmp_path: str) -> int:
    store_path = os.path.join(tmp_path, "store")
    return sum(
        os.stat(os.path.join(dirpath, fname)).st_size
        for dirpath, _dirnames, fnames in os.walk(store_path)
        for fname in fnames
    )


def read_version_link(tmp_path: str, link_name: str) -> str:
    """
    Read a symlink, return the version directory it points to,
    without 'store' prefix.
    """
    return os.readlink(f"{tmp_path}/{link_name}").removeprefix("store/")


def gc_store(tmp_path: str, max_size_bytes: int):
    sizes: Dict[str, int] = {}
    store_path = os.path.join(tmp_path, "store")
    for version in os.listdir(store_path):
        version_path = os.path.join(store_path, version)
        size_bytes = sum(
            os.stat(os.path.join(dirpath, fname)).st_size
            for dirpath, _dirnames, fnames in os.walk(version_path)
            for fname in fnames
        )
        sizes[version] = size_bytes

    # Build the ordered candidates for deletion, ordered by most recently
    # deployed first (those must be kept).
    candidates: Dict[str, Tuple[int, str]] = {}

    with open(f"{tmp_path}/deploy.log", "r", encoding="utf-8") as f:
        for line in reversed(f.readlines()):
            time, name = line.strip().split(" ")
            if name in sizes and name not in candidates:
                candidates[name] = sizes[name], time

    budget_bytes = max_size_bytes

    # We should not GC anything that has a link pointing to it.
    current_name = read_version_link(tmp_path, "current")
    previous_name = read_version_link(tmp_path, "previous")
    budget_bytes -= candidates.pop(current_name)[0]
    budget_bytes -= candidates.pop(previous_name)[0]

    # Keep as many of the most recent releases as will fit the budget.
    to_keep = set()
    for name, (size, time) in candidates.items():
        if budget_bytes > size:
            to_keep.add(name)
            budget_bytes -= size
        else:
            break

    to_delete = [
        (name, size)
        for name, (size, _time) in candidates.items()
        if name not in to_keep
    ]

    if len(to_delete) == 0:
        print("GC: No candidates to delete from the store.")
        return

    freed_bytes = sum(size for _name, size in to_delete)
    freed_mb = freed_bytes / 1e6
    print(
        f"GC: Deleting the {len(to_delete)} least recently deployed versions "
        f"to free up {freed_mb:,.2f} MB of space."
    )
    for name, size in to_delete:
        print(f"  {name} ({size / 1e6:,.2f} MB)", end="")
        shutil.rmtree(os.path.join(store_path, name))
        print(" deleted")


def main() -> None:
    args = sys.argv[1:]

    if len(args) == 0:
        print(__doc__)
        sys.exit(1)

    cmd, args = args[0], args[1:]
    if cmd not in ("deploy", "gc", "status", "install"):
        print("Invalid command:", cmd)
        print(__doc__)
        sys.exit(1)

    if len(args) == 0:
        print("Missing <host>")
        print(__doc__)
        sys.exit(1)

    host = args[0]

    release_path = get_current_release_path()
    release_name = os.path.basename(release_path).split("-")[0]
    renew_time = get_renew_time(host)

    if cmd == "deploy":
        print("Deploying", release_path, "...")

        with sshfs(host) as tmp_path:
            deploy_image(release_name, release_path, tmp_path, renew_time)

            print("Restarting nginx ...")
            subprocess.run(
                [
                    "ssh",
                    host,
                    "sudo systemctl daemon-reload && "
                    "sudo systemctl restart nginx && "
                    "sudo env SYSTEMD_COLORS=256 systemctl status nginx",
                ]
            )

    if cmd == "status":
        with sshfs(host) as tmp_path:
            current_name = read_version_link(tmp_path, "current")
            previous_name = read_version_link(tmp_path, "previous")
            store_size_bytes = get_store_size_bytes(tmp_path)
            store_size_mb = store_size_bytes / 1e6
            print(f"Current local version:      {release_name}")
            print(f"Current remote deployment:  {current_name}")
            print(f"Previous remote deployment: {previous_name}")
            print(f"Store size:                 {store_size_mb:,.2f} MB")
            print("Latest deployment log entries:")
            with open(f"{tmp_path}/deploy.log", "r", encoding="utf-8") as f:
                for line in reversed(f.readlines()[-5:]):
                    # Cut out the T from the timestamp to make it more readable.
                    print("  ", line[:10], line[11:], end="")

            print()
            subprocess.run(
                [
                    "ssh",
                    host,
                    "sudo env SYSTEMD_COLORS=256 systemctl status nginx",
                ]
            )

    if cmd == "gc":
        with sshfs(host) as tmp_path:
            gc_store(tmp_path, max_size_bytes=550_000_000)

    if cmd == "install":
        print("Deploying", release_path, "...")
        with sshfs(host) as tmp_path:
            deploy_image(release_name, release_path, tmp_path, renew_time)

            print("Linking, enabling, and starting systemd units ...")
            subprocess.run(
                [
                    "ssh",
                    host,
                    "sudo ln -fs /var/lib/miniserver/current/nginx.service /etc/systemd/system/nginx.service && "
                    "sudo ln -fs /var/lib/miniserver/current/nginx-reload-config.service /etc/systemd/system/nginx-reload-config.service && "
                    "sudo ln -fs /var/lib/miniserver/current/lego.service /etc/systemd/system/lego.service && "
                    "sudo ln -fs /var/lib/miniserver/current/lego.timer /etc/systemd/system/lego.timer && "
                    "sudo systemctl daemon-reload && "
                    "sudo systemctl enable --now nginx.service && "
                    "sudo systemctl enable --now lego.timer && "
                    "sudo env SYSTEMD_COLORS=256 systemctl status nginx.service lego.timer",
                ]
            )


if __name__ == "__main__":
    main()
