"""Tests for Lima VM template configuration and e2e orchestration contracts."""

from pathlib import Path
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
LIMA_TEMPLATE = REPO_ROOT / "files" / "lima" / "bluefin-server-kiosk.yaml"
E2E_TEMPLATE = REPO_ROOT / ".github" / "scripts" / "bluefin-lima-template.yaml"
E2E_SCRIPT = REPO_ROOT / "tests" / "e2e" / "test_kubestellar_browser_login.py"
JUSTFILE = REPO_ROOT / "Justfile"


def test_lima_e2e_template_uses_standard_lima_schema() -> None:
    assert E2E_TEMPLATE.is_file(), f"{E2E_TEMPLATE} must exist"
    data = yaml.safe_load(E2E_TEMPLATE.read_text(encoding="utf-8"))

    # Extend the canonical Ubuntu 24.04 cloud-image base so `limactl validate`
    # gets the required `images` and a resolved arch.
    base = data.get("base", [])
    assert "template:_images/ubuntu-24.04" in base, (
        "template must extend base: [template:_images/ubuntu-24.04]"
    )

    # Expose /dev/kvm to the guest so the e2e script can QEMU-boot with -enable-kvm.
    assert data.get("nestedVirtualization") is True

    # `ssh.localShell` was rejected by limactl validate; the ssh block must not
    # carry it.
    assert "localShell" not in (data.get("ssh") or {})


def test_lima_kiosk_template_exists_and_is_valid_yaml() -> None:
    assert LIMA_TEMPLATE.is_file(), f"{LIMA_TEMPLATE} must exist"
    data = yaml.safe_load(LIMA_TEMPLATE.read_text(encoding="utf-8"))

    assert data.get("vmType") == "qemu"
    assert data.get("arch") == "x86_64"
    assert "images" in data and len(data["images"]) > 0

    # Ensure essential port forwards are defined
    port_forwards = data.get("portForwards", [])
    guest_ports = [pf.get("guestPort") for pf in port_forwards]
    assert 8080 in guest_ports, "Port 8080 must be forwarded for KubeStellar Console"
    assert 6443 in guest_ports, "Port 6443 must be forwarded for Kubernetes API"


def test_e2e_browser_test_script_exists() -> None:
    assert E2E_SCRIPT.is_file(), f"{E2E_SCRIPT} must exist"
    content = E2E_SCRIPT.read_text(encoding="utf-8")
    assert "selenium" in content
    assert "8080" in content
    assert "8585" in content
    assert "kubestellar-kiosk-gate" in content


def test_justfile_defines_setup_kubestellar_and_e2e_targets() -> None:
    justfile = JUSTFILE.read_text(encoding="utf-8")
    assert "test-e2e-browser" in justfile
    assert "test-e2e-lima:" in justfile
