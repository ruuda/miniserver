#!/usr/bin/env python3
# Copyright 2026 Ruud van Asseldonk

"""
Miniserver -- deploy self-contained erofs images for webserver software

USAGE

    miniserver.py <command> <host>...
    miniserver.py deploy <tree> [--image=<img>...] [--host=<host>...]

COMMANDS

   deploy     Deploy images to hosts.
   status     Print store details and recent deployment log.
   gc         Remove old versions from the store.
              Note, gc also happens automatically after deploy, the manual
              command is here mostly for testing purposes.

OPTIONS

   --image    Limit the image to deploy. Can be provided multiple times.
   --host     Limit the host to deploy to. Can be provided multiple times.

ARGUMENTS

    <host>    The hosts to deploy to, must be an ssh hostname.
    <tree>    A directory tree with one directory per host to deploy to
              (the directory name must be the hostname), and inside each
              directory, a file 'images.json' that contains a json list
              of the image manifests to deploy (as built with 'nix build').
"""

import json
import os
import shutil
import subprocess
import sys
import time
import uuid

from collections import defaultdict
from contextlib import contextmanager
from datetime import datetime, timezone
from hashlib import blake2b
from typing import Dict, Iterator, List, NamedTuple, Optional, Tuple, Set

from nix_store import NIX_BIN, ensure_pinned_nix_version, run


class Manifest(NamedTuple):
    name: str
    version: str
    id: str
    nix_store_path: str
    img_store_path: str
    image_file: str
    image_size_bytes: int
    verity_file: str
    verity_roothash: str
    nixpkgs_commit: str
    nixpkgs_date: str

    @staticmethod
    def load(fname: str) -> Manifest:
        with open(fname, "r", encoding="utf-8") as f:
            return Manifest(**json.load(f))

    def save(self, fname: str) -> None:
        with open(fname, "w", encoding="utf-8") as f:
            json.dump(self._asdict(), f, indent=2)


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
            subprocess.run(
                [
                    "ssh",
                    host,
                    "sudo mkdir -p /var/lib/images && ",
                    "sudo chown $USER /var/lib/images",
                ]
            )
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
    manifest: Manifest,
) -> None:
    target_sub = manifest.img_store_path.removeprefix("/var/lib/images/")
    target_dir = f"{tmp_path}/{target_sub}"
    now = datetime.now(timezone.utc)

    os.makedirs(target_dir, exist_ok=True)

    # If the image already exists, there is nothing for us to do here.
    target_manifest = f"{target_dir}/image.json"
    target_manifest_new = f"{target_dir}/image_partial.json"
    try:
        existing_manifest = Manifest.load(target_manifest)
        if existing_manifest == manifest:
            return
        else:
            print("Warning: Encountered different manifest, overwriting image.")

    except FileNotFoundError:
        pass

    manifest.save(target_manifest_new)

    for fname in [manifest.image_file, manifest.verity_file]:
        src = f"{manifest.nix_store_path}/{fname}"
        dst = f"{target_dir}/{fname}"

        # Note, we don't read back the file to confirm that the copy arrived
        # unscathed. The image is already protected by dm-verity and we send
        # over the verity roothash out of band, so corruption will be detected.
        # It's not worth complicating things with `-o direct_io` or separate
        # SSH invocations to verify the checksums.
        shutil.copyfile(src, dst)

    # Flush before we move image.json into its final place, we want image.json
    # to exist only if the entire image has been written.
    os.sync()
    os.rename(target_manifest_new, target_manifest)

    # Record when we deployed this version.
    with open(f"{tmp_path}/deploy.log", "a", encoding="utf-8") as deploylog:
        deploylog.write(f"{now.isoformat()}\t{target_sub}\t{manifest.image_file}\n")


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


def gc_store(tmp_path: str, max_size_bytes: int, subdirs: List[str]) -> None:
    sizes: Dict[str, int] = {}
    for pkg in subdirs:
        pkg_path = os.path.join(tmp_path, pkg)
        if not os.path.isdir(pkg_path):
            continue
        for version in os.listdir(pkg_path):
            version_path = os.path.join(pkg_path, version)
            size_bytes = sum(
                get_file_size_bytes(os.path.join(dirpath, fname))
                for dirpath, _dirnames, fnames in os.walk(version_path)
                for fname in fnames
            )
            sizes[f"{pkg}/{version}"] = size_bytes

    # Build the ordered candidates for deletion, ordered by most recently
    # deployed first (those must be kept).
    candidates: Dict[str, Tuple[int, str]] = {}

    # Per image, the versions to definitely keep. We keep the last two versions,
    # to enable rollback to still work after we put the new image in place and
    # activate it.
    keep_versions: Dict[str, Set[str]] = defaultdict(lambda: set())

    with open(f"{tmp_path}/deploy.log", "r", encoding="utf-8") as f:
        for line in reversed(f.readlines()):
            time, subdir, _imgfile = line.strip().split()
            img_name, version = subdir.split("/")
            if subdir in sizes and subdir not in candidates:
                candidates[subdir] = sizes[subdir], time

            keep = keep_versions[img_name]
            if len(keep) < 2:
                keep.add(subdir)

    budget_bytes = max_size_bytes

    # Keep as many of the most recent releases as will fit the budget, and also
    # the most recently deployed versions of every image/subdir we are touching.
    to_keep = {v for vs in keep_versions.values() for v in vs}
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

    max_len = max(len(subdir) for subdir, _size in to_delete)

    for subdir, size in to_delete:
        subdir_pad = subdir.ljust(max_len)
        print(f"  {subdir_pad} ({size / 1e6:,.2f} MB)", end="")
        shutil.rmtree(os.path.join(tmp_path, subdir))
        print(" deleted")


class DeploymentPlan(NamedTuple):
    """
    Load a deployment plan for a cluster from a config tree directory.
    """

    # Per host, the images that should be deployed there.
    hosts: Dict[str, List[Manifest]]

    @staticmethod
    def from_tree(tree_path: str) -> DeploymentPlan:
        """
        Load the plan from a directory structure where every directory is one
        host, and inside every directory is an `images.json` with manifests.
        """
        result: Dict[str, List[Manifest]] = {}
        for path in os.listdir(tree_path):
            try:
                with open(
                    os.path.join(tree_path, path, "images.json"), "r", encoding="utf-8"
                ) as f:
                    raw = json.load(f)
                    result[path] = [Manifest(**m) for m in raw]

            except (FileNotFoundError, NotADirectoryError):
                pass

        return DeploymentPlan(result)

    def filter_hosts(self, hosts: List[str]) -> DeploymentPlan:
        """
        Prune all hosts except those that occur in `hosts`.
        """
        return DeploymentPlan({h: ms for h, ms in self.hosts.items() if h in hosts})

    def filter_images(self, images: List[str]) -> DeploymentPlan:
        """
        Prune all images except those that occur in `images`.
        """
        return DeploymentPlan(
            {h: [m for m in ms if m.name in images] for h, ms in self.hosts.items()}
        )

    def prune_empty(self) -> DeploymentPlan:
        """
        Prune all hosts that have no images to deploy there.
        """
        return DeploymentPlan({h: ms for h, ms in self.hosts.items() if len(ms) > 0})


def main() -> None:
    args = sys.argv[1:]

    if len(args) == 0:
        print(__doc__)
        sys.exit(1)

    cmd, args = args[0], args[1:]
    if cmd not in ("deploy", "gc", "status"):
        print("Invalid command:", cmd)
        print(__doc__)
        sys.exit(1)

    if len(args) == 0:
        print("Missing <tree>")
        print(__doc__)
        sys.exit(1)

    images = []
    hosts = []
    config_dir: Optional[str] = None

    for arg in args:
        if arg.startswith("--image="):
            images.append(arg.removeprefix("--image="))
        elif arg.startswith("--host="):
            hosts.append(arg.removeprefix("--host="))
        elif config_dir is None:
            config_dir = arg
        else:
            print("Unexpected argument:", arg)
            print(__doc__)
            sys.exit(1)

    if config_dir is None:
        print("Expected <tree>")
        print(__doc__)
        sys.exit(1)

    plan = DeploymentPlan.from_tree(config_dir)

    if len(images) > 0:
        plan = plan.filter_images(images)

    if len(hosts) > 0:
        plan = plan.filter_hosts(hosts)

    plan = plan.prune_empty()

    for host, manifests in plan.hosts.items():
        print(host)
        for manifest in manifests:
            print(
                f"  {manifest.name:15} {manifest.version:8} "
                f"{manifest.image_size_bytes / 1e6:5.1f} MB  {manifest.id}"
            )

    if cmd == "deploy":
        for host, manifests in plan.hosts.items():
            images = [m.name for m in manifests]
            print(f"\nConnecting to {host} ...")
            with sshfs(host) as tmp_path:
                for manifest in manifests:
                    print(f"=> {manifest.img_store_path}/{manifest.image_file}")
                    deploy_image(tmp_path, manifest)
                gc_store(
                    tmp_path,
                    max_size_bytes=100_000_000 * len(images),
                    subdirs=images,
                )

    if cmd == "status":
        for host, manifests in plan.hosts.items():
            print(f"\nConnecting to {host} ...")
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
        for host, manifests in plan.hosts.items():
            print(f"\nConnecting to {host} ...")
            images = [m.name for m in manifests]
            with sshfs(host) as tmp_path:
                gc_store(
                    tmp_path,
                    max_size_bytes=100_000_000 * len(images),
                    subdirs=images,
                )


if __name__ == "__main__":
    main()
