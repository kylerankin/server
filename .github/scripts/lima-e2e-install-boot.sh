#!/usr/bin/env bash
# End-to-end installer and boot verification inside a nested-virt Lima VM.
#
# Verifies the full unattended chain the issue calls for:
#   Source elements -> Installer Raw Image ->
#   systemd-sysinstall auto-partitioning & DDI copy (Lima VM) ->
#   Installed target disk boot (Lima VM) -> multi-user.target / login prompt
#
# Runs entirely inside the Lima guest so BuildStream/podman and QEMU share the
# single nested-virt-enabled VM (the macOS runner has no native KVM).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SERIAL_DIR="$(mktemp -d)"
trap 'echo "==> Serial logs retained at ${SERIAL_DIR}"; exit $?' INT TERM

DEADLINE_SECS="${LIMA_E2E_DEADLINE_SECS:-720}"
TARGET_DISK_SIZE="${LIMA_E2E_TARGET_DISK_SIZE:-16G}"
INSTALLER_BOOT_DEADLINE="${LIMA_E2E_INSTALLER_BOOT_DEADLINE:-360}"

fail() {
  echo "ERROR: $*" >&2
  echo "===== installer serial tail =====" >&2
  tail -n 80 "${SERIAL_DIR}/installer.log" 2>/dev/null >&2 || true
  echo "===== target serial tail =====" >&2
  tail -n 80 "${SERIAL_DIR}/target.log" 2>/dev/null >&2 || true
  exit 1
}

first_existing() {
  for candidate in "$@"; do
    [ -f "$candidate" ] && { echo "$candidate"; return 0; }
  done
  return 1
}

echo "==> Validating element graph (just validate)..."
just validate

echo "==> Building and exporting the installer raw image..."
just export-installer
INSTALLER_ZST="$(find dist/ -maxdepth 1 -type f -name 'bluefin-server-installer-*.raw.zst' -print -quit)"
[ -n "${INSTALLER_ZST}" ] || fail "no exported installer image found in dist/"
echo "==> Installer artifact: ${INSTALLER_ZST}"

INSTALLER_RAW="${SERIAL_DIR}/installer.raw"
TARGET_RAW="${SERIAL_DIR}/target.raw"
zstd -d -f "${INSTALLER_ZST}" -o "${INSTALLER_RAW}"
truncate -s "${TARGET_DISK_SIZE}" "${TARGET_RAW}"

OVMF_CODE="$(first_existing \
  /home/linuxbrew/.linuxbrew/Cellar/qemu/*/share/qemu/edk2-x86_64-code.fd \
  /usr/share/edk2/ovmf/OVMF_CODE.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/OVMF/OVMF_CODE_4M.fd \
  /usr/share/edk2/x64/OVMF_CODE.4m.fd \
  /usr/share/qemu/edk2-x86_64-code.fd \
  /usr/share/qemu/OVMF_CODE.fd)" \
  || fail "OVMF_CODE.fd not found; install qemu-efi"

# ponytail: OVMF_VARS is stateful; reuse one fresh NVRAM across the two boots so
# the firmware boot order survives from the installer boot into the target boot.
# A zero-filled copy of the firmware size is a valid empty NVRAM (matches
# show-me-the-future); the guest writes its own variables there.
OVMF_VARS="${SERIAL_DIR}/ovmf-vars.fd"
truncate -s "$(stat -c '%s' "$OVMF_CODE")" "$OVMF_VARS"

SMP_CPUS="${LIMA_E2E_SMP:-$(nproc)}"
MEM_SIZE="${LIMA_E2E_MEM:-8192}"

# ── Step 1: boot the installer media, run the unattended install ──────────
# The installer overrides systemd-sysinstall.service with SuccessAction=poweroff,
# so on a successful unattended install the guest powers off and -no-reboot
# makes QEMU exit. A missing target disk or install failure also exits QEMU,
# which we detect by watching the process.
echo "==> Booting installer media in QEMU (unattended)..."
if ! timeout "${INSTALLER_BOOT_DEADLINE}s" qemu-system-x86_64 \
    -enable-kvm \
    -m "${MEM_SIZE}" \
    -cpu host \
    -smp "${SMP_CPUS}" \
    -drive file="${INSTALLER_RAW}",format=raw,if=virtio,readonly=on \
    -drive file="${TARGET_RAW}",format=raw,if=virtio \
    -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,file="${OVMF_VARS}" \
    -kernel "$(find dist/ -maxdepth 1 -type f -name 'bluefin-server-pxe-vmlinuz-*' -print -quit)" \
    -initrd "$(find dist/ -maxdepth 1 -type f -name 'bluefin-server-pxe-initrd-*.cpio.gz' -print -quit)" \
    -append "systemd.unit=system-install.target console=tty0 console=ttyS0,115200 rw unattended" \
    -nographic \
    -no-reboot \
    -serial file:"${SERIAL_DIR}/installer.log" \
    </dev/null; then
  RC=$?
  if [ "${RC}" -eq 124 ]; then
    fail "installer boot exceeded ${INSTALLER_BOOT_DEADLINE}s (see ${SERIAL_DIR}/installer.log)"
  fi
fi

if grep -qaE 'Running in UNATTENDED mode|systemd-sysinstall.*[Ss]uccess|Installation complete' "${SERIAL_DIR}/installer.log" 2>/dev/null; then
  echo "==> Installer ran the unattended install."
elif grep -qa 'system-install.target' "${SERIAL_DIR}/installer.log"; then
  echo "==> Installer reached system-install.target (no explicit completion line; continuing to boot check)."
else
  fail "installer never reached system-install.target (see ${SERIAL_DIR}/installer.log)"
fi

# ── Step 2: boot the installed target disk and verify multi-user.target ──
echo "==> Booting the installed target disk in QEMU..."
# The installed OS keeps /var on its own XFS partition; supply the fstab
# credential so systemd mounts /var on first boot, matching show-me-the-future.
START_TIME=$(date +%s)
qemu-system-x86_64 \
    -enable-kvm \
    -m "${MEM_SIZE}" \
    -cpu host \
    -smp "${SMP_CPUS}" \
    -drive file="${TARGET_RAW}",format=raw,if=virtio \
    -drive if=pflash,format=raw,readonly=on,file="${OVMF_CODE}" \
    -drive if=pflash,format=raw,file="${OVMF_VARS}" \
    -smbios "type=11,value=io.systemd.stub.kernel-cmdline-extra=console=tty0 console=ttyS0,,115200 systemd.mask=systemd-firstboot.service" \
    -smbios "type=11,value=io.systemd.stub.credential.fstab.extra=L2Rldi9kaXNrL2J5LXBhcnRsYWJlbC92YXIgL3ZhciB4ZnMgZGVmYXVsdHMgMCAwCg==" \
    -nographic \
    -serial file:"${SERIAL_DIR}/target.log" \
    </dev/null &
TARGET_QEMU_PID=$!

while true; do
  kill -0 "${TARGET_QEMU_PID}" 2>/dev/null || break
  if grep -qaE 'Reached multi-user.target|login:|Bluefin' "${SERIAL_DIR}/target.log" 2>/dev/null; then
    break
  fi
  if [ $(( $(date +%s) - START_TIME )) -ge "${DEADLINE_SECS}" ]; then
    fail "target boot exceeded ${DEADLINE_SECS}s without reaching multi-user.target (see ${SERIAL_DIR}/target.log)"
  fi
  sleep 3
done

kill "${TARGET_QEMU_PID}" 2>/dev/null || true
wait "${TARGET_QEMU_PID}" 2>/dev/null || true

if ! grep -qa 'Reached multi-user.target' "${SERIAL_DIR}/target.log"; then
  fail "target did not reach multi-user.target (see ${SERIAL_DIR}/target.log)"
fi

echo "==> SUCCESS: installed Bluefin Server reached multi-user.target."
echo "    installer log: ${SERIAL_DIR}/installer.log"
echo "    target log:    ${SERIAL_DIR}/target.log"
