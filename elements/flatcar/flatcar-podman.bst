kind: manual
description: |
  Import and extract the Flatcar podman system extension (sysext).
  Provides the podman container CLI, replacing the FSDK podman component in the
  OS payload (projectbluefin/server#127, hard rule 4: no container runtime in
  the base DDI). The raw squashfs is also staged under /usr/lib/sysexts so
  systemd-sysext attaches it at runtime on a booted image.

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
    url: flatcar:stable/%{flatcar-board}/%{flatcar-version}/flatcar-podman.raw
    ref: bc8c6777ab9dee286eb1f70a1605a880fcc5199246d87f9c92f00d880194d72b

config:
  install-commands:
    - |
      set -euo pipefail

      # Extract the SquashFS sysext directly into the element install root
      unsquashfs -no-xattrs -f -d "%{install-root}" flatcar-podman.raw

      # Also preserve the raw sysext image under /usr/lib/sysexts for runtime sysext usage
      mkdir -p "%{install-root}/usr/lib/sysexts"
      install -D -m 0644 flatcar-podman.raw "%{install-root}/usr/lib/sysexts/podman.raw"
