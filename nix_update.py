#!/bin/env python3

from __future__ import annotations

"""
Update the pinned Nixpkgs snapshot to the latest available Nixpkgs commit, and
if the new snapshot contains interesting changes, commit the update, including
the changes in the commit message.

Usage:

  nix_update.py [<owner> [<repo> [<branch> | <commit-hash>]]]

Defaults to the NixOS/nixpkgs repository and the nixos-unstable branch.
"""

import datetime
import json
import os
import re
import subprocess
import sys
import textwrap
import urllib.request
import uuid

from typing import Any, Dict, Iterable, List, NamedTuple, Optional, Set, Union

from miniserver import Manifest
from nix_store import ClosureInfo, Package, get_closure_info, run
from nix_store import NIX_BIN, ensure_pinned_nix_version
from nix_diff import Addition, Change, Diff, Removal, diff, format_difflist


class Branch(NamedTuple):
    name: str
    # Sha of the commit that the branch currently points to.
    head: str


class Commit(NamedTuple):
    # Sha of the commit itself.
    head: str


def is_commit_hash(ref: str) -> bool:
    return re.fullmatch("[0-9a-f]{40}", ref) is not None


def get_branch_head(owner: str, repo: str, branch: str) -> Branch:
    """
    Return the current HEAD commit hash of the given branch. This queries the
    GitHub API.
    """
    url = f"https://api.github.com/repos/{owner}/{repo}/git/refs/heads/{branch}"
    response = urllib.request.urlopen(url)
    body = json.load(response)
    sha: str = body["object"]["sha"]
    return Branch(branch, sha)


def get_committer_date(owner: str, repo: str, commit_hash: str) -> str:
    """
    Return the committer date of the given commit. This queries the GitHub API.
    """
    url = (
        f"https://api.github.com/repos/{owner}/{repo}/commits/{commit_hash}?per_page=0"
    )
    response = urllib.request.urlopen(url)
    body = json.load(response)
    timestamp: str = body["commit"]["committer"]["date"]

    # Ensure that we can parse the timestamp.
    datetime.datetime.fromisoformat(timestamp)

    return timestamp


def get_latest_revision(
    owner: str, repo: str, branch_or_sha: str
) -> Union[Branch, Commit]:
    """
    Return the HEAD commit of the branch, or the commit itself if it was provided.
    """
    if is_commit_hash(branch_or_sha):
        return Commit(branch_or_sha)
    else:
        return get_branch_head(owner, repo, branch_or_sha)


def prefetch_url(url: str) -> str:
    """
    Prefetch a file into the Nix store and return its sha256.
    """
    result_raw = run(
        f"{NIX_BIN}/nix",
        "--extra-experimental-features",
        "nix-command",
        "--extra-experimental-features",
        "flakes",
        "flake",
        "prefetch",
        "--json",
        url,
    )
    result = json.loads(result_raw)
    result_hash: str = result["hash"]
    return result_hash


def format_nixpkgs_pin(owner: str, repo: str, commit_hash: str) -> str:
    """
    For a given Nixpkgs commit, return the expression with metadata and the
    fetchTarball to fetch it.
    """
    url = f"https://github.com/{owner}/{repo}/archive/{commit_hash}.tar.gz"
    committer_date = get_committer_date(owner, repo, commit_hash)
    archive_hash = prefetch_url(url)

    nix_expr = textwrap.dedent(f"""\
        rec {{
          owner = "{owner}";
          repo = "{repo}";
          commit = "{commit_hash}";
          commit_date = "{committer_date}";
          tarball = fetchTarball {{
            url = "https://github.com/${{owner}}/${{repo}}/archive/${{commit}}.tar.gz";
            sha256 = "{archive_hash}";
          }};
        }}
        """)
    return textwrap.dedent(nix_expr)


class Diffs(NamedTuple):
    build: List[Diff]
    runtime: List[Diff]

    def __len__(self) -> int:
        return len(self.build) + len(self.runtime)


def get_union_closure_info(manifest: Manifest) -> ClosureInfo:
    """
    For a given manfiest file, load the closure info of each package in it,
    and union those.
    """
    packages_fname = os.path.join(manifest.nix_store_path, "packages.json")
    return get_closure_info(packages_fname)


class UpdateResult(NamedTuple):
    diff: Diffs
    size_bytes_before: int
    size_bytes_after: int


def try_update_nixpkgs(image: str, pinned_expr: str) -> Optional[UpdateResult]:
    """
    Replace nixpkgs-pinned.nix with a newer version that fetches the latest
    commit in the given channel, and build default.nix. Return the resulting
    changes. The caller must restore nixpkgs-pinned.nix.bak to undo the change.
    """
    tmp_path = f"/tmp/nix-{image}-{uuid.uuid4()}"
    before_path = f"{tmp_path}-before"
    after_path = f"{tmp_path}-after"

    subprocess.run(
        [
            f"{NIX_BIN}/nix",
            "--extra-experimental-features",
            "nix-command",
            "build",
            "--file",
            f"images/{image}/default.nix",
            "--out-link",
            before_path,
        ]
    )

    os.rename(
        f"images/{image}/nixpkgs-pinned.nix",
        f"images/{image}/nixpkgs-pinned.nix.bak",
    )
    with open(f"images/{image}/nixpkgs-pinned.nix", "w", encoding="utf-8") as f:
        f.write(pinned_expr)

    subprocess.run(
        [
            f"{NIX_BIN}/nix",
            "--extra-experimental-features",
            "nix-command",
            "build",
            "--file",
            f"images/{image}/default.nix",
            "--out-link",
            after_path,
        ]
    )

    before_manifest = Manifest.load(before_path)
    after_manifest = Manifest.load(after_path)

    # If the Nix store path of the image did not change, then for sure nothing
    # changed, we don't even need to bother to check.
    if before_manifest.id == after_manifest.id:
        return None

    before_info = get_union_closure_info(before_manifest)
    after_info = get_union_closure_info(after_manifest)

    diffs_build = list(diff(sorted(before_info.build), sorted(after_info.build)))
    diffs_runtime = list(diff(sorted(before_info.runtime), sorted(after_info.runtime)))

    return UpdateResult(
        diff=Diffs(diffs_build, diffs_runtime),
        size_bytes_before=before_manifest.image_size_bytes,
        size_bytes_after=after_manifest.image_size_bytes,
    )


def summarize(image: str, diffs: Diffs) -> Optional[str]:
    """
    Return a short subject line that summarizes the diff. Returns none if we
    can't find a good summary.
    """
    changes_build: List[Change] = []
    changes_runtime: List[Change] = []
    num_other_changes = 0

    for diff in diffs.build:
        if isinstance(diff, Change):
            changes_build.append(diff)
        # We don't count build additions and removals as "other changes",
        # because we can't reliably gather build dependencies. Maybe we should
        # just stop listing these entirely ...

    for diff in diffs.runtime:
        if isinstance(diff, Change):
            changes_runtime.append(diff)
        else:
            num_other_changes += 1

    # We list packages by shortest name first, to get as much information in the
    # subject line as possible.
    changes_build.sort(key=lambda change: len(change.after.name))
    changes_runtime.sort(key=lambda change: len(change.after.name))

    # The most important package is the one that the image is named after,
    # so extract that one out if one exists.
    changes_primary = [ch for ch in changes_runtime if ch.after.name.startswith(image)]
    for ch in changes_primary:
        changes_runtime.remove(ch)

    if len(changes_runtime) + len(changes_build) == 0:
        return None

    def tail(n: int) -> str:
        if num_other_changes + n == 0:
            return ""
        elif num_other_changes + n == 1:
            return ", and one more change"
        else:
            return f", and {num_other_changes + n} changes"

    # Combine all changes, but prefer runtime deps over build deps when space
    # is scarce. Generate both long-form updates and short-form updates.
    # We keep the primary separate because those should always include the
    # version.
    changes = changes_runtime + changes_build
    prefix = [f"{ch.after.name} {ch.after.version}" for ch in changes_primary]
    changes_long = prefix + [f"{ch.after.name} {ch.after.version}" for ch in changes]
    changes_short = prefix + [ch.after.name for ch in changes]

    # Generate all possible messages, in order of preference. We prefer to
    # include as much names as possible, and we prefer to have them with
    # versions over not having versions.
    messages = []
    omitted = 0
    while len(changes_long) > 0:
        messages.append(f"Update {image}: " + ", ".join(changes_long) + tail(omitted))
        messages.append(f"Update {image}: " + ", ".join(changes_short) + tail(omitted))
        changes_long.pop()
        changes_short.pop()
        omitted += 1

    # Then take the most preferred message that still fits in the conventional
    # Git subject line limit
    for message in messages:
        if len(message) < 52:
            return message

    # If nothing fits, return the shortest message we had, if any.
    if len(messages) > 0:
        return messages[-1]

    return None


def commit_nixpkgs_pinned(
    image: str,
    owner: str,
    repo: str,
    revision: Union[Branch, Commit],
    update: UpdateResult,
) -> None:
    """
    Commit nixpkgs-pinned.nix, and include the diff in the message.
    """
    run("git", "add", f"images/{image}/nixpkgs-pinned.nix")

    if isinstance(revision, Branch):
        message = (
            "This updates the pinned Nixpkgs snapshot "
            f"for {image} to the latest commit "
            f"in the {revision.name} branch of {owner}/{repo}."
        )
    else:
        message = (
            "This updates the pinned Nixpkgs snapshot "
            f"for {image} to commit {revision.head} of {owner}/{repo}."
        )

    body_lines = [*textwrap.wrap(message, width=72)]

    growth = update.size_bytes_after / update.size_bytes_before - 1.0
    body_lines += [
        "",
        (
            "Image size: "
            + f"{update.size_bytes_before * 1e-6:,.2f} MB -> "
            + f"{update.size_bytes_after * 1e-6:,.2f} MB "
            + f"({growth:+.1%})"
        ),
    ]

    if len(update.diff.runtime) > 0:
        body_lines += [
            "",
            "Runtime dependencies:",
            "",
            *format_difflist(update.diff.runtime),
        ]

    if len(update.diff.build) > 0:
        body_lines += [
            "",
            "Build dependencies:",
            "",
            *format_difflist(update.diff.build),
        ]

    subject_opt = summarize(image, update.diff)
    subject = subject_opt or (
        f"Update {image} to latest commit in {owner}/{repo} {revision.name}"
        if isinstance(revision, Branch)
        else f"Update {image} to pinned commit in {owner}/{repo}"
    )

    body = "\n".join(body_lines)
    message = f"{subject}\n\n{body}\n"
    subprocess.run(["git", "commit", "--message", message])

    # If we commit the new file, then we no longer need the backup.
    os.remove(f"images/{image}/nixpkgs-pinned.nix.bak")

    if isinstance(revision, Branch):
        print(f"Committed update to latest commit in {owner}/{repo} {revision.name}")
    else:
        print(f"Committed update to {owner}/{repo} {revision.head}")


def main(owner: str, repo: str, branch_or_sha: str) -> None:
    """
    Update to the latest commit in the given branch (called channel for Nixpkgs),
    and commit that, if newer versions of a dependency are available.
    """
    ensure_pinned_nix_version()

    images = os.listdir("images")
    n = 1 + len(images)

    revision = get_latest_revision(owner, repo, branch_or_sha)
    if isinstance(revision, Branch):
        print(f"[1/{n}] Fetching latest commit in {owner}/{repo} {revision.name} ...")
    else:
        print(f"[1/{n}] Fetching {owner}/{repo} {revision.head} ...")

    pinned_expr = format_nixpkgs_pin(owner, repo, revision.head)

    for i, image in enumerate(images):
        print(f"[{i+1}/{n}] Building {image} ...")
        result = try_update_nixpkgs(image, pinned_expr)
        if (result is not None) and (len(result.diff.runtime) > 0):
            commit_nixpkgs_pinned(image, owner, repo, revision, result)
        else:
            # If there were no changes in the runtime paths, then the new pinned
            # revision is not useful to this project, so restore the previously
            # pinned revision in order to not introduce unnecessary churn. The
            # store paths can still change. That might mean that e.g. the
            # compiler changed.
            os.rename(
                f"images/{image}/nixpkgs-pinned.nix.bak",
                f"images/{image}/nixpkgs-pinned.nix",
            )

            if isinstance(revision, Branch):
                print(
                    f"Latest commit in {revision.name} branch has no interesting changes."
                )
            else:
                print(f"Commit {revision.head} has no interesting changes.")


def getarg(n: int, default: str) -> str:
    return sys.argv[n] if len(sys.argv) > n else default


if __name__ == "__main__":
    main(
        owner=getarg(1, "nixos"),
        repo=getarg(2, "nixpkgs"),
        branch_or_sha=getarg(3, "nixos-unstable"),
    )
