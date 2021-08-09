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
 
import json
import os
import re
import subprocess
import sys
import textwrap
import urllib.request
import uuid

from typing import Any, Dict, Iterable, List, NamedTuple, Optional, Union

from nix_store import get_build_requisites, get_runtime_requisites, run
from nix_diff import Addition, Change, Diff, Removal, diff, format_difflist

class Branch(NamedTuple):
    name: str
    # Sha of the commit that the branch currently points to.
    head: str


class Commit(NamedTuple):
    # Sha of the commit itself.
    head: str


def is_commit_hash(ref: str) -> bool:
    return re.fullmatch('[0-9a-f]{40}', ref) is not None


def get_branch_head(owner: str, repo: str, branch: str) -> Branch:
    """
    Return the current HEAD commit hash of the given branch. This queries the
    GitHub API.
    """
    url = f'https://api.github.com/repos/{owner}/{repo}/git/refs/heads/{branch}'
    response = urllib.request.urlopen(url)
    body = json.load(response)
    sha: str = body['object']['sha']
    return Branch(branch, sha)


def get_latest_revision(owner: str, repo: str, branch_or_sha: str) -> Union[Branch, Commit]:
    """
    Return the HEAD commit of the branch, or the commit itself if it was provided.
    """
    if is_commit_hash(branch_or_sha):
        return Commit(branch_or_sha)
    else:
        return get_branch_head(owner, repo, branch_or_sha)


def prefetch_url(url: str) -> str:
    """
    Run nix-prefecth-url with unpack and return the sha256.
    """
    return run('nix-prefetch-url', '--unpack', '--type', 'sha256', url).rstrip('\n')


def format_fetch_nixpkgs_tarball(owner: str, repo: str, commit_hash: str) -> str:
    """
    For a given Nixpkgs commit, return a fetchTarball expression to fetch it.
    """
    url = f'https://github.com/{owner}/{repo}/archive/{commit_hash}.tar.gz'
    archive_hash = prefetch_url(url)

    nix_expr = f"""\
    import (fetchTarball {{
      url = "https://github.com/{owner}/{repo}/archive/{commit_hash}.tar.gz";
      sha256 = "{archive_hash}";
    }})
    """
    return textwrap.dedent(nix_expr)


class Diffs(NamedTuple):
    build: List[Diff]
    runtime: List[Diff]

    def __len__(self) -> int:
        return len(self.build) + len(self.runtime)


def try_update_nixpkgs(owner: str, repo: str, revision: Union[Branch, Commit]) -> Diffs:
    """
    Replace nixpkgs-pinned.nix with a newer version that fetches the latest
    commit in the given channel, and build default.nix. If that produces any
    changes, keep nixpkgs-pinned.nix, otherwise restore the previous version.
    """
    tmp_path = f'/tmp/nix-{uuid.uuid4()}'
    before_path = f'{tmp_path}-before'
    after_path = f'{tmp_path}-after'

    print('[1/3] Building before ...')
    subprocess.run(['nix', 'build', '--out-link', before_path])

    os.rename('nixpkgs-pinned.nix', 'nixpkgs-pinned.nix.bak')

    if isinstance(revision, Branch):
        print(f'[2/3] Fetching latest commit in {owner}/{repo} {revision.name} ...')
    else:
        print(f'[2/3] Fetching {owner}/{repo} {revision.head} ...')

    pinned_expr = format_fetch_nixpkgs_tarball(owner, repo, revision.head)
    with open('nixpkgs-pinned.nix', 'w', encoding='utf-8') as f:
        f.write(pinned_expr)

    print('[3/3] Building after ...')
    subprocess.run(['nix', 'build', '--out-link', after_path])

    befores_build = get_build_requisites(before_path)
    befores_runtime = get_runtime_requisites(before_path)

    afters_build = get_build_requisites(after_path)
    afters_runtime = get_runtime_requisites(after_path)

    # We only want to show dependencies once, if it already is a runtime
    # dependency, don't show it under build-time dependencies too.
    befores_build -= befores_runtime
    afters_build -= afters_runtime

    diffs_build = list(diff(sorted(befores_build), sorted(afters_build)))
    diffs_runtime = list(diff(sorted(befores_runtime), sorted(afters_runtime)))
    result = Diffs(diffs_build, diffs_runtime)

    if len(result) == 0:
        # If there were no changes in the output, then the new pinned revision
        # is not useful to this project, so restore the previously pinned
        # revision in order to not introduce unnecessary churn. The store paths
        # can still change. That might mean that e.g. the compiler changed.
        # TODO: So should the build dependencies count or not?
        os.rename('nixpkgs-pinned.nix.bak', 'nixpkgs-pinned.nix')

    return result


def summarize(diffs: Diffs) -> Optional[str]:
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
        else:
            num_other_changes += 1

    for diff in diffs.runtime:
        if isinstance(diff, Change):
            changes_runtime.append(diff)
        else:
            num_other_changes += 1

    # We list packages by shortest name first, to get as much information in the
    # subject line as possible.
    changes_build.sort(key=lambda ch: len(str(ch.after)))
    changes_build.reverse()

    changes_runtime.sort(key=lambda ch: len(str(ch.after)))
    changes_runtime.reverse()

    # Combine all changes, but prefer runtime deps over build deps when space
    # is scarce.
    changes = changes_runtime + changes_build

    if len(changes) == 0:
        return None

    def tail(n: int) -> str:
        if num_other_changes + n == 0:
            return ''
        elif num_other_changes + n == 1:
            return ', and one more change'
        else:
            return f', and {num_other_changes + n} changes'

    # Generate both long-form updates and short-form updates.
    changes_long = [f'{ch.after.name} to {ch.after.version}' for ch in changes]
    changes_short = [ch.after.name for ch in changes]

    # Generate all possible messages, in order of preference. We prefer to
    # include as much names as possible, and we prefer to have them with
    # versions over not having versions.
    messages = []
    omitted = 0
    while len(changes_long) > 0:
        messages.append('Update ' + ', '.join(changes_long) + tail(omitted))
        messages.append('Update ' + ', '.join(changes_short) + tail(omitted))
        changes_long.pop()
        changes_short.pop()
        omitted += 1

    # Then take the most preferred message that still fits in the conventional
    # Git subject line limit
    for message in messages:
        if len(message) < 52:
            return message

    # If nothing fits, we ran out.
    return None


def commit_nixpkgs_pinned(
    owner: str,
    repo: str,
    revision: Union[Branch, Commit],
    diffs: Diffs,
) -> None:
    """
    Commit nixpkgs-pinned.nix, and include the diff in the message.
    """
    run('git', 'add', 'nixpkgs-pinned.nix')

    if isinstance(revision, Branch):
        message = (
            'This updates the pinned Nixpkgs snapshot to the latest commit '
            f'in the {revision.name} branch of {owner}/{repo}.'
        )
    else:
        message = (
            f'This updates the pinned Nixpkgs snapshot to commit '
            f'{revision.head} of {owner}/{repo}.'
        )

    body_lines = [*textwrap.wrap(message, width=72)]

    if len(diffs.runtime) > 0:
        body_lines += [
            '',
            'Runtime dependencies:',
            '',
            *format_difflist(diffs.runtime),
        ]

    if len(diffs.build) > 0:
        body_lines += [
            '',
            'Build dependencies:',
            '',
            *format_difflist(diffs.build),
        ]

    if isinstance(revision, Branch):
        subject = summarize(diffs) or f'Update to latest commit in {owner}/{repo} {revision.name}'
    else:
        subject = summarize(diffs) or f'Update to pinned commit in {owner}/{repo}'

    body = '\n'.join(body_lines)
    message = f'{subject}\n\n{body}\n'
    subprocess.run(['git', 'commit', '--message', message])

    # If we commit the new file, then we no longer need the backup.
    os.remove('nixpkgs-pinned.nix.bak')

    if isinstance(revision, Branch):
        print(f'Committed upgrade to latest commit in {owner}/{repo} {revision.name}')
    else:
        print(f'Committed upgrade to {owner}/{repo} {revision.head}')


def main(owner: str, repo: str, branch_or_sha: str) -> None:
    """
    Update to the latest commit in the given branch (called channel for Nixpkgs),
    and commit that, if newer versions of a dependency are available.
    """
    revision = get_latest_revision(owner, repo, branch_or_sha)
    diffs = try_update_nixpkgs(owner, repo, revision)
    if len(diffs) > 0:
        commit_nixpkgs_pinned(owner, repo, revision, diffs)
    else:
        if isinstance(revision, Branch):
            print(f'Latest commit in {revision.name} branch has no interesting changes.')
        else:
            print(f'Commit {revision.head} has no interesting changes.')


def getarg(n: int, default: str) -> str:
    return sys.argv[n] if len(sys.argv) > n else default


if __name__ == '__main__':
    main(
        owner=getarg(1, 'nixos'),
        repo=getarg(2, 'nixpkgs'),
        branch_or_sha=getarg(3, 'nixos-unstable'),
    )
