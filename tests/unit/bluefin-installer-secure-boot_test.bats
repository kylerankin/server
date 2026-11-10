#!/usr/bin/env bats
#
# Unit tests for files/os/libexec/bluefin-installer-secure-boot: the USB
# installer's Secure Boot check before systemd-sysinstall erases anything
# (#309).
#
# A fake efivarfs (BLUEFIN_EFIVARS) holds SecureBoot, SetupMode, db and
# LoaderEntries in efivarfs format (4 attribute bytes, then the data); a fake
# stick (BLUEFIN_INSTALLER_KEYS) holds PK/KEK/db.auth as systemd-boot reads
# them (EFI_VARIABLE_AUTHENTICATION_2, then EFI_SIGNATURE_LISTs). bootctl and
# systemctl are stubs that log their arguments.

GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
DB=d719b2cb-3d3a-4596-a3bc-dad00e67656f
LOADER=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
X509="a1 59 c0 a5 e4 94 a7 4a 87 b5 ab 15 5c 2b f0 72"
OURS="30 82 01 0a 02 82 01 01 00 b1 e5 f1 00 0b 00 75 72 73"
MICROSOFT="30 82 06 10 30 82 03 f8 a0 03 02 01 02 02 0a 61 08 d3 c4"
OWNER="11 22 33 44 55 66 77 88 99 aa bb cc dd ee ff 00"

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/files/os/libexec/bluefin-installer-secure-boot"
    EFI="${BATS_TEST_TMPDIR}/efivars"
    KEYS="${BATS_TEST_TMPDIR}/stick/loader/keys/auto"
    CREDS="${BATS_TEST_TMPDIR}/creds"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    LOG="${BATS_TEST_TMPDIR}/calls.log"
    mkdir -p "${EFI}" "${KEYS}" "${CREDS}" "${STUB_DIR}"
    : > "${LOG}"
    for c in bootctl systemctl; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "${LOG}"\n' "${c}" > "${STUB_DIR}/${c}"
    done
    chmod +x "${STUB_DIR}"/*
    auth db.auth "${OURS}"
    auth KEK.auth "${OURS}"
    auth PK.auth "${OURS}"
}

# bytes <file> <hex...>: write the bytes.
bytes() {
    local f="$1"; shift
    # shellcheck disable=SC2059
    printf "$(printf ' %s' "$@" | sed 's/ \([0-9a-f][0-9a-f]\)/\\x\1/g')" > "${f}"
}

le32() { printf '%02x %02x %02x %02x' $(( $1 & 255 )) $(( ($1 >> 8) & 255 )) $(( ($1 >> 16) & 255 )) $(( $1 >> 24 )); }

# esl <cert hex>: one EFI_SIGNATURE_LIST with one X.509 certificate.
esl() {
    local n
    n=$(( $(wc -w <<< "$1") ))
    printf '%s %s %s %s %s %s' "${X509}" "$(le32 $(( 28 + 16 + n )))" "$(le32 0)" "$(le32 $(( 16 + n )))" "${OWNER}" "$1"
}

# auth <file> <cert hex>: an enrollment payload as on the stick.
auth() {
    local time="00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
    local wincert
    wincert="$(le32 24) 00 02 f1 0e 9d d2 af 4a df 68 ee 49 8a a9 34 7d 37 56 65 a7"
    bytes "${KEYS}/$1" "${time}" "${wincert}" "$(esl "$2")"
}

efivar() { local f="${EFI}/$1"; shift; bytes "${f}" 07 00 00 00 "$@"; }

# firmware <SecureBoot> <SetupMode> [db cert...]
firmware() {
    local sb="$1" setup="$2" lists="" c
    shift 2
    efivar "SecureBoot-${GLOBAL}" "0${sb}"
    efivar "SetupMode-${GLOBAL}" "0${setup}"
    for c in "$@"; do lists+=" $(esl "${c}")"; done
    [ -z "${lists}" ] || efivar "db-${DB}" ${lists}
}

# loader_entries <id...>: LoaderEntries as systemd-boot writes it.
loader_entries() {
    local hex="" id i
    for id in "$@"; do
        for (( i = 0; i < ${#id}; i++ )); do hex+=" $(printf '%02x' "'${id:i:1}") 00"; done
        hex+=" 00 00"
    done
    efivar "LoaderEntries-${LOADER}" ${hex}
}

check() {
    run env PATH="${STUB_DIR}:${PATH}" LOG="${LOG}" \
        BLUEFIN_EFIVARS="${EFI}" BLUEFIN_INSTALLER_KEYS="${KEYS}" \
        BLUEFIN_SECURE_BOOT_TIMEOUT=2 CREDENTIALS_DIRECTORY="${CREDS}" \
        bash "${SCRIPT}"
}

answer() { printf '%s' "$1" > "${BATS_TEST_TMPDIR}/stdin"; }
check_with_input() {
    run env PATH="${STUB_DIR}:${PATH}" LOG="${LOG}" \
        BLUEFIN_EFIVARS="${EFI}" BLUEFIN_INSTALLER_KEYS="${KEYS}" \
        BLUEFIN_SECURE_BOOT_TIMEOUT=2 CREDENTIALS_DIRECTORY="${CREDS}" \
        bash -c 'exec bash "$1" < "$2"' _ "${SCRIPT}" "${BATS_TEST_TMPDIR}/stdin"
}

unattended() { printf '[Service]\nStandardInput=null\n' > "${CREDS}/systemd.unit-dropin.systemd-sysinstall.service"; }

@test "Secure Boot on with our certificate in db: continues silently" {
    firmware 1 0 "${MICROSOFT}" "${OURS}"
    answer ""
    check_with_input
    [ "${status}" -eq 0 ]
    [[ "${output}" != *"Secure Boot is required"* ]]
    [[ "${output}" == *"Secure Boot is on with the Bluefin Server keys"* ]]  # stderr, the journal
    [[ "${output}" != *"Choice"* ]]
}

@test "Secure Boot on with our certificate also passes unattended, without the credential" {
    firmware 1 0 "${OURS}"
    unattended
    check
    [ "${status}" -eq 0 ]
}

@test "the certificate is our db certificate, not any certificate in the payload" {
    # The same bytes shifted by a nibble are not a match.
    local shifted
    shifted="$(printf '0%s0' "${OURS// /}" | sed 's/../& /g')"
    firmware 1 0 "${shifted}"
    answer ""
    check_with_input
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"does not trust the Bluefin Server keys (Secure Boot on"* ]]
}

@test "Secure Boot on in User Mode with foreign keys: warns, Enter cancels" {
    firmware 1 0 "${MICROSOFT}"
    answer $'\n'
    check_with_input
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"does not trust the Bluefin Server keys"* ]]
    [[ "${output}" == *"Reset to Setup Mode"* ]]
    [[ "${output}" == *"1) Cancel: no disk is changed (default)"* ]]
    [[ "${output}" == *"2) Continue without Secure Boot"* ]]
    [[ "${output}" == *"Installation cancelled"* ]]
    [ ! -s "${LOG}" ]
}

@test "Secure Boot off with foreign keys: no answer (end of input) cancels" {
    firmware 0 0 "${MICROSOFT}"
    answer ""
    check_with_input
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Secure Boot off, other keys enrolled"* ]]
    [[ "${output}" == *"Installation cancelled"* ]]
}

@test "Secure Boot off with our keys: tells the operator to enable it" {
    firmware 0 0 "${OURS}"
    answer "1"$'\n'
    check_with_input
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Secure Boot is off (the Bluefin Server keys are enrolled)"* ]]
    [[ "${output}" == *"set Secure Boot to Enabled"* ]]
    [[ "${output}" == *"Installation cancelled"* ]]
}

@test "Secure Boot off: the prompt times out to Cancel" {
    firmware 0 0 "${OURS}"
    mkfifo "${BATS_TEST_TMPDIR}/stdin"
    exec 5<>"${BATS_TEST_TMPDIR}/stdin"
    check_with_input
    exec 5>&-
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Installation cancelled"* ]]
}

@test "Continue without Secure Boot needs a typed yes" {
    firmware 0 0 "${MICROSOFT}"
    answer "2"$'\n'"y"$'\n'
    check_with_input
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'Type "yes" to continue without Secure Boot'* ]]
    [[ "${output}" == *"Installation cancelled"* ]]

    answer "2"$'\n'"yes"$'\n'
    check_with_input
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Continuing without Secure Boot (confirmed on the console)"* ]]
}

@test "anything but the listed choices cancels" {
    firmware 0 0 "${MICROSOFT}"
    answer "continue"$'\n'"yes"$'\n'
    check_with_input
    [ "${status}" -eq 1 ]
    [[ "${output}" != *'Type "yes"'* ]]
}

@test "Setup Mode: offers systemd-boot's enrollment, which restarts into its auto entry" {
    firmware 0 1
    loader_entries bluefin-server-installer_1.efi secure-boot-keys-auto reboot
    answer "2"$'\n'
    check_with_input
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Setup Mode (no Secure Boot keys are enrolled)"* ]]
    [[ "${output}" == *"2) Enroll the Bluefin Server keys and restart"* ]]
    [[ "${output}" == *"3) Continue without Secure Boot"* ]]
    [ "$(cat "${LOG}")" = $'bootctl set-oneshot secure-boot-keys-auto\nsystemctl reboot' ]
}

@test "Setup Mode: Enter cancels and enrolls nothing" {
    firmware 0 1
    loader_entries bluefin-server-installer_1.efi secure-boot-keys-auto
    answer $'\n'
    check_with_input
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Installation cancelled"* ]]
    [ ! -s "${LOG}" ]
}

@test "Setup Mode without systemd-boot's enrollment entry: no enroll choice" {
    firmware 0 1
    loader_entries bluefin-server-installer_1.efi xsecure-boot-keys-auto-not
    answer "2"$'\n'"yes"$'\n'
    check_with_input
    [[ "${output}" != *"Enroll the Bluefin Server keys and restart"* ]]
    [[ "${output}" == *"2) Continue without Secure Boot"* ]]
    [ "${status}" -eq 0 ]
    [ ! -s "${LOG}" ]
}

@test "unattended: Secure Boot off cancels without prompting" {
    firmware 0 0 "${MICROSOFT}"
    unattended
    answer "2"$'\n'"yes"$'\n'
    check_with_input
    [ "${status}" -eq 1 ]
    [[ "${output}" != *"Choice"* ]]
    [[ "${output}" == *"unattended install and the firmware does not trust the Bluefin Server keys"* ]]
    [[ "${output}" == *"bluefin.install-allow-insecure-boot=1"* ]]
}

@test "unattended: a drop-in credential with a name suffix counts too" {
    firmware 0 1
    printf '[Service]\n' > "${CREDS}/systemd.unit-dropin.systemd-sysinstall.service~dogfood"
    check
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"unattended install"* ]]
    [ ! -s "${LOG}" ]
}

@test "unattended: bluefin.install-allow-insecure-boot=1 continues without Secure Boot" {
    firmware 0 0 "${MICROSOFT}"
    unattended
    printf '1\n' > "${CREDS}/bluefin.install-allow-insecure-boot"
    check
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Continuing without Secure Boot (credential bluefin.install-allow-insecure-boot)"* ]]
}

@test "the credential must say yes" {
    firmware 0 0 "${MICROSOFT}"
    unattended
    printf '0' > "${CREDS}/bluefin.install-allow-insecure-boot"
    check
    [ "${status}" -eq 1 ]
}

@test "no Secure Boot variables at all (firmware without Secure Boot) warns" {
    unattended
    check
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"reports no Secure Boot state"* ]]
}

@test "a stick without db.auth cannot prove our keys and warns" {
    firmware 1 0 "${OURS}"
    rm "${KEYS}/db.auth"
    unattended
    check
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot be read"* ]]
}
