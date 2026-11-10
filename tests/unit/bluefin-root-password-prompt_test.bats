#!/usr/bin/env bats
#
# Unit tests for files/os/libexec/bluefin-root-password-prompt: the first
# boot after a USB install asks for a root password until root has one
# (#311).
#
# systemd-firstboot is a stub that logs its arguments and answers like the
# real one from the next line of ANSWERS: "pw" sets a password hash for root
# in the fake /etc/shadow, "empty" writes the locked, invalid "!*" stock
# firstboot writes for an empty answer, and "skip" changes nothing (root
# already configured, without --force). "fail" exits 1.

setup() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    SCRIPT="${REPO_ROOT}/files/os/libexec/bluefin-root-password-prompt"
    STUB_DIR="${BATS_TEST_TMPDIR}/bin"
    export LOG="${BATS_TEST_TMPDIR}/calls.log"
    export ANSWERS="${BATS_TEST_TMPDIR}/answers"
    export BLUEFIN_SHADOW="${BATS_TEST_TMPDIR}/shadow"
    export BLUEFIN_CMDLINE="${BATS_TEST_TMPDIR}/cmdline"
    export BLUEFIN_FIRSTBOOT="${STUB_DIR}/systemd-firstboot"
    export CREDENTIALS_DIRECTORY="${BATS_TEST_TMPDIR}/creds"
    mkdir -p "${STUB_DIR}" "${CREDENTIALS_DIRECTORY}"
    : > "${LOG}"
    : > "${ANSWERS}"
    printf 'quiet console=tty0 console=ttyS0,115200\n' > "${BLUEFIN_CMDLINE}"
    shadow '!unprovisioned'
    cat > "${BLUEFIN_FIRSTBOOT}" <<'EOF'
#!/usr/bin/env bash
echo "systemd-firstboot $*" >> "${LOG}"
answer="$(head -n1 "${ANSWERS}")"
sed -i 1d "${ANSWERS}"
case "${answer}" in
    pw) hash='$y$j9T$dogfood$notarealhash' ;;
    empty) hash='!*' ;;
    fail) exit 1 ;;
    *) exit 0 ;;
esac
printf 'root:%s:20000::::::\nnobody:!*:20000::::::\n' "${hash}" > "${BLUEFIN_SHADOW}"
EOF
    chmod +x "${BLUEFIN_FIRSTBOOT}"
}

shadow() { printf 'root:%s:20000::::::\nnobody:!*:20000::::::\n' "$1" > "${BLUEFIN_SHADOW}"; }
answers() { printf '%s\n' "$@" > "${ANSWERS}"; }

@test "a password at the first prompt: asked once, stock" {
    answers pw
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(cat "${LOG}")" = "systemd-firstboot --prompt-root-password --mute-console=yes" ]
    [[ "${output}" != *"not accepted"* ]]
}

@test "an empty answer is asked again until root has a password" {
    answers empty empty pw
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${LOG}")" -eq 3 ]
    [ "$(sed -n 1p "${LOG}")" = "systemd-firstboot --prompt-root-password --mute-console=yes" ]
    # Root counts as configured after "!*": --force, and no welcome screen
    # that would clear the explanation.
    [ "$(sed -n 2p "${LOG}")" = "systemd-firstboot --force --welcome=no --prompt-root-password --mute-console=yes" ]
    [ "$(sed -n 3p "${LOG}")" = "systemd-firstboot --force --welcome=no --prompt-root-password --mute-console=yes" ]
    [ "$(grep -c 'would lock root for good, so it is not accepted here.' <<< "${output}")" -eq 2 ]
    grep -q '^root:\$y\$' "${BLUEFIN_SHADOW}"
}

@test "a first boot cut short after an empty answer asks again" {
    # Power lost after "!*" was written, before first-boot-complete.target:
    # stock firstboot then sees root as configured and skips.
    shadow '!*'
    answers skip pw
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${LOG}")" -eq 2 ]
    grep -q '^root:\$y\$' "${BLUEFIN_SHADOW}"
}

@test "root that already has a password is not asked again" {
    shadow '$y$j9T$earlier$hash'
    answers skip
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${LOG}")" -eq 1 ]
}

@test "a passwd credential answers once, as given, even a locked root" {
    for c in passwd.hashed-password.root passwd.plaintext-password.root; do
        rm -f "${CREDENTIALS_DIRECTORY}"/*
        : > "${LOG}"
        : > "${CREDENTIALS_DIRECTORY}/${c}"
        answers empty
        run bash "${SCRIPT}"
        [ "${status}" -eq 0 ]
        [ "$(cat "${LOG}")" = "systemd-firstboot --prompt-root-password --mute-console=yes" ]
    done
}

@test "systemd.firstboot=no turns the prompt off: one run, no loop" {
    printf 'quiet systemd.firstboot=no console=ttyS0\n' > "${BLUEFIN_CMDLINE}"
    answers skip
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${LOG}")" -eq 1 ]
}

@test "a failing systemd-firstboot fails the unit" {
    answers fail
    run bash "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [ "$(wc -l < "${LOG}")" -eq 1 ]
}

@test "it gives up instead of spinning when root never gets a password" {
    answers skip skip skip skip
    BLUEFIN_ROOT_PROMPT_TRIES=3 run bash "${SCRIPT}"
    [ "${status}" -eq 1 ]
    [ "$(wc -l < "${LOG}")" -eq 3 ]
    [[ "${output}" == *"giving up"* ]]
}

@test "only root's shadow entry counts" {
    printf 'nobody:$y$j9T$x$y:20000::::::\nroot:!*:20000::::::\n' > "${BLUEFIN_SHADOW}"
    answers skip pw
    run bash "${SCRIPT}"
    [ "${status}" -eq 0 ]
    [ "$(wc -l < "${LOG}")" -eq 2 ]
}
