kind: manual
description: |
  Import and extract the Flatcar docker system extension (sysext).
  Provides the Docker CLI and containerd-based runtime, published by Flatcar as
  a rootfs-included sysext (projectbluefin/server#127). The raw squashfs is also
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
    url: flatcar:stable/%{flatcar-board}/%{flatcar-version}/rootfs-included-sysexts/docker-flatcar.raw
    ref: 5105dfe9cfb1357fce76e0297c0285e169b1eeb47fa6edd83d5bafe697c72662

config:
  install-commands:
    - |
      set -euo pipefail

      # Extract the SquashFS sysext directly into the element install root
      unsquashfs -no-xattrs -f -d "%{install-root}" docker-flatcar.raw

      # Also preserve the raw sysext image under /usr/lib/sysexts for runtime sysext usage
      mkdir -p "%{install-root}/usr/lib/sysexts"
      install -D -m 0644 docker-flatcar.raw "%{install-root}/usr/lib/sysexts/docker.raw"
