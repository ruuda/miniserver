#!/bin/env python3

from __future__ import annotations

"""
Extract package names and version of the closure of a Nix store path.
"""
 
import subprocess
import sys
import json

from typing import Any, Dict, Iterable, List, NamedTuple, Optional


class Package(NamedTuple):
    """
    Package name and version, inferred through a heuristic from a store path.
    """
    name: str
    version: str

    def __str__(self) -> str:
        return self.name + (f'-{self.version}' if self.version != '' else '')

    @staticmethod
    def parse(path: str) -> Package:
        parts = path.split('-')

        name: List[str] = []
        version: List[str] = []

        while len(parts) > 0:
            part = parts[0]
            if part[0].isdigit():
                # We assume that a part that starts with a digit is the version
                # part. So far this works well enough.
                version = parts
                break
            else:
                name.append(part)
                parts = parts[1:]

        # Some store path have a suffix because the derivation has multiple
        # outputs. Merge these into a single entry.
        for exclude in ('bin', 'data', 'dev', 'doc', 'env', 'lib', 'man'):
            if exclude in version:
                version.remove(exclude)

        return Package('-'.join(name), '-'.join(version))


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


def get_requisites(path: str) -> List[str]:
    """
    Return the closure of runtime dependencies of the store path.
    """
    return run('nix-store', '--query', '--requisites', path).splitlines()


def get_closure(path: str) -> Iterable[Package]:
    """
    Return the runtime dependencies of the store path as parsed packages.
    """
    results = set()
    for dep_path in get_requisites(path):
        # Nix store paths are of the form "/nix/store/{sha}-{name_version}".
        store_path, name_version = dep_path.strip().split('-', maxsplit=1)
        results.add(Package.parse(name_version))

    return sorted(results)
