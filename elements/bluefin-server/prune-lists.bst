kind: import
description: |
  Reviewed prune lists and their applier (files/prune/), staged at /prune by
  oci/bluefin-server-usr.bst and oci/bluefin-server-boot.bst. Build-time
  only; nothing here ships in an image.

sources:
- kind: local
  path: files/prune
