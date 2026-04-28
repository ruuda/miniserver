#!/usr/bin/env python3
# Copyright 2026 Ruud van Asseldonk

"""
Miniserver -- deploy self-contained erofs images for webserver software

USAGE

    miniserver.py <command> <host>...

COMMANDS

   deploy     Deploy the currently checked-out version.
   status     Print currently deployed version and status of the nginx unit.
   gc         Remove old versions from the store.
              Note, gc also happens automatically after deploy, the manual
              command is here mostly for testing purposes.

ARGUMENTS

    <host>    The hosts to deploy to, must be an ssh hostname.
"""

import json
import os
import shutil
import subprocess
import sys
import time
import uuid

from contextlib import contextmanager
from datetime import datetime, timezone
from hashlib import blake2b
from typing import Dict, Iterator, List, NamedTuple, Tuple

from nix_store import NIX_BIN, ensure_pinned_nix_version, run


class ManifestEntry(NamedTuple):
    id: str
    nix_store_path: str
    img_store_path: str
    image_file: str
    verity_file: str
    verity_roothash: str


def get_current_manifest() -> Dict[str, ManifestEntry]:
    ensure_pinned_nix_version()
    path = run(
        f"{NIX_BIN}/nix",
        "--extra-experimental-features",
        "nix-command",
        "path-info",
        "--file",
        "default.nix",
    ).rstrip("\n")
    with open(path, "r", encoding="utf-8") as f:
        return {
            name: ManifestEntry(**entry)
            for name, entry in json.load(f).items()
        }


@contextmanager
def sshfs(host: str) -> Iterator[str]:
    """
    Context manager that mounts /var/lib/images through sshfs on a temporary
    directory. Returns the path of that temporary directory.
    """
    tmp_path = f"/tmp/miniserver-{uuid.uuid4()}"

    os.makedirs(tmp_path)
    stat_before = os.stat(tmp_path)

    proc = subprocess.Popen(
        ["sshfs", "-f", f"{host}:/var/lib/images", tmp_path],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        encoding="utf-8",
    )

    # Wait up to 10 seconds until the sshfs is mounted and stat-able.
    is_ok = False
    for _ in range(200):
        try:
            # If the stat output changed from before we tried to mount something
            # there, that means the mount is now complete.
            stat_after = os.stat(tmp_path)
            if stat_after != stat_before:
                is_ok = True
                break

        except OSError as exc:
            # During setup, we get Errno 107, Transport endpoint is not connected.
            pass

        try:
            sleep_seconds = 0.05
            proc.wait(sleep_seconds)
            break

        except subprocess.TimeoutExpired:
            # If the wait failed then the process is still running
            continue

    # If we failed to mount the sshfs because the images directory does not yet
    # exist on the host, that's something we can easily fix. We need to know
    # then whether the process exited already.
    if proc.returncode is not None:
        assert proc.stderr is not None
        if "/var/lib/images: No such file or directory" in proc.stderr.read():
            print("/var/lib/images does not yet exist on the remote host, creating ...")
            subprocess.run([
                "ssh",
                host,
                "sudo mkdir -p /var/lib/images && ",
                "sudo chown $USER /var/lib/images",
            ])
            print("Directory created, retry now.")
            sys.exit(1)

    assert is_ok
    yield tmp_path

    proc.terminate()
    timeout_seconds = 10
    proc.wait(timeout_seconds)
    os.rmdir(tmp_path)


def deploy_image(
    tmp_path: str,
    entry: ManifestEntry,
) -> None:
    target_sub = entry.img_store_path.removeprefix("/var/lib/images/")
    target_dir = f"{tmp_path}/{target_sub}"
    now = datetime.now(timezone.utc)

    os.makedirs(target_dir, exist_ok=True)
    for fname in [entry.image_file, entry.verity_file]:
        src = f"{entry.nix_store_path}/{fname}"
        dst = f"{target_dir}/{fname}"

        # Note, we don't read back the file to confirm that the copy arrived
        # unscathed. The image is already protected by dm-verity and we send
        # over the verity roothash out of band, so corruption will be detected.
        # It's not worth complicating things with `-o direct_io` or separate
        # SSH invocations to verify the checksums.
        shutil.copyfile(src, dst)

    # Record when we deployed this version.
    with open(f"{tmp_path}/deploy.log", "a", encoding="utf-8") as deploylog:
        deploylog.write(f"{now.isoformat()}\t{target_sub}\t{entry.image_file}\n")


def get_file_size_bytes(path: str) -> int:
    try:
        return os.stat(path).st_size
    except FileNotFoundError:
        return 0


def get_store_size_bytes(tmp_path: str) -> int:
    return sum(
        get_file_size_bytes(os.path.join(dirpath, fname))
        for dirpath, _dirnames, fnames in os.walk(tmp_path)
        for fname in fnames
    )


def gc_store(tmp_path: str, max_size_bytes: int, keep_subdirs: List[str]) -> None:
    sizes: Dict[str, int] = {}
    for pkg in os.listdir(tmp_path):
        pkg_path = os.path.join(tmp_path, pkg)
        if not os.path.isdir(pkg_path):
            continue
        for version in os.listdir(pkg_path):
            version_path = os.path.join(tmp_path, version)
            size_bytes = sum(
                get_file_size_bytes(os.path.join(dirpath, fname))
                for dirpath, _dirnames, fnames in os.walk(version_path)
                for fname in fnames
            )
            sizes[f"{pkg}/{version}"] = size_bytes

    # Build the ordered candidates for deletion, ordered by most recently
    # deployed first (those must be kept).
    candidates: Dict[str, Tuple[int, str]] = {}

    with open(f"{tmp_path}/deploy.log", "r", encoding="utf-8") as f:
        for line in reversed(f.readlines()):
            time, subdir, pkgname_ = line.strip().split()
            if subdir in sizes and subdir not in candidates:
                candidates[subdir] = sizes[subdir], time

    budget_bytes = max_size_bytes

    # We should not GC anything that we are instructed to keep.
    for keep_subdir in keep_subdirs:
        budget_bytes -= candidates.pop(keep_subdir)[0]

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
        f"GC: Deleting the {len(to_delete)} least recently deployed images "
        f"to free up {freed_mb:,.2f} MB of space."
    )
    for subdir, size in to_delete:
        print(f"  {subdir} ({size / 1e6:,.2f} MB)", end="")
        shutil.rmtree(os.path.join(tmp_path, subdir))
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


    manifest = get_current_manifest()
    pkg_subdirs = [
        entry.img_store_path.removeprefix("/var/lib/images/")
        for entry in manifest.values()
    ]

    for host in args:
        if cmd == "deploy":
            print(f"Connecting to {host} ...")
            with sshfs(host) as tmp_path:
                for name, entry in manifest.items():
                    print(f"=> {entry.img_store_path}/{entry.image_file}")
                    deploy_image(tmp_path, entry)
                gc_store(
                    tmp_path,
                    max_size_bytes=550_000_000,
                    keep_subdirs=pkg_subdirs,
                )

        if cmd == "status":
            with sshfs(host) as tmp_path:
                store_size_bytes = get_store_size_bytes(tmp_path)
                store_size_mb = store_size_bytes / 1e6
                print(f"Store size: {store_size_mb:,.2f} MB")
                print("Latest deployment log entries:")
                try:
                    with open(f"{tmp_path}/deploy.log", "r", encoding="utf-8") as f:
                        for line in f.readlines()[-10:]:
                            # Cut out the T from the timestamp
                            # to make it more readable.
                            print("  ", line[:10], line[11:], end="")
                except FileNotFoundError:
                    print("  (deploy log is empty)")

        if cmd == "gc":
            with sshfs(host) as tmp_path:
                gc_store(
                    tmp_path,
                    max_size_bytes=550_000_000,
                    keep_subdirs=pkg_subdirs,
                )


if __name__ == "__main__":
    main()
