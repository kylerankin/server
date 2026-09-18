"""Contract tests for the boot-proof entry points (issue #130).

The Flatcar-base DDI boot proof is four gates that must all pass against
``os-base: flatcar``: ``just show-me-the-future``, ``just test-e2e-lima``,
``just test-e2e-browser``, and k0s sysext first-boot node-Ready.

The Lima and browser gates are pinned by
``tests/unit/test_lima_e2e_contract.py``; this file pins the two that gate the
whole proof -- ``show-me-the-future`` (the entry point that builds, exports,
then runs the install-and-boot smoke test) and ``test-installer-artifact``
(the smoke test that boots the installed OS and proves the Console is healthy).

These recipes run QEMU in the factory lab; the tests here pin the contract so
the proof cannot silently drift, and they run in ``just test-unit`` where no
hypervisor is required.
"""

from pathlib import Path

JUSTFILE = Path(__file__).resolve().parents[2] / "Justfile"


def _recipe(justfile: str, header: str) -> str:
    """Return the recipe body for ``header`` (e.g. ``test-installer-artifact:``)."""
    start = justfile.index(header)
    rest = justfile[start + len(header) :]
    end = len(rest)
    for match in _top_level_headers(rest):
        end = min(end, match)
    return rest[:end]


def _top_level_headers(text: str) -> list[int]:
    import re

    return [m.start() for m in re.finditer(r"(?m)^[A-Za-z_][\w-]*:\s*$", text)]


def test_show_me_the_future_defers_to_installer_artifact_smoke() -> None:
    """show-me-the-future builds, exports, then runs the reusable smoke path."""
    recipe = _recipe(JUSTFILE.read_text(encoding="utf-8"), "show-me-the-future:")

    assert recipe.strip().startswith("just build-installer")
    assert "just export-installer" in recipe
    assert "just test-installer-artifact" in recipe


def test_test_installer_artifact_proves_console_smoke() -> None:
    """The smoke test boots the installed OS and proves the Console is healthy."""
    recipe = _recipe(JUSTFILE.read_text(encoding="utf-8"), "test-installer-artifact:")

    assert recipe.strip().startswith("#!/usr/bin/env bash")
    assert "set -euo pipefail" in recipe
    # Boots installer media, then the installed server, forwarding the console.
    assert "Booting installer media in QEMU" in recipe
    assert "Booting the installed server in QEMU" in recipe
    assert "8080-:8080" in recipe
    # The proof asserts the Console: /healthz status ok and / returns HTTP 200.
    assert '.status == "ok"' in recipe
    assert "returned HTTP 200" in recipe
