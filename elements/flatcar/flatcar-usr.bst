kind: manual
description: |
  Import the Flatcar LTS `/usr` as the Bluefin Server OS payload base.

  Replaces the FSDK 26.08 base userspace (systemd, glibc, bash, coreutils,
  dbus, systemd-sysext) with a single-ABI Flatcar `/usr` that shares the
  vermagic, glibc, and systemd of the Flatcar LTS kernel imported by
  flatcar-kernel.bst and flatcar-zfs.bst. The installer keeps its own FSDK
  userspace (see installer/installer-stack.bst); only the installed OS DDI
  lands on this base.

  Mirrors flatcar-zfs.bst's import pattern: a single pinned, digest-verified
  remote source, prebuilt binaries, no rebuild from source.

(@):
  - include/arch.yml
  - include/flatcar.yml

build-depends:
  - base/base-stack.bst
  - freedesktop-sdk.bst:components/tar.bst
  - freedesktop-sdk.bst:components/gzip.bst
  - freedesktop-sdk.bst:components/xz.bst
  - freedesktop-sdk.bst:components/findutils.bst
  - freedesktop-sdk.bst:components/coreutils.bst
  - freedesktop-sdk.bst:components/squashfs-tools.bst

variables:
  # Prebuilt binaries: the FSDK stripper must not touch Flatcar's trees.
  strip-binaries: ""

sources:
  # Complete OS tree: /usr (19,658 entries), /boot, /oem. Carries .DIGESTS,
  # .DIGESTS.asc, and .sig companions for independent GPG verification.
  - kind: remote
    url: flatcar:stable/%{flatcar-board}/%{flatcar-version}/flatcar-container.tar.gz
    ref: c533ff576e128d11ce240e01f818c358d75b9ff118b2dd9199fbf4684547a32c

config:
  install-commands:
    - |
      set -euo pipefail

      # Extract the complete Flatcar /usr into the element install root.
      tar -xzf flatcar-container.tar.gz -C "%{install-root}" ./usr

      # --- Remove Flatcar's update + provisioning stack ---------------------
      # Bluefin Server stays on systemd-sysupdate + Kured (design non-goal),
      # so these upstream units are dropped rather than masked. Each rm names
      # its replacement so a Flatcar bump that reintroduces a different tool
      # fails loudly instead of silently regressing the update path.
      rm -rf "%{install-root}/usr/bin/update_engine" \
             "%{install-root}/usr/bin/update_engine_client" \
             "%{install-root}/usr/lib/systemd/system/update_engine.service" \
             "%{install-root}/usr/lib/systemd/system/update_timer.service" \
             "%{install-root}/usr/bin/locksmithd" \
             "%{install-root}/usr/bin/ignition" \
             "%{install-root}/usr/bin/coreos-cloudinit" \
             "%{install-root}/usr/bin/flatcar-update" \
             "%{install-root}/usr/bin/download_sysext" \
             "%{install-root}/usr/lib/systemd/system/ensure-sysext.service"

      # --- Flatten Flatcar's nested module directory ------------------------
      # Flatcar nests modules at usr/lib/modules/<kver>/<kver>/. The rest of
      # this tree (flatcar-kernel.bst, dracut, dracut/depmod) expects the
      # single-level usr/lib/modules/<kver>/ layout, so collapse one level.
      KVER="%{flatcar-kver}"
      if [ -d "%{install-root}/usr/lib/modules/${KVER}/${KVER}" ]; then
        mv "%{install-root}/usr/lib/modules/${KVER}/${KVER}" \
           "%{install-root}/usr/lib/modules/${KVER}.flatcar-nested"
        find "%{install-root}/usr/lib/modules/${KVER}.flatcar-nested" \
             -mindepth 1 -maxdepth 1 -exec mv -t "%{install-root}/usr/lib/modules/${KVER}" {} +
        rmdir "%{install-root}/usr/lib/modules/${KVER}.flatcar-nested"
      fi

      # --- Stage the raw sysext images for runtime sysext usage -------------
      # Preserves Flatcar's prebuilt ZFS / Podman / containerd / docker
      # squashfs sysexts under /usr/lib/sysexts, mirroring flatcar-zfs.bst.
      mkdir -p "%{install-root}/usr/lib/sysexts"
      for name in flatcar-zfs flatcar-podman containerd-flatcar docker-flatcar; do
        if [ -e "${name}.raw" ]; then
          install -D -m 0644 "${name}.raw" "%{install-root}/usr/lib/sysexts/${name}.raw"
        fi
      done
