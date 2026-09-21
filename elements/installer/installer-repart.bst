kind: import
description: |
  Installs the repart.d partition definitions into /usr/lib/repart.d/ inside
  the live installer environment. When the installer runs
  "systemd-repart --dry-run=no DEVICE", it reads these configs to know how
  to partition and populate the TARGET disk.

  Partition layout:
    10-esp.conf          EFI System Partition (vfat, 500M–1G)
    20-usr-a.conf        Read-only /usr slot A — OS /usr DDI copied here
    30-usr-b.conf        Read-only /usr slot B — spare, empty (A/B + verity later)
    40-oem.conf          OEM — ext4, cloud-metadata / Ignition (label OEM)
    50-root.conf         Writable root — grows to fill disk, seeds k0s sysext

sources:
  - kind: local
    path: files/installer/repart.d

config:
  target: /usr/lib/repart.d
