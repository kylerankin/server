kind: manual
description: |
  Import and extract the Flatcar containerd system extension (sysext).
  Provides the containerd runtime and CLI, published by Flatcar as a
  rootfs-included sysext (projectbluefin/server#127). The raw squashfs is also
  staged under /usr/lib/sysexts so systemd-sysext attaches it at runtime.

(@):
  - include/arch.yml
  - include/flatcar.yml

build-depends:
  - base/base-stack.bst
  - freedesktop-sdk.bst:components/squashfs-tools.bst

variables:
  strip-binaries: ""

sources:
  - kind: remote
    url: flatcar:stable/%{flatcar-board}/%{flatcar-version}/rootfs-included-sysexts/containerd-flatcar.raw
    ref: 78e38344ac490004b9fa4c7da38bbfcffc393146aa990379aff7b5c09589f809

config:
  install-commands:
    - |
      set -euo pipefail

      # Extract the SquashFS sysext directly into the element install root
      unsquashfs -no-xattrs -f -d "%{install-root}" containerd-flatcar.raw

      # Also preserve the raw sysext image under /usr/lib/sysexts for runtime sysext usage
      mkdir -p "%{install-root}/usr/lib/sysexts"
      install -D -m 0644 containerd-flatcar.raw "%{install-root}/usr/lib/sysexts/containerd.raw"
