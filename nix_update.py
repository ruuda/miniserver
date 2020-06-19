#!/bin/env python3

from __future__ import annotations

"""
Update the pinned Nixpkgs snapshot to the latest available Nixpkgs commit, and
if the new snapshot contains interesting changes, commit the update, including
the changes in the commit message.

Usage:

  nix_update.py [<owner> [<repo> [<branch>]]]

Defaults to the NixOS/nixpkgs-channels repository and the nixos-unstable branch.
"""
 
import json
import os
import subprocess
import sys
import textwrap
import urllib.request
import uuid

from typing import Any, Dict, Iterable, List, NamedTuple, Optional

from nix_store import get_closure, run
from nix_diff import Addition, Change, Diff, Removal, diff, format_difflist


def get_latest_revision(owner: str, repo: str, branch: str) -> str:
    """
    Return the current HEAD commit hash of the given branch.
    This queries the GitHub API.
    """
    url = f'https://api.github.com/repos/{owner}/{repo}/git/refs/heads/{branch}'
    response = urllib.request.urlopen(url)
    body = json.load(response)
    return body['object']['sha']


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


def try_update_nixpkgs(owner: str, repo: str, branch: str) -> List[Diff]:
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

    print('[2/3] Fetching latest Nixpkgs ...')
    commit_hash = get_latest_revision(owner, repo, branch)
    pinned_expr = format_fetch_nixpkgs_tarball(owner, repo, commit_hash)
    with open('nixpkgs-pinned.nix', 'w', encoding='utf-8') as f:
        f.write(pinned_expr)

    print('[3/3] Building after ...')
    subprocess.run(['nix', 'build', '--out-link', after_path])

    befores = get_closure(before_path)
    afters = get_closure(after_path)
    diffs = list(diff(befores, afters))

    if len(diffs) == 0:
        # If there were no changes in the output, then the new pinned revision
        # is not useful to this project, so restore the previously pinned
        # revision in order to not introduce unnecessary churn. The store paths
        # can still change. That might mean that e.g. the compiler changed.
        os.rename('nixpkgs-pinned.nix.bak', 'nixpkgs-pinned.nix')

    return diffs


def summarize(diffs: List[Diff]) -> Optional[str]:
    """
    Return a short subject line that summarizes the diff. Returns none if we
    can't find a good summary.
    """
    changes: List[Change] = []
    num_other_changes = 0

    for diff in diffs:
        if isinstance(diff, Change):
            changes.append(diff)
        else:
            num_other_changes += 1

    # We list packages by shortest name first, to get as much information in the
    # subject line as possible.
    changes.sort(key=lambda ch: len(str(ch.after)))
    changes.reverse()

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


def commit_nixpkgs_pinned(owner: str, repo: str, branch: str, diffs: List[Diff]) -> None:
    """
    Commit nixpkgs-pinned.nix, and include the diff in the message.
    """
    run('git', 'add', 'nixpkgs-pinned.nix')

    body_lines = [
        *textwrap.wrap(
            'This updates the pinned Nixpkgs snapshot to the latest commit '
            f'in the {branch} branch of {owner}/{repo}.',
            width=72,
        ),
        '',
        *format_difflist(diffs),
    ]

    subject = summarize(diffs) or f'Update to latest commit in {owner}/{repo} {branch}'
    body = '\n'.join(body_lines)
    message = f'{subject}\n\n{body}\n'
    subprocess.run(['git', 'commit', '--message', message])

    # If we commit the new file, then we no longer need the backup.
    os.remove('nixpkgs-pinned.nix.bak')
    print(f'Committed upgrade to latest commit in {owner}/{repo} {branch}')


def print_diff_store_paths(before_path: str, after_path: str) -> None:
    """
    Print the diff between two store paths, assuming they exist.
    """
    befores = get_closure(before_path)
    afters = get_closure(after_path)
    diffs = list(diff(befores, afters))
    for line in format_difflist(diffs):
        print(line)


def print_diff_commits(before_ref: str, after_ref: str) -> None:
    """
    Print the diff between default.nix in two commits.
    Beware, this does run "git checkout".
    """
    before_path = f'/tmp/{abs(hash(before_ref))}'
    after_path = f'/tmp/{abs(hash(after_ref))}'

    run('git', 'checkout', before_ref, '--') 
    print('[1/2] Building before ...', end='', flush=True)
    subprocess.run(['nix', 'build', '--out-link', before_path])

    run('git', 'checkout', after_ref, '--') 
    print('[2/2] Building after ...', end='', flush=True)
    subprocess.run(['nix', 'build', '--out-link', after_path])

    print_diff_store_paths(before_path, after_path)


def main(owner: str, repo: str, branch: str) -> None:
    """
    Update to the latest commit in the given branch (called channel for Nixpkgs),
    and commit that, if newer versions of a dependency are available.
    """
    diffs = try_update_nixpkgs(owner, repo, branch)
    if len(diffs) > 0:
        commit_nixpkgs_pinned(owner, repo, branch, diffs)
    else:
        print(f'Latest commit in {branch} channel has no interesting changes.')


def getarg(n: int, default: str) -> str:
    return sys.argv[n] if len(sys.argv) > n else default


if __name__ == '__main__':
    main(
        owner=getarg(1, 'NixOS'),
        repo=getarg(2, 'nixpkgs-channels'),
        branch=getarg(3, 'nixos-unstable'),
    )
