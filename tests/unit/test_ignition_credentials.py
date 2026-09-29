"""Executed coverage for bluefin-ignition-credentials.

bluefin-ignition-credentials stages an Ignition config from a system credential
or, for a network-booted node, from bluefin-node.ign next to the UKI. The
Ignition config used to be fetched and applied with no signature or hash — an
on-path attacker on the (often plain-HTTP) provisioning network got root despite
the signed boot chain. This verifies the fix: a plain http:// origin is refused,
a detached signature (bluefin-node.ign.gpg) is checked against the import
keyring and the verified bytes staged inline, and an https origin without a
signature still provisions but is flagged unauthenticated. Both run against a
local HTTPS server (curl trusts its self-signed cert via CURL_CA_BUNDLE) and a
throwaway GnuPG key; no files/boot-keys are needed.
"""

from __future__ import annotations

import functools
import os
import shutil
import stat
import subprocess
import threading
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "files" / "initrd-ignition" / "usr" / "libexec" / "bluefin-ignition-credentials"
ELEMENTS = ROOT / "elements" / "bluefin-server" / "initrd"
needs_tools = pytest.mark.skipif(
    not all(shutil.which(t) for t in ("curl", "gpg", "gpgv", "openssl")),
    reason="needs curl, gpg, gpgv and openssl",
)

CONFIG = """\
{"ignition":{"version":"3.6.0"},"systemd":{"units":[{"name":"x.service","enabled":true,"contents":"[Unit]\\n[Service]\\nExecStart=/bin/true\\n[Install]\\nWantedBy=multi-user.target\\n"}]}}
"""


def test_ships_in_the_initrd_stack_and_is_executable_bash() -> None:
    import yaml

    stack = yaml.safe_load((ELEMENTS / "initrd-stack.bst").read_text(encoding="utf-8"))["depends"]
    assert "bluefin-server/initrd/initrd-ignition-stack.bst" in stack
    doc = yaml.safe_load((ELEMENTS / "initrd-ignition-stack.bst").read_text(encoding="utf-8"))
    assert doc["kind"] == "stack"
    assert "bluefin-server/initrd/initrd-ignition.bst" in doc["depends"]
    assert SCRIPT.read_text(encoding="utf-8").startswith("#!/usr/bin/bash\n")
    assert SCRIPT.stat().st_mode & stat.S_IXUSR
    subprocess.run(["bash", "-n", str(SCRIPT)], check=True)


def test_uses_the_import_keyring_and_refuses_plain_http() -> None:
    body = SCRIPT.read_text(encoding="utf-8")
    # same trust root as the /usr image pull and sysupdate
    assert "/etc/systemd/import-pubring.pgp" in body
    assert "/usr/lib/systemd/import-pubring.pgp" in body
    # the headline fix: a plain http origin is refused, automatic or credential
    assert 'http://*) die' in body
    assert "fetched and applied with no signature" in body


@pytest.fixture(scope="module")
def keys(tmp_path_factory: pytest.TempPathFactory) -> dict[str, Path]:
    base = tmp_path_factory.mktemp("gpg")
    out = {}
    for name in ("release", "stranger"):
        home = base / name
        home.mkdir(mode=0o700)
        env = dict(os.environ, GNUPGHOME=str(home))
        subprocess.run(
            ["gpg", "--batch", "--quiet", "--passphrase", "", "--quick-gen-key",
             f"{name} <{name}@example.invalid>", "ed25519", "sign", "never"],
            check=True, env=env, capture_output=True,
        )
        ring = base / f"{name}.pgp"
        subprocess.run(["gpg", "--batch", "--export", "--output", str(ring)], check=True, env=env, capture_output=True)
        out[name] = home
        out[f"{name}-ring"] = ring
    return out


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args) -> None:
        pass


def _serve(root: Path, cert_dir: Path) -> tuple[ThreadingHTTPServer, str]:
    import ssl

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=str(cert_dir / "cert.pem"), keyfile=str(cert_dir / "key.pem"))
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(root)))
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    url = f"https://127.0.0.1:{httpd.server_address[1]}"
    return httpd, url


@pytest.fixture()
def origin(tmp_path: Path):
    # A self-signed cert for 127.0.0.1; curl is pointed at it via CURL_CA_BUNDLE.
    srv = tmp_path / "srv"
    srv.mkdir()
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-keyout", "key.pem", "-out", "cert.pem",
         "-days", "1", "-nodes", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1"],
        check=True, cwd=tmp_path, capture_output=True,
    )
    httpd, url = _serve(srv, tmp_path)
    yield url, srv
    httpd.shutdown()
    httpd.server_close()


def _publish(directory: Path, *, config: str = CONFIG, sign_key: Path | None = None) -> None:
    (directory / "bluefin-server-netboot.efi").write_text("uki", encoding="utf-8")
    (directory / "bluefin-node.ign").write_text(config, encoding="utf-8")
    if sign_key is not None:
        subprocess.run(
            ["gpg", "--batch", "--yes", "--detach-sign", "--output",
             str(directory / "bluefin-node.ign.gpg"), str(directory / "bluefin-node.ign")],
            check=True, env=dict(os.environ, GNUPGHOME=str(sign_key)), capture_output=True,
        )


def run(
    tmp_path: Path,
    *,
    origin_url: str | None = None,
    creds: dict[str, str] | None = None,
    keyring: Path | None = None,
) -> tuple[int, str, str | None]:
    """Run bluefin-ignition-credentials. Returns (returncode, combined output,
    or the staged user.ign contents, or None if nothing was staged)."""
    out = tmp_path / "run" / "ignition"
    out.mkdir(parents=True)
    env = dict(os.environ, BLUEFIN_IGNITION_OUT=str(out / "user.ign"), CURL_CA_BUNDLE=str(tmp_path / "cert.pem"))
    env.pop("CREDENTIALS_DIRECTORY", None)
    if keyring is not None:
        env["BLUEFIN_KEYRING"] = str(keyring)
    if creds:
        cred_dir = tmp_path / "creds"
        cred_dir.mkdir(exist_ok=True)
        for name, value in creds.items():
            (cred_dir / name).write_text(value, encoding="utf-8")
        env["CREDENTIALS_DIRECTORY"] = str(cred_dir)
    if origin_url is not None:
        # A stand-in for /usr/libexec/bluefin-boot-origin: it reports the URL the
        # node booted from (the UKI URL; the config lives next to it).
        bo = tmp_path / "boot-origin"
        bo.write_text(f'#!/usr/bin/bash\nprintf "%s\\n" "{origin_url}"\n', encoding="utf-8")
        bo.chmod(0o755)
        env["BLUEFIN_BOOT_ORIGIN"] = str(bo)
    result = subprocess.run([str(SCRIPT)], capture_output=True, text=True, env=env, timeout=120)
    user_ign = out / "user.ign"
    contents = user_ign.read_text(encoding="utf-8") if user_ign.exists() else None
    return result.returncode, result.stdout + result.stderr, contents


@needs_tools
def test_signed_node_config_is_staged_inline(tmp_path: Path, origin: tuple[str, Path], keys: dict[str, Path]) -> None:
    url, srv = origin
    _publish(srv, sign_key=keys["release"])
    rc, log, contents = run(tmp_path, origin_url=url + "/bluefin-server-netboot.efi", keyring=keys["release-ring"])
    assert rc == 0, log
    assert contents == CONFIG, "the verified bytes are staged verbatim"
    assert "gpgv-verified" in log


@needs_tools
def test_signature_from_another_key_is_refused(tmp_path: Path, origin: tuple[str, Path], keys: dict[str, Path]) -> None:
    url, srv = origin
    _publish(srv, sign_key=keys["stranger"])
    rc, log, contents = run(tmp_path, origin_url=url + "/bluefin-server-netboot.efi", keyring=keys["release-ring"])
    assert rc == 1, "an unverifiable signature must be refused"
    assert contents is None
    assert "does not verify" in log


@needs_tools
def test_unsigned_node_config_over_https_still_provisions_but_is_flagged(tmp_path: Path, origin: tuple[str, Path], keys: dict[str, Path]) -> None:
    url, srv = origin
    _publish(srv, sign_key=None)
    rc, log, contents = run(tmp_path, origin_url=url + "/bluefin-server-netboot.efi", keyring=keys["release-ring"])
    assert rc == 0, log
    assert contents is not None
    # no signature served: the config is wrapped in a config.replace of the
    # https URL, and the run is flagged unauthenticated
    assert "replace" in contents
    assert "https://" in contents
    assert "UNAUTHENTICATED" in log


@needs_tools
def test_plain_http_boot_origin_is_refused(tmp_path: Path, origin: tuple[str, Path], keys: dict[str, Path]) -> None:
    url, srv = origin
    _publish(srv)
    http_origin = url.replace("https://", "http://")
    rc, log, contents = run(tmp_path, origin_url=http_origin + "/bluefin-server-netboot.efi", keyring=keys["release-ring"])
    assert rc == 1, "a plain http origin is refused"
    assert contents is None
    assert "refusing http://" in log


@needs_tools
def test_ignition_config_credential_is_staged_inline(tmp_path: Path) -> None:
    rc, log, contents = run(tmp_path, creds={"ignition.config": CONFIG})
    assert rc == 0, log
    assert contents == CONFIG


@needs_tools
def test_http_config_url_credential_is_refused(tmp_path: Path) -> None:
    rc, log, contents = run(tmp_path, creds={"ignition.config.url": "http://10.0.2.2:8765/bluefin-node.ign"})
    assert rc == 1, "a plain http config URL is refused"
    assert contents is None
    assert "refusing http://" in log


@needs_tools
def test_https_config_url_credential_is_staged_as_replace(origin: tuple[str, Path], tmp_path: Path) -> None:
    url, _ = origin
    rc, log, contents = run(tmp_path, creds={"ignition.config.url": url + "/bluefin-node.ign"})
    assert rc == 0, log
    assert contents is not None
    assert "replace" in contents
    assert url + "/bluefin-node.ign" in contents


@needs_tools
def test_no_credential_and_no_boot_origin_is_a_no_op(tmp_path: Path) -> None:
    rc, log, contents = run(tmp_path)
    assert rc == 0, log
    assert contents is None
    assert "nothing to apply" in log
