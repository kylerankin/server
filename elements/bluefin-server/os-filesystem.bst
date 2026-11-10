kind: compose
description: |
  Integrated OS tree (os-stack minus debug/devel/doc/locale/tests) for the
  /usr image. The locale domain is message catalogs and locale sources; the
  compiled C.UTF-8 and en_US.UTF-8 locales in /usr/lib/locale stay, and no
  other locale is compiled, so the catalogs could never load.

build-depends:
- bluefin-server/os-stack.bst

config:
  exclude:
  - debug
  - devel
  - doc
  - locale
  - tests
  include-orphans: True
  # Ships a shell; integration builds the ld.so cache and hwdb.
  integrate: True
