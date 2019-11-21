#!/bin/env python3

from __future__ import annotations

"""
Inspect the differences between the closures of two Nix store paths.
"""
 
import subprocess
import sys
import json


def get_store_paths(nix_file_path: str) -> List[str]:
    """
    Return the store paths that the given file builds.
    """
    cmd = ['nix', 'path-info', '--file', nix_file_path]
    result = subprocess.run(cmd, capture_output=True)
    assert result.returncode == 0
    return result.stdout.decode('utf-8').splitlines()


def get_requisites(path: str) -> List[str]:
    """
    Return the closure of runtime dependencies of the store path.
    """
    cmd = ['nix-store', '--query', '--requisites', path]
    result = subprocess.run(cmd, capture_output=True)
    assert result.returncode == 0
    return result.stdout.decode('utf-8').splitlines()


def get_deriver(path: str) -> None:
    """
    If the derivation that produced the given store path exists in the store,
    parse and return it.
    """
    cmd = ['nix-store', '--query', '--deriver', path]
    result = subprocess.run(cmd, capture_output=True)

    if result.returncode != 0:
        return None

    drv_path = result.stdout.decode('utf-8').rstrip('\n')
    cmd = ['nix', 'show-derivation', drv_path]
    result = subprocess.run(cmd, capture_output=True)

    if  result.returncode != 0:
        print("no store path for", path, drv_path)
        return None

    return json.loads(result.stdout.decode('utf-8'))


if __name__ == '__main__':
    for path in get_store_paths('default.nix'):
        reqs = get_requisites(path)
        for req in reqs:
            print(get_deriver(req))
