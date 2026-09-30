"""Safety invariants for the key-free BuildStream artifact allow-list.

The upload step pushes ``bst push`` elements to the org CAS. These tests
enforce that nothing key-derived is ever uploaded: the boot-key element, any
element embedding files/boot-keys, and anything transitively depending on them
are excluded, while the named key-free elements are included.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / ".github" / "scripts"))

spec = importlib.util.spec_from_file_location(
    "bst_push_elements", REPO_ROOT / ".github" / "scripts" / "bst-push-elements.py"
)
bst_push = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bst_push)


def _element(name, build=None, run=None, raw_extra=""):
    """Build a load_elements()-shaped record for a synthetic graph."""
    return {
        "build": build or [],
        "run": run or [],
        "raw": {"_raw": raw_extra},
    }


def synthetic_graph():
    """A graph with a boot-key seed, a files/boot-keys seed, and dependents."""
    return {
        "keys/boot-keys.bst": _element("keys/boot-keys.bst"),
        # embeds files/boot-keys directly
        "bluefin-server/boot-init.bst": _element(
            "bluefin-server/boot-init.bst", raw_extra="sources:\n  - path: files/boot-keys\n"
        ),
        # build-depends on the boot-key element
        "bluefin-server/sealed-boot.bst": _element(
            "bluefin-server/sealed-boot.bst", build=["keys/boot-keys.bst"]
        ),
        # run-depends on the files/boot-keys user (transitive)
        "bluefin-server/secure-setup.bst": _element(
            "bluefin-server/secure-setup.bst", run=["bluefin-server/boot-init.bst"]
        ),
        # unrelated, key-free element
        "flatcar/flatcar-kernel.bst": _element("flatcar/flatcar-kernel.bst"),
    }


def test_key_seed_and_dependents_are_key_derived():
    elements = synthetic_graph()
    derived = bst_push.key_derived_paths(elements)
    assert "keys/boot-keys.bst" in derived
    assert "bluefin-server/boot-init.bst" in derived  # embeds files/boot-keys
    assert "bluefin-server/sealed-boot.bst" in derived  # build-depends on seed
    assert "bluefin-server/secure-setup.bst" in derived  # transitive run-dep


def test_key_free_element_is_not_key_derived():
    elements = synthetic_graph()
    derived = bst_push.key_derived_paths(elements)
    assert "flatcar/flatcar-kernel.bst" not in derived


def test_named_elements_are_in_the_allow_list():
    for elem in (
        "flatcar/flatcar-kernel.bst",
        "flatcar/flatcar-zfs.bst",
        "k0s/k0s-bin.bst",
    ):
        assert elem in bst_push.ALLOWED_ELEMENTS


def test_no_allowed_element_is_key_derived_on_the_real_graph():
    elements = bst_push.load_elements()
    derived = bst_push.key_derived_paths(elements)
    for elem in bst_push.ALLOWED_ELEMENTS:
        assert bst_push._local_name(elem) not in derived, (
            f"{elem} is key-derived and must not be uploaded"
        )


def test_no_local_element_depends_on_boot_keys_today():
    """If any local element were key-derived it would be a red flag."""
    elements = bst_push.load_elements()
    derived = bst_push.key_derived_paths(elements)
    # sysupdate-keys (public GPG ring) is NOT boot-keys; ensure the marker is
    # specific enough that it is not swept in.
    assert not any("sysupdate-keys" in name for name in derived)
    # Nothing currently derives from boot keys (the element does not exist yet).
    assert derived == set()


def test_main_emits_allowed_elements():
    assert bst_push.main(["prog", "flatcar/flatcar-kernel.bst"]) == 0
