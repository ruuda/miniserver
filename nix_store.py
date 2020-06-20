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
        """
        Parse a package name and version using heuristics, from a name-version.
        """
        parts = [part for part in path.split('-') if part != '']

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

    @staticmethod
    def parse_derivation(derivation: Dict[str, Any]) -> Optional[Package]:
        """
        Try to extract structured name and version from a derivation returned by
        nix show-derivation, if the derivation is a package.
        """
        if derivation['platform'] == 'builtin':
            # If the derivation is produced by a builtin, it is not a package.
            return None

        if derivation['outputs'].get('out', {}).get('hash') is not None:
            # If the derivation is a fixed-output derivation, then we assume
            # it's not a package (but instead likely something we fetch from the
            # network.)
            return None

        if len(derivation['inputDrvs']) <= 2:
            # Some things are helper utils, not packages. We assume a package
            # has at least three inputs: Bash, stdenv, and its fetched source.
            # These helpers often have only two, no source.
            return None

        env = derivation['env']
        pname = env.get('pname')
        name = env.get('name')
        version = env.get('version')

        if name is None:
            # Packages have names.
            return None

        if name.split('-')[-1] == 'hook' or name.split('-')[-1] == 'hook.sh':
            # Hooks are not packages.
            return None

        if name.endswith('stdenv-linux'):
            # The stdenv is special, we don't count it as a package.
            return None

        if pname is not None and version is not None:
            # Best case we have the full metadata split out.
            return Package(pname, version)

        if version is not None:
            # Sometimes we have only the name (including version) to go by, but
            # at least the version is known.
            if name.endswith('-' + version):
                return Package(name[:-len(version) - 1], version)

        # In some cases, we only have the name to go by, and we hope it
        # includes the version too. This can lead to false positives: some
        # derivations such as patch files or source archives are not
        # packages at all, but so far I have not found a reliable way to
        # tell them apart. For now, the heuristic is whether we managed to
        # parse the name in a sensible way.
        package = Package.parse(name)
        if package.name != '' and package.version != '':
            return package

        return None


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


def get_packages_from_derivations(drv_paths: List[str]) -> Iterable[Package]:
    """
    Extract package names and versions from each of the derivation files.
    """
    # "nix show-derivation" produces a map from store path to derivation.
    path_to_drv = json.loads(run('nix', 'show-derivation', *drv_paths))
    for drv_path, derivation in path_to_drv.items():
        package = Package.parse_derivation(derivation)
        if package is not None:
            yield package


def get_requisites(path: str) -> Set[Package]:
    """
    Return the closure of runtime dependencies of the store path.
    """
    runtime_deps = run('nix-store', '--query', '--requisites', path).splitlines()
    derivations = run('nix-store', '--query', '--deriver', *runtime_deps).splitlines()
    return set(get_packages_from_derivations(derivations))


def get_build_requisites(path: str) -> Set[Package]:
    """
    Return the closure of build time dependencies of the store path.
    """
    derivation = run('nix-store', '--query', '--deriver', path).strip()
    deps_closure = run('nix-store', '--query', '--requisites', derivation)
    deps_derivations = [p for p in deps_closure.splitlines() if p.endswith('.drv')]
    return set(get_packages_from_derivations(deps_derivations))
