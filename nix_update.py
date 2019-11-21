#!/bin/env python3

from __future__ import annotations

"""
Inspect the differences between the closures of two Nix store paths.
"""
 
import subprocess
import sys

from typing import Any, Dict, Iterable, List, NamedTuple, Optional

from nix_store import get_closure, run
from nix_diff import diff, print_difflist


def print_diff_store_paths(before_path: str, after_path: str) -> None:
    """
    Print the diff between two store paths, assuming they exist.
    """
    befores = get_closure(before_path)
    afters = get_closure(after_path)
    diffs = list(diff(befores, afters))
    print_difflist(diffs)


def print_diff_commits(before_ref: str, after_ref: str) -> None:
    """
    Print the diff between default.nix in two commits.
    """
    before_path = f'/tmp/{abs(hash(before_ref))}'
    after_path = f'/tmp/{abs(hash(after_ref))}'
    run('git', 'checkout', before_ref, '--') 
    subprocess.run(['nix', 'build', '--out-link', before_path])
    run('git', 'checkout', after_ref, '--') 
    subprocess.run(['nix', 'build', '--out-link', after_path])
    print_diff_store_paths(before_path, after_path)


if __name__ == '__main__':
    print_diff_commits(sys.argv[1], sys.argv[2])
