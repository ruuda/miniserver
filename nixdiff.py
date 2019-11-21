#!/bin/env python3

from __future__ import annotations

"""
Inspect the differences between the closures of two Nix store paths.
"""
 
import subprocess
import sys
import json

from typing import Any, Dict, List, Optional


def run(*cmd: str) -> str:
    """
    Run a command, return its stdout interpreted as UTF-8.
    """
    result = subprocess.run(cmd, capture_output=True)

    if result.returncode != 0:
        sys.stdout.buffer.write(result.stdout)
        sys.stdout.buffer.write(result.stderr)
        sys.stdout.buffer.flush()
        sys.exit(1)

    return result.stdout.decode('utf-8')


def get_store_paths(nix_file_path: str) -> List[str]:
    """
    Return the store paths that the given file builds.
    """
    return run('nix', 'path-info', '--file', nix_file_path).splitlines()


def get_requisites(path: str) -> List[str]:
    """
    Return the closure of runtime dependencies of the store path.
    """
    return run('nix-store', '--query', '--requisites', path).splitlines()


def get_deriver(path: str) -> Optional[Dict[str, Any]]:
    """
    If the derivation that produced the given store path exists in the store,
    parse and return it.
    """
    drv_path = run('nix-store', '--query', '--deriver', path).rstrip('\n')
    derivation = run('nix', 'show-derivation', drv_path)
    return json.loads(derivation)[drv_path]


if __name__ == '__main__':
    for path in get_store_paths('default.nix'):
        reqs = get_requisites(path)
        for req in reqs:
            derivation = get_deriver(req)
            print(derivation['env']['name'], derivation['env'].get('version', '???'))
