#!/bin/env python3

from __future__ import annotations

"""
Diff and pretty-print two lists of packages. 
"""

import sys

from typing import Iterable, Iterator, List, NamedTuple, Optional, TypeVar, Union

from nix_store import Package

T = TypeVar("T")


class Addition(NamedTuple):
    package: Package


class Removal(NamedTuple):
    package: Package


class Change(NamedTuple):
    before: Package
    after: Package


Diff = Union[Addition, Removal, Change]


def next_opt(iterator: Iterator[T]) -> Optional[T]:
    try:
        return next(iterator)
    except StopIteration:
        return None


def diff(befores: Iterable[Package], afters: Iterable[Package]) -> Iterator[Diff]:
    """
    Perform a merge-diff of two sorted streams of packages.
    """
    it_befores = iter(befores)
    it_afters = iter(afters)

    left = next_opt(it_befores)
    right = next_opt(it_afters)

    while True:
        if left is None and right is None:
            break

        if left is not None and (right is None or left.name < right.name):
            yield Removal(left)
            left = next_opt(it_befores)
            continue

        if right is not None and (left is None or left.name > right.name):
            yield Addition(right)
            right = next_opt(it_afters)
            continue

        assert left is not None and right is not None, "Inputs must be sorted."

        if left.name == right.name:
            if left.version != right.version:
                yield Change(left, right)

            left = next_opt(it_befores)
            right = next_opt(it_afters)
            continue


def format_difflist(diffs: List[Diff]) -> Iterator[str]:
    """
    Pretty-print a list of differences.
    """
    names = set()
    versions_before = set()
    versions_after = set()

    for diff in diffs:
        if isinstance(diff, Addition):
            names.add(diff.package.name_with_group())
            versions_after.add(diff.package.version)
        if isinstance(diff, Removal):
            names.add(diff.package.name_with_group())
            versions_before.add(diff.package.version)
        if isinstance(diff, Change):
            names.add(diff.before.name_with_group())
            versions_before.add(diff.before.version)
            versions_after.add(diff.after.version)

    if len(names) == 0:
        # Print to stderr so redirect works for normal output.
        sys.stderr.write("No differences found.\n")
        return

    name_len = max(len(name) for name in names)
    before_len = max(len(version) for version in ["0", *versions_before])
    after_len = max(len(version) for version in ["0", *versions_after])

    for diff in diffs:
        op = " "
        arrow = "  "
        name = ""
        v_before = ""
        v_after = ""

        if isinstance(diff, Addition):
            op = "+"
            name = diff.package.name_with_group()
            v_after = diff.package.version
        if isinstance(diff, Removal):
            op = "-"
            name = diff.package.name_with_group()
            v_before = diff.package.version
        if isinstance(diff, Change):
            arrow = "->"
            name = diff.before.name_with_group()
            v_before = diff.before.version
            v_after = diff.after.version

        name = name.ljust(name_len)
        v_before = v_before.ljust(before_len)
        v_after = v_after.ljust(after_len)
        yield f"{op} {name} {v_before} {arrow} {v_after}"
