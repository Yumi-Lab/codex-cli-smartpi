# vendor/qemu-aarch64-static

QEMU user-mode emulator used to run the (aarch64) codex binary on an armv7l host.
It is the **fallback** engine — the default is the Yumi fork of 9.2.4, downloaded
at install time from
[qemu-64on32-smartpi](https://github.com/Yumi-Lab/qemu-64on32-smartpi/releases).

- **Version**: 7.2+dfsg-7+deb12u18+b3 (Debian 12 "bookworm", armhf)
- **sha256**: `a26fb51967c49bd100d8d9f4865f643c1a7084cc60de583cde55ac33c62f30a6`
  (verified by `install.sh` at every run)
- **Origin**: extracted unmodified from the official
  [`qemu-user-static`](https://packages.debian.org/bookworm/qemu-user-static)
  package (`dpkg-deb -x qemu-user-static_7.2+dfsg-7+deb12u18+b3_armhf.deb`)
- **License**: GPL-2.0 — full sources available from Debian:
  <https://packages.debian.org/source/bookworm/qemu>
- **Why this version**: it is the last QEMU generation whose linux-user mode
  accepts a 64-bit guest on a 32-bit host (support removed in QEMU 10 / Debian
  trixie). 8.2 and 9.2 stock builds behave worse for this use case; the fork that
  fixes 9.2.4's torn 64-bit accesses is what runs by default. See
  [../docs/METHODOLOGY.md](../docs/METHODOLOGY.md).

The file is vendored because Debian pool URLs change with every point release
(the exact `.deb` eventually disappears from the main mirror), and a board that
cannot reach a Debian mirror must still be able to install.
