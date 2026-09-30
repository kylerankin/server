---
name: booty-integration
description: How Booty serves Bluefin Server releases to nodes. Load when working on HTTP boot, iPXE chainloading, per-node Ignition, or kubeadm worker provisioning.
metadata:
  type: reference
  status: stable
  last_updated: "2026-09-29"
---
# Booty Integration

[Booty](https://github.com/jeefy/booty) is the network boot server for Bluefin
Server at scale. It syncs a release and answers boot requests with the right
artifacts per node.

## What Booty serves

From a release `v<ver>` (GitHub Releases or the ORAS OCI artifact at
`ghcr.io/projectbluefin/bluefin-server:<ver>,latest`) Booty syncs the netboot
UKI `bluefin-server-netboot_<ver>.efi`, the OS DDI `bluefin-server_<ver>.raw`,
`SHA256SUMS` and `SHA256SUMS.gpg`, and any listed sysext assets
(`zfs_<ver>.raw.zst`, `kubestellar_<ver>.raw.zst`, `kubeadm_<ver>.raw.zst`,
`k0s-<k0s-ver>.raw.zst`), verifies them against `SHA256SUMS` (and, with
`--bluefinKeyring`, against the GPG signature), and serves them over plain
HTTP. The netboot ESP image, the disk UKI and the USB installer are not
synced; they are for booting without Booty.

## Boot paths

| Firmware | Path |
|---|---|
| UEFI HTTP Boot | Firmware fetches `http://<booty>/bluefin/<mac>/bluefin-server-netboot.efi`; Secure Boot on. |
| iPXE chainload | UEFI firmware without HTTP Boot PXE-boots iPXE, which chainloads the netboot UKI with an explicit `rd.systemd.pull` URL; Secure Boot off. |
| Legacy BIOS | BIOS iPXE boots the UKI's kernel and initrd sections directly, diskless only; no install, no sysupdate, no boot counting (those need UEFI). |

## Per-node configuration

Booty renders a `bluefin-node.ign` (Ignition spec 3.6.0) per MAC address and
serves it next to the UKI. Fields include hostname, SSH keys (which also
enable `sshd.service`, disabled by preset in the image), state disk,
extensions (any of `zfs`, `kubestellar`, `k0s`), and a k0s token.

A node with no `ignition.config` / `ignition.config.url` credential HEADs
`bluefin-node.ign` next to its boot origin. Nothing there means nothing to
apply. If it is there, `bluefin-ignition-credentials` in the initrd applies it
only if it is signed:

- It fetches `bluefin-node.ign.gpg` from the same directory and verifies it
  with `gpgv` against the import keyring (the `/etc/systemd/import-pubring.pgp`
  override, else the image's `/usr/lib/systemd/import-pubring.pgp`: the same
  root as the image pull), then stages the verified bytes inline at
  `/run/ignition/user.ign`, so Ignition applies exactly what was signed. The
  signature is the gate, not the transport: plain `http://` works, as it does
  for the `/usr` pull.
- Only an HTTP 404 on the `.gpg` counts as "unsigned", and an unsigned config
  is applied only with the system credential `bluefin.ignition.allow-unsigned`
  (any non-empty value), a trust-the-network opt-out that costs nothing
  extra: whoever can set it can already set `ignition.config`. Any other
  failure fetching the `.gpg` (5xx, timeout, dropped connection), or a
  signature that does not verify, fails the boot into emergency mode
  (`bluefin-ignition-credentials.service` has `OnFailure=emergency.target`).
- A signed config must be self-contained. Ignition fetches
  `ignition.config.merge` / `replace` targets and remote
  `storage.files[].contents.source` URLs without checking them against any
  signature, so each such source needs a `verification.hash`.

Booty signing per-MAC configs is tracked in issue #284. Until it does,
plain-network Booty deployments that serve `bluefin-node.ign` need the
opt-out credential, or they stop at emergency mode.

## Install to disk

Setting `doInstall` in the node's Booty config boots it into
`booty-install.service`, which runs `systemd-sysinstall` against the local
disk. Without Booty, write `bluefin-server-netboot_<ver>.esp.raw` to a USB
stick and place an `import.pull.cred` credential in `/loader/credentials/`
specifying the URL to pull.

## kubeadm workers

A Bluefin host joins a kubeadm cluster when Booty is run with
`--profile=kubeadm-worker` against an external cluster: its `bluefin-node.ign`
then carries the release's `kubeadm` sysext (version-locked, see
[kubeadm-sysext.md](kubeadm-sysext.md)), enables `containerd.service` and
`kubelet.service`, and runs `kubeadm join` on every diskless boot. `kubeadm`
is not one of the host's selectable `extensions`; Booty adds it for the
profile. How Booty renders and serves this lives in the Booty README; the
sysext's contents and runtime contract live in
[kubeadm-sysext.md](kubeadm-sysext.md).

## Read more

- [Booty README](https://github.com/jeefy/booty) — flags, config file layout,
  and the operator-side boot and provisioning story.
- [ddi-installer.md](ddi-installer.md) — boot flow, DDI layout, and sysinstall
  contract.
- [kubeadm-sysext.md](kubeadm-sysext.md) — worker sysext build and runtime
  contract.

## See also

- [index.md](index.md) — lazy-load routing manifest.
- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary.
