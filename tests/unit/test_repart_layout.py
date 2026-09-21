"""Invariant coverage for the target-disk partition layout.

``files/installer/repart.d/*.conf`` is the recipe ``systemd-repart`` follows
when the live installer partitions the *target* disk. These are pure static
checks: they read the shipped configs (plus the installer element and the
sysupdate transfer for cross-file consistency) and assert the invariants the
installer depends on. No BuildStream, no root, no block devices.

Layout (issue #134, Flatcar EFI-SYSTEM/USR-A/USR-B/OEM/ROOT):

  10-esp.conf   EFI-SYSTEM   ESP (vfat)
  20-usr-a.conf USR-A        read-only /usr slot A (Flatcar root-fs GUID)
  30-usr-b.conf USR-B        spare read-only /usr slot B
  40-oem.conf   OEM          ext4, cloud metadata / Ignition (label OEM)
  50-root.conf  ROOT         writable root, grows to fill disk, seeds k0s
"""

from __future__ import annotations

import configparser
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
REPART_DIR = REPO_ROOT / "files" / "installer" / "repart.d"
ELEMENTS_DIR = REPO_ROOT / "elements"
ROOT_TRANSFER = REPO_ROOT / "files" / "os" / "sysupdate.d" / "50-root.transfer"

# Flatcar GPT type GUIDs (issue #134).
GUID_USR = "5dfbf5f4-2848-4bac-aa5e-0d9a20b745a6"
GUID_OEM = "0fc63daf-8483-4772-8e79-3d69d8477de4"
GUID_ROOT = "3884dd41-8582-4404-b9a8-e9b84f2df50e"

SIZE_SUFFIXES = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}


def parse_size(value: str) -> int:
    match = re.fullmatch(r"(\d+)([KMGT]?)", value.strip())
    assert match, f"unparseable systemd size: {value!r}"
    number, suffix = match.groups()
    return int(number) * SIZE_SUFFIXES.get(suffix, 1)


def load_config(path: Path):
    parser = configparser.ConfigParser(strict=True)
    parser.optionxform = str
    parser.read_string(path.read_text(encoding="utf-8"))
    return parser


def sysupdate_root_targets() -> list[str]:
    parser = configparser.ConfigParser(strict=True)
    parser.optionxform = str
    parser.read_string(ROOT_TRANSFER.read_text(encoding="utf-8"))
    assert parser.has_option("Target", "MatchPattern"), (
        f"{ROOT_TRANSFER.name} declares no [Target] MatchPattern"
    )
    return parser["Target"]["MatchPattern"].split()


def repart_files() -> list[Path]:
    return sorted(REPART_DIR.glob("*.conf"))


CONFIG_PATHS = repart_files()


def partitions() -> dict[str, dict[str, str]]:
    result = {}
    for path in CONFIG_PATHS:
        parser = load_config(path)
        result[path.name] = dict(parser["Partition"])
    return result


def section_by_label(label: str) -> dict[str, str]:
    for section in partitions().values():
        if section.get("Label") == label:
            return section
    raise AssertionError(f"no partition with Label={label!r} in {list(partitions())}")


def test_repart_directory_is_populated():
    assert CONFIG_PATHS, f"no repart.d configs found under {REPART_DIR}"


@pytest.mark.parametrize("path", CONFIG_PATHS, ids=lambda p: p.name)
def test_config_parses_with_a_partition_section(path: Path):
    parser = load_config(path)
    assert parser.sections() == ["Partition"], (
        f"{path.name} must define exactly one [Partition] section, got {parser.sections()}"
    )


@pytest.mark.parametrize("path", CONFIG_PATHS, ids=lambda p: p.name)
def test_config_filename_is_ordered_and_lowercase(path: Path):
    assert re.fullmatch(r"\d{2}-[a-z0-9-]+\.conf", path.name), (
        f"{path.name} must be NN-name.conf so systemd-repart orders it predictably"
    )


def test_config_ordering_prefixes_are_unique():
    prefixes = [p.name[:2] for p in CONFIG_PATHS]
    assert len(prefixes) == len(set(prefixes)), (
        "two repart.d configs share an ordering prefix, so partition order "
        f"depends on the filename tiebreak: {prefixes}"
    )


def test_expected_slots_are_present_exactly_once():
    labels = [section["Label"] for section in partitions().values()]
    for label in ("EFI-SYSTEM", "USR-A", "USR-B", "OEM", "ROOT"):
        assert labels.count(label) == 1, f"expected exactly one {label}, got {labels.count(label)}"


def test_esp_is_efi_system_and_vfat():
    esp = section_by_label("EFI-SYSTEM")
    assert esp["Type"] == "esp", "the EFI-SYSTEM slot must be the ESP"
    assert esp["Format"] == "vfat", "an ESP that is not vfat is unbootable by UEFI"
    assert parse_size(esp["SizeMinBytes"]) >= 100 * 1024**2, (
        "the ESP must be large enough for systemd-boot plus at least one UKI"
    )
    assert "SizeMaxBytes" in esp, "the ESP must be capped so it cannot eat the disk"


def test_usr_slots_are_flatcar_root_fs_and_sized_to_match():
    usr_a = section_by_label("USR-A")
    usr_b = section_by_label("USR-B")
    for section in (usr_a, usr_b):
        assert section["Type"] == GUID_USR, (
            f"USR slots must use the Flatcar root-fs type GUID {GUID_USR}"
        )
    assert parse_size(usr_b["SizeMinBytes"]) >= parse_size(usr_a["SizeMinBytes"]), (
        "USR-B must be at least as large as USR-A so a full /usr image fits the spare"
    )


def test_usr_a_copies_blocks_from_a_label_the_installer_media_stamps():
    usr_a = section_by_label("USR-A")
    copy_blocks = usr_a.get("CopyBlocks")
    assert copy_blocks, (
        "the USR-A partition must CopyBlocks= the /usr DDI payload; without it "
        "the installed system has an empty /usr"
    )
    prefix = "/dev/disk/by-partlabel/"
    assert copy_blocks.startswith(prefix), (
        f"CopyBlocks={copy_blocks} should address the installer media by "
        "partition label, not by an unstable device node"
    )
    partlabel = copy_blocks[len(prefix):]
    stamped = any(
        re.search(rf"^\s*Label={re.escape(partlabel)}\s*$", text, re.MULTILINE)
        for text in (path.read_text(encoding="utf-8") for path in ELEMENTS_DIR.rglob("*.bst"))
    )
    assert stamped, (
        f"no element stamps Label={partlabel} on the installer media data "
        "partition, so CopyBlocks= would resolve to nothing at install time"
    )


def test_oem_is_ext4_with_a_filesystem_label():
    oem = section_by_label("OEM")
    assert oem["Type"] == GUID_OEM, f"OEM must use the Flatcar OEM type GUID {GUID_OEM}"
    assert oem.get("Format") == "ext4", "the OEM slot must be ext4"
    # The boot path matches on the *filesystem* label, so FSLabel=OEM must be set.
    assert oem.get("FSLabel") == "OEM", (
        "the OEM slot must set FSLabel=OEM; the boot path matches the filesystem "
        "label, not the GPT partition label"
    )


def test_root_is_writable_and_grows():
    root = section_by_label("ROOT")
    assert root["Type"] == GUID_ROOT, f"ROOT must use the Flatcar type GUID {GUID_ROOT}"
    assert root.get("GrowFileSystem") == "yes", "the writable root must grow to its partition"
    assert "SizeMinBytes" in root, "ROOT must set SizeMinBytes so a too-small disk fails loudly"


def test_bounded_partitions_leave_room_on_minimum_target_disk():
    # Smoke-test and minimal installer target disks are 16 GiB.
    target_disk = 16 * 1024**3
    total = sum([
        parse_size(section_by_label("EFI-SYSTEM")["SizeMaxBytes"]),
        parse_size(section_by_label("USR-A")["SizeMaxBytes"]),
        parse_size(section_by_label("USR-B")["SizeMaxBytes"]),
        parse_size(section_by_label("OEM")["SizeMinBytes"]),
        parse_size(section_by_label("ROOT")["SizeMinBytes"]),
    ])
    assert total <= target_disk, (
        f"partition sizes ({total}) exceed 16 GiB target disk ({target_disk}), "
        "which starves the writable root"
    )


def test_partition_labels_are_unique():
    labels = [s["Label"] for s in partitions().values() if "Label" in s]
    assert len(labels) == len(set(labels)), (
        f"duplicate GPT partition labels would make Path=auto ambiguous: {labels}"
    )


def test_root_seeds_the_offline_k0s_sysext():
    root = section_by_label("ROOT")
    assert root.get("CopyFiles") == "/k0s.raw:/var/lib/k0s/k0s.raw", (
        "the writable ROOT slot must seed the offline k0s sysext raw at "
        "/var/lib/k0s/k0s.raw where k0s-first-boot.service reads it"
    )


def test_root_partition_label_is_matched_by_the_sysupdate_root_transfer():
    root = section_by_label("ROOT")
    targets = sysupdate_root_targets()
    assert root["Label"] in targets, (
        f"the installed root label {root['Label']!r} is not matched by the "
        f"sysupdate target pattern {targets}; OTA updates would find no slot"
    )


def test_sysupdate_root_target_is_provisioned_by_the_installer():
    targets = set(sysupdate_root_targets())
    provisioned = {
        s["Label"] for s in partitions().values() if s["Type"] == GUID_ROOT
    }
    assert targets.issubset(provisioned), (
        f"sysupdate targets {sorted(targets)} require slots, only {provisioned} provisioned"
    )


def test_no_var_partition_remains():
    labels = [s["Label"] for s in partitions().values()]
    assert "var" not in labels, "the var partition was removed in issue #134"
    assert not (REPART_DIR / "30-var.conf").exists(), "30-var.conf was removed in issue #134"
