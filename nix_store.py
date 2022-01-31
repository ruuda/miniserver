#!/bin/env python3

from __future__ import annotations

"""
Extract package names and version of the closure of a Nix store path.
"""
 
import json
import os.path
import subprocess
import sys

from typing import Any, Dict, Iterable, List, NamedTuple, Optional, Set


# Nix 2.4 has breaking changes in its CLI interface, use Nix 2.3 instead.
NIX_BIN = '/nix/store/9hkh1fx8z1frgbz2nawr0mnyvizrb8yk-nix-2.3.15/bin'


def ensure_pinned_nix_version():
    if not os.path.isfile(f'{NIX_BIN}/nix'):
        print('Getting Nix 2.3.15 ...')
        run('nix-store', '--realise', os.path.dirname(NIX_BIN))
    else:
        print('Already have Nix 2.3.15.')


class Package(NamedTuple):
    """
    Package name and version, inferred through a heuristic from a store path.
    """
    name: str
    version: str
    group: Optional[str] = None

    def __str__(self) -> str:
        return self.name + (f'-{self.version}' if self.version != '' else '')

    def __lt__(self, other):
        # Overload the comparison operator, to give packages where group=None
        # an ordering with respect to pacakges that do have a group. Without
        # this, sorting a list of packages can fail with a TypeError.
        lhs = (self.name, self.version, self.group or '')
        rhs = (other.name, other.version, other.group or '')
        return lhs < rhs

    def name_with_group(self) -> str:
        """
        If the package is part of a group, return the name prefixed by the group
        name. E.g. return "perl5.31.0-CGI" when the name is "CGI" and the group
        is "perl5.31.0".
        """
        if self.group is not None:
            return f'{self.group}-{self.name}'
        else:
            return self.name

    def _extract_group(self) -> Package:
        """
        If the package is part of a group, e.g "perl5.32.0-CGI", then we should
        not treat the group as part of the name. This is to avoid triggering
        huge diffs if Perl is bumped, but the Perl package versions don’t change.
        """
        assert self.group == None, 'Can only extract group once.'

        parts = self.name.split('-', maxsplit=1)

        if len(parts) == 1:
            return self

        # Use heuristics; for now we only detect this grouping situation for
        # Perl. I believe it also applies to Python, but I can add it when that
        # happens.
        if parts[0].startswith('perl5'):
            return Package(name=parts[1], version=self.version, group=parts[0])
        if parts[0].startswith('ruby2.'):
            return Package(name=parts[1], version=self.version, group=parts[0])

        return self

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
        excludes = (
            'bin',
            'data',
            'dev',
            'doc',
            'env',
            'lib',
            'man',
            'sdist.tar.gz',
        )
        for exclude in excludes:
            if exclude in version:
                version.remove(exclude)

        return Package('-'.join(name), '-'.join(version))._extract_group()

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
            return Package(pname, version)._extract_group()

        if version is not None:
            # Sometimes we have only the name (including version) to go by, but
            # at least the version is known.
            if name.endswith('-' + version):
                return Package(name[:-len(version) - 1], version)._extract_group()

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
    existing_paths = []
    missing_paths = []
    for path in drv_paths:
        if os.path.isfile(path):
            existing_paths.append(path)
        else:
            missing_paths.append(path)

    # "nix show-derivation" produces a map from store path to derivation.
    path_to_drv = json.loads(run(
        f'{NIX_BIN}/nix', 'show-derivation', *existing_paths,
    ))
    for drv_path, derivation in path_to_drv.items():
        package = Package.parse_derivation(derivation)
        if package is not None:
            yield package

    # For the .drv files that we don't have locally, there is no way to obtain
    # them as far as I am aware. See also
    # https://discourse.nixos.org/t/how-to-get-a-missing-drv-file-for-a-derivation-from-nixpkgs/2300
    # So instead, we get the details heuristically from the store path.
    for drv_path in missing_paths:
        _store_prefix, name = drv_path.split('-', maxsplit=1)
        name = name[:-4]  # Cut off the .drv suffix.
        package = Package.parse(name)
        if package.name != '' and package.version != '':
            yield package


def get_runtime_requisites(path: str) -> Set[Package]:
    """
    Return the closure of runtime dependencies of the store path.
    """
    runtime_deps = run(f'{NIX_BIN}/nix-store', '--query', '--requisites', path).splitlines()
    derivations = run(f'{NIX_BIN}/nix-store', '--query', '--deriver', *runtime_deps).splitlines()
    return set(get_packages_from_derivations(derivations))


def get_build_requisites(path: str) -> Set[Package]:
    """
    Return the closure of build time dependencies of the store path.
    """
    derivation = run(f'{NIX_BIN}/nix-store', '--query', '--deriver', path).strip()
    deps_closure = run(f'{NIX_BIN}/nix-store', '--query', '--requisites', derivation)
    deps_derivations = [p for p in deps_closure.splitlines() if p.endswith('.drv')]
    return set(get_packages_from_derivations(deps_derivations))
