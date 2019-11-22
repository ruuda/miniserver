#!/bin/env python3

from __future__ import annotations

"""
Inspect the differences between the closures of two Nix store paths.
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
from nix_diff import Diff, diff, format_difflist


def get_latest_revision(channel: str) -> str:
    """
    Return the current HEAD commit hash of the given Nixpkgs channel.
    This queries the GitHub API.
    """
    url = 'https://api.github.com/repos/NixOS/nixpkgs-channels/git/refs/heads/'
    response = urllib.request.urlopen(url + channel)
    body = json.load(response)
    return body['object']['sha']


def prefetch_url(url: str) -> str:
    """
    Run nix-prefecth-url with unpack and return the sha256.
    """
    return run('nix-prefetch-url', '--unpack', '--type', 'sha256', url).rstrip('\n')


def format_fetch_nixpkgs_tarball(commit_hash: str) -> str:
    """
    For a given Nixpkgs commit, return a fetchTarball expression to fetch it.
    """
    url = f'https://github.com/NixOS/nixpkgs/archive/{commit_hash}.tar.gz'
    archive_hash = prefetch_url(url)

    nix_expr = f"""\
    fetchTarball {{
      url = "https://github.com/NixOS/nixpkgs/archive/{commit_hash}.tar.gz";
      sha256 = "{archive_hash}";
    }}
    """
    return textwrap.dedent(nix_expr)


def try_update_nixpkgs(channel: str) -> List[Diff]:
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
    commit_hash = get_latest_revision(channel)
    pinned_expr = format_fetch_nixpkgs_tarball(commit_hash)
    with open('nixpkgs-pinned.nix', 'w', encoding='utf-8') as f:
        f.write(pinned_expr)

    print('[2/3] Building after ...')
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


def commit_nixpkgs_pinned(channel: str, diffs: List[diff]) -> None:
    """
    Commit nixpkgs-pinned.nix, and include the diff in the message.
    """
    run('git', 'add', 'nixpkgs-pinned.nix')
    subject = f'Upgrade to latest commit in {channel} channel'
    body = '\n'.join(format_difflist(diffs))
    message = f'{subject}\n\n{body}\n'
    subprocess.run(['git', 'commit', '--message', message])


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


def main(channel: str = 'nixos-unstable') -> None:
    """
    Update to the latest commit in the given Nixpkgs channel, and commit that,
    if newer versions of a dependency are available.
    """
    diffs = try_update_nixpkgs(channel)
    if len(diffs) > 0:
        commit_nixpkgs_pinned(channel, diffs)


if __name__ == '__main__':
    main(channel='nixos-unstable')
