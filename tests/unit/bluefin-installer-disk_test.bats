#!/usr/bin/env bats
#
# Unit tests for files/os/libexec/bluefin-installer-disk: the USB installer's
# target-disk question, with each disk's size and model, before
# systemd-sysinstall (#311).
#
# varlinkctl is a stub that logs its arguments and prints REPLIES (the
# JSON-SEQ records systemd-repart's io.systemd.Repart.ListCandidateDevices
# sends with --more --json=short), or fails like the NoCandidateDevices
# sentinel when REPLIES is empty. The answers come on stdin.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/files/os/libexec/bluefin-installer-disk"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    export LOG="${BATS_TEST_TMPDIR}/calls.log"
    export REPLIES="${BATS_TEST_TMPDIR}/replies"
    export RUNTIME_DIRECTORY="${BATS_TEST_TMPDIR}/run"
    export CREDENTIALS_DIRECTORY="${BATS_TEST_TMPDIR}/creds"
    export BLUEFIN_VARLINKCTL="${STUB_DIR}/varlinkctl"
    export BLUEFIN_OS_RELEASE="${BATS_TEST_TMPDIR}/os-release"
    ENV_FILE="${RUNTIME_DIRECTORY}/sysinstall.env"
    mkdir -p "${STUB_DIR}" "${RUNTIME_DIRECTORY}" "${CREDENTIALS_DIRECTORY}"
    : > "${LOG}"
    : > "${REPLIES}"
    printf 'ID=bluefin-server\nIMAGE_VERSION="26.10.1"\n' > "${BLUEFIN_OS_RELEASE}"
    cat > "${STUB_DIR}/varlinkctl" <<'EOF'
#!/usr/bin/env bash
echo "varlinkctl $*" >> "${LOG}"
[ -s "${REPLIES}" ] || { echo "Method call failed: io.systemd.Repart.NoCandidateDevices" >&2; exit 1; }
cat "${REPLIES}"
EOF
    chmod +x "${STUB_DIR}/varlinkctl"
}

# reply <json>: one record as varlinkctl --more --json=short prints it.
reply() { printf '\x1e%s\n' "$1" >> "${REPLIES}"; }

nvme='{"node":"/dev/nvme0n1","symlinks":["/dev/disk/by-id/nvme-eui.002538b231b4c7a1","/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNX0R123456","/dev/disk/by-path/pci-0000:01:00.0-nvme-1"],"diskseq":3,"sizeBytes":1000204886016,"model":"Samsung SSD 980 PRO 1TB","subsystem":"nvme"}'
sata='{"node":"/dev/sda","symlinks":["/dev/disk/by-id/wwn-0x50014ee2b5c7a8f1","/dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K0ABCDEF"],"diskseq":4,"sizeBytes":4000787030016,"model":"WDC_WD40EFRX-68N32N0","vendor":"ATA","subsystem":"scsi"}'
virtio='{"node":"/dev/vda","symlinks":["/dev/disk/by-id/virtio-bluefin-target","/dev/disk/by-path/pci-0000:00:03.0"],"diskseq":2,"sizeBytes":17179869184,"vendor":"0x1af4","subsystem":"virtio"}'

@test "asks systemd-repart for the disks sysinstall would list, the stick left out" {
    reply "${virtio}"
    run bash "${SCRIPT}" <<< ""
    [ "${status}" -eq 0 ]
    grep -qxF 'varlinkctl --more --json=short call exec:/usr/bin/systemd-repart io.systemd.Repart.ListCandidateDevices {"ignoreRoot":true}' "${LOG}"
}

@test "lists every disk with its number, size, model and by-id name" {
    reply "${nvme}"
    reply "${sata}"
    reply "${virtio}"
    run bash "${SCRIPT}" <<< "3"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Install Bluefin Server 26.10.1 to which disk?"* ]]
    [[ "${output}" == *"erases the chosen disk completely"* ]]
    grep -qE '^  1\) 931\.5G +Samsung SSD 980 PRO 1TB +nvme-Samsung_SSD_980_PRO_1TB_S5GXNX0R123456$' <<< "${output}"
    # udev's ID_MODEL has underscores for spaces.
    grep -qE '^  2\) 3\.6T +WDC WD40EFRX-68N32N0 +ata-WDC_WD40EFRX-68N32N0_WD-WCC7K0ABCDEF$' <<< "${output}"
    # No model: the vendor, as repart reports it.
    grep -qE '^  3\) 16G +0x1af4 +virtio-bluefin-target$' <<< "${output}"
    [[ "${output}" == *"Disk number (1-3), or q to cancel: "* ]]
}

@test "the chosen disk goes to sysinstall by its by-id name" {
    reply "${nvme}"
    reply "${sata}"
    run bash "${SCRIPT}" <<< "2"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ENV_FILE}")" = "BLUEFIN_INSTALL_TARGET=/dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K0ABCDEF" ]
    [[ "${output}" == *"Disk 2: /dev/disk/by-id/ata-WDC_WD40EFRX-68N32N0_WD-WCC7K0ABCDEF (3.6T, WDC WD40EFRX-68N32N0)."* ]]
}

@test "a disk without a by-id name goes by its kernel node" {
    reply '{"node":"/dev/vdb","symlinks":["/dev/disk/by-path/pci-0000:00:04.0"],"sizeBytes":8589934592}'
    run bash "${SCRIPT}" <<< "1"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ENV_FILE}")" = "BLUEFIN_INSTALL_TARGET=/dev/vdb" ]
    grep -qE '^  1\) 8G +unknown model +/dev/vdb$' <<< "${output}"
}

@test "a disk with only wwn or eui names goes by one of those" {
    reply '{"node":"/dev/sdb","symlinks":["/dev/disk/by-id/wwn-0x5000c500a1b2c3d4"],"sizeBytes":2000398934016,"model":"ST2000DM008"}'
    run bash "${SCRIPT}" <<< "1"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ENV_FILE}")" = "BLUEFIN_INSTALL_TARGET=/dev/disk/by-id/wwn-0x5000c500a1b2c3d4" ]
    grep -qE '^  1\) 1\.8T +ST2000DM008 ' <<< "${output}"
}

@test "with one disk, Enter chooses it" {
    reply "${virtio}"
    run bash "${SCRIPT}" <<< ""
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Disk number [1], or q to cancel: "* ]]
    [ "$(cat "${ENV_FILE}")" = "BLUEFIN_INSTALL_TARGET=/dev/disk/by-id/virtio-bluefin-target" ]
}

@test "with several disks, Enter and wrong answers ask again" {
    reply "${nvme}"
    reply "${sata}"
    run bash "${SCRIPT}" < <(printf '\n0\n3\nsda\n 1 \n')
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"There is no disk 0."* ]]
    [[ "${output}" == *"There is no disk 3."* ]]
    [[ "${output}" == *"Not a disk number: sda"* ]]
    [ "$(grep -c 'Disk number (1-2), or q to cancel: ' <<< "${output}")" -ge 1 ]
    [ "$(cat "${ENV_FILE}")" = "BLUEFIN_INSTALL_TARGET=/dev/disk/by-id/nvme-Samsung_SSD_980_PRO_1TB_S5GXNX0R123456" ]
}

@test "q cancels: no disk for sysinstall, which then does not start" {
    reply "${nvme}"
    reply "${sata}"
    run bash "${SCRIPT}" <<< "q"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Installation cancelled: no disk was chosen."* ]]
    [[ "${output}" == *"No disk was changed."* ]]
    [ ! -s "${ENV_FILE}" ]
}

@test "end of input cancels" {
    reply "${nvme}"
    reply "${sata}"
    run bash "${SCRIPT}" < /dev/null
    [ "${status}" -eq 1 ]
    [ ! -s "${ENV_FILE}" ]
}

@test "no disk to install to cancels with the reason" {
    run bash "${SCRIPT}" <<< "1"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"no disk to install to was found"* ]]
    [ ! -s "${ENV_FILE}" ]
}

@test "an unattended install is not asked: its drop-in names the disk" {
    reply "${nvme}"
    for name in systemd.unit-dropin.systemd-sysinstall.service systemd.unit-dropin.systemd-sysinstall.service~50-dogfood; do
        rm -f "${CREDENTIALS_DIRECTORY}"/*
        : > "${LOG}"
        : > "${CREDENTIALS_DIRECTORY}/${name}"
        run bash "${SCRIPT}" < /dev/null
        [ "${status}" -eq 0 ]
        # Nothing on the monitor; the reason goes to the journal.
        [ "${output}" = "bluefin-installer-disk: unattended install: the disk is the one its drop-in names" ]
        [ ! -s "${LOG}" ]
        [ -e "${ENV_FILE}" ] && [ ! -s "${ENV_FILE}" ]
    done
}

@test "another unit's drop-in credential is not an unattended install" {
    reply "${virtio}"
    : > "${CREDENTIALS_DIRECTORY}/systemd.unit-dropin.bluefin-installer-done.service"
    run bash "${SCRIPT}" <<< "1"
    [ "${status}" -eq 0 ]
    [ "$(cat "${ENV_FILE}")" = "BLUEFIN_INSTALL_TARGET=/dev/disk/by-id/virtio-bluefin-target" ]
}
