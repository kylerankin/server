#!/usr/bin/env python3
"""Emit the key-free BuildStream elements to upload to the org CAS.

BuildStream rebuilds FSDK's kernel (``components/linux.bst``) and roughly 15
other elements from source on every ``main`` run -- 62-93 min of the ~110 min
``build`` job. Pushing a safe subset of the already-built artifacts to
``cache.projectbluefin.io:11002`` warms the cache for the next run.

Safety invariant: nothing key-derived is ever uploaded. An element is
excluded when it is the boot-key element itself, embeds files from
``files/boot-keys``, or transitively depends on such an element in build or
runtime. The allow-list below is an explicit positive list of key-free
elements; this script fails closed (non-zero exit) if any of them is
key-derived, so a misconfigured list can never upload a key.

Prints one element identifier per line for ``bst push``.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
ELEMENTS_DIR = REPO_ROOT / "elements"

# Junction declarations are external FSDK / gnome-build-meta element libraries
# whose contents are resolved at build time, not parsed here.
JUNCTION_ELEMENTS = {"freedesktop-sdk.bst", "gnome-build-meta.bst"}

# An element is key-derived (never uploaded) when its path is the boot-key
# element, or its body references files/boot-keys.
KEY_DERIVED_ELEMENT_SUFFIX = "keys/boot-keys.bst"
KEY_DERIVED_FILE = "files/boot-keys"

# Explicit allow-list of key-free elements to warm the cache. These are the
# kernel, the OpenZFS sysext, the k0s binaries, and the FSDK/bootstrap elements
# FSDK's own cache does not hold. Updated from the issue's measured subset;
# every entry is asserted key-free by tests/unit/test_bst_push_allowlist.py.
ALLOWED_ELEMENTS = [
    "flatcar/flatcar-kernel.bst",
    "flatcar/flatcar-zfs.bst",
    "k0s/k0s-bin.bst",
    "freedesktop-sdk.bst:bootstrap/go.bst",
    "freedesktop-sdk.bst:bootstrap/binutils-stage1.bst",
    "freedesktop-sdk.bst:components/elfutils.bst",
    "freedesktop-sdk.bst:components/lvm2-base.bst",
]


def _dep_name(dep):
    """Normalise a build-depends / run-depends entry to a bare element name."""
    if isinstance(dep, str):
        return dep
    if isinstance(dep, dict):
        filename = dep.get("filename")
        if isinstance(filename, str):
            return filename
    return None


def _local_name(dep_name):
    """Return the local-element name a dependency resolves to, or None.

    Strips any junction-ref prefix (``freedesktop-sdk.bst:components/x.bst``);
    junction targets are external and never key-derived from this graph.
    """
    if not isinstance(dep_name, str):
        return None
    return dep_name.split(":", 1)[0]


def load_elements():
    """Return {element_name: {"build": [...], "run": [...], "raw": str}}.

    ``element_name`` is the path relative to ``elements/`` (e.g.
    ``bluefin-server/os-stack.bst``). Junction declarations are skipped.
    """
    elements = {}
    for bst in sorted(ELEMENTS_DIR.rglob("*.bst")):
        name = bst.relative_to(ELEMENTS_DIR).as_posix()
        if bst.name in JUNCTION_ELEMENTS:
            continue
        try:
            doc = yaml.safe_load(bst.read_text(encoding="utf-8"))
        except yaml.YAMLError:
            continue
        if not isinstance(doc, dict):
            continue
        elements[name] = {
            "build": [d for d in (_dep_name(x) for x in doc.get("build-depends", [])) if d],
            "run": [d for d in (_dep_name(x) for x in doc.get("run-depends", [])) if d],
            "raw": doc,
        }
    return elements


def key_derived_paths(elements):
    """Return the set of key-derived element names (seeds + transitive dependents).

    Seeds are elements named like the boot-key element or embedding
    files/boot-keys. Dependents are elements that build- or run-depend (transitively)
    on a seed.
    """
    seeds = {
        name
        for name, info in elements.items()
        if name.endswith(KEY_DERIVED_ELEMENT_SUFFIX) or KEY_DERIVED_FILE in str(info["raw"])
    }

    key_derived = set(seeds)
    changed = True
    while changed:
        changed = False
        for name, info in elements.items():
            if name in key_derived:
                continue
            deps = {_local_name(d) for d in info["build"]} | {_local_name(d) for d in info["run"]}
            if deps & key_derived:
                key_derived.add(name)
                changed = True
    return key_derived


def main(argv):
    allowed = argv[1:] or ALLOWED_ELEMENTS

    elements = load_elements()
    key_derived = key_derived_paths(elements)

    violations = [elem for elem in allowed if _local_name(elem) in key_derived]
    if violations:
        for elem in violations:
            print(f"refusing to upload key-derived element: {elem}", file=sys.stderr)
        sys.exit(1)

    print("\n".join(allowed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
