# Methodology — running the OpenAI Codex CLI on armv7l

Why every choice in [`install.sh`](../install.sh) is what it is, what was
measured, and what is still open. Written so the next person (or the next model)
does not have to re-derive it.

## 1. The problem

`curl -fsSL https://chatgpt.com/codex/install.sh | sh` resolves a *vendor target*
from `uname -s` / `uname -m` and only knows `x86_64` and `aarch64` (plus the
Apple/Windows ones). On an armv7l board it stops immediately. OpenAI publishes no
32-bit ARM build — release `rust-v0.146.0` contains 170+ assets, none of them
`armv7`/`arm-unknown-linux-*`.

The board: Allwinner H3, 4× Cortex-A7 @ 1.2 GHz, 1 GB RAM, Armbian/Debian armhf,
SD-card storage.

## 2. Why emulation is the pragmatic path

The Linux aarch64 asset is a **statically linked musl Rust binary**:

```
$ file codex-aarch64-unknown-linux-musl
ELF 64-bit LSB executable, ARM aarch64, statically linked, stripped   (269 MB)
```

Static + no dynamic loader + no host libraries is the ideal shape for
**qemu user-mode**: one process, no sysroot to assemble. This is the same path
already in production on this hardware for the Grok CLI
([grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi)), where the
official binary has the same shape.

The alternative — compiling codex natively for `armv7-unknown-linux-gnueabihf` —
is genuinely possible (the source is public and Apache-2.0) but is a project of
its own, with real blockers. It is assessed separately in
[NATIVE-BUILD.md](NATIVE-BUILD.md).

## 3. Engine: the Yumi qemu fork by default, 7.2 as fallback

- QEMU **≥ 10 removed 64-bit-guest-on-32-bit-host** in linux-user. The last
  distro build that does it is **7.2** (Debian bookworm), vendored here in
  [`vendor/`](../vendor/) so no Debian pool URL can rot.
- 7.2's user mode **tears 64-bit accesses** between threads ("in user mode
  atomicity was simply broken"). The
  [Yumi fork of 9.2.4](https://github.com/Yumi-Lab/qemu-64on32-smartpi) routes
  every 64-bit guest access through a single-copy-atomic emission (inline
  LDRD/STRD on Cortex-A7 LPAE), backports the `termios2`/`TCGETS2` ioctls and
  makes the translation cache configurable.
- codex is a **tokio multithreaded runtime with a ratatui TUI**: shared 64-bit
  state across threads and termios ioctls are exactly the two things 7.2 gets
  wrong. On the Grok CLI, the same difference decided whether the native TUI ran
  at all. Hence: fork by default, `CODEX_QEMU=7.2` to fall back.
- **Translation cache**: user-mode qemu froze the TB cache at 32 MiB, which turns
  a large guest into a permanent `tb_flush` storm. The fork exposes
  `QEMU_TB_SIZE` (MiB); the wrapper sets **128** by default (`CODEX_TB_SIZE` to
  change). codex is 269 MB of code — this matters more here than for a 120 MB
  binary.

## 4. Sandboxing is off — and that is not laziness

codex sandboxes the commands it runs. On Linux that means Landlock + a seccomp
filter, or the bundled `bwrap`. None of it can work here:

- The seccomp filter is built for a fixed target architecture. Upstream
  ([`linux-sandbox/src/landlock.rs`](https://github.com/openai/codex/blob/main/codex-rs/linux-sandbox/src/landlock.rs)):

  ```rust
  if cfg!(target_arch = "x86_64") { TargetArch::x86_64 }
  else if cfg!(target_arch = "aarch64") { TargetArch::aarch64 }
  else { unimplemented!("unsupported architecture for seccomp filter") }
  ```

  The guest binary is aarch64, so it would emit an **aarch64 filter** — while the
  kernel enforcing it is **armv7**, where the syscall numbers are different. A
  filter written in the wrong numbering does not fail loudly, it denies (or
  allows) the wrong calls.
- `bwrap` and the re-exec'd `codex-linux-sandbox` helper are **aarch64
  binaries**: without a binfmt handler the kernel answers `ENOEXEC`.
- A *native* 32-bit build would not help: the same `unimplemented!` is what a
  `target_arch = "arm"` build hits.

So the installer writes, only when the user has no config yet:

```toml
sandbox_mode = "danger-full-access"
approval_policy = "untrusted"
```

Approvals become the safety net: codex asks before running a command. The
trade-off is stated in the README rather than hidden — never run this board with
both the sandbox off *and* approvals off.

`binfmt_misc` registration (root, optional, only if nothing else is registered)
covers the remaining case: any aarch64 helper codex still re-execs is loaded by
the kernel through the fork engine instead of failing.

## 5. Sizes, disk and memory

| Item | Size |
|---|---|
| `codex-aarch64-unknown-linux-musl.tar.gz` | 105 MB |
| unpacked binary | 269 MB |
| qemu fork | 35 MB |
| qemu 7.2 (vendored) | 7.6 MB |

Consequences baked into the installer:

- **≥ 700 MB free** is checked before anything is written (download + new binary
  + the previous one during an update). A half-written 269 MB binary on an SD
  card is a bad failure mode.
- Downloads go to **`/var/tmp`, never `/tmp`** — `/tmp` is a tmpfs on Armbian and
  a 105 MB download in RAM on a 1 GB board invites an OOM freeze.
- The tarball holds a single file, so it is **unpacked straight to its final
  path** (`tar -xzOf … > …`): staging it elsewhere would cost another 269 MB.
- `earlyoom` is installed when possible: with SD-card swap, memory exhaustion
  freezes the machine before the kernel OOM killer reacts.
- One emulated runtime at a time. The `codex` dispatcher warns when another
  `qemu-aarch64` is already running (`CODEX_SOLO=0` to mute).

Thermals: on this SoC a sustained 4-core emulated load has reached ~102 °C and
frozen the board (measured during the Grok work). `CODEX_CPUS=0,1` throttles
without reinstalling; watch `/sys/class/thermal/thermal_zone0/temp` on long runs.

## 6. Login without a browser

codex supports a device-code flow — the strings in the binary say it plainly:
*"On a remote or headless machine? Use `codex login --device-auth` instead."*
That is the documented path here; `printenv OPENAI_API_KEY | codex login
--with-api-key` is the API-key alternative (the old `--api-key <key>` flag was
removed upstream). Credentials land in `~/.codex/auth.json`.

## 7. OTA contract (shared by the Yumi-Lab `*-smartpi` repos)

- Re-running `install.sh` **is** the update. It exits fast when already newest.
- `codex-check-update` prints one JSON line, no sudo, no side effects — the Yumi
  AI Gateway polls it for the update badge and then re-runs `install.sh`.
- Version resolution and checksum lookup live in **one** file,
  [`lib/codex-release.sh`](../lib/codex-release.sh), installed next to the
  payload and sourced by the probe. Adding a mirror or changing an endpoint is a
  one-file change.
- Checksums come from the **published metadata** (`"digest": "sha256:…"`), not
  from a constant in this repo: nothing to bump when codex releases. Both
  metadata shapes are handled — releases.openai.com puts the digest right after
  the asset name, GitHub inserts a whole `uploader` object in between (there is a
  unit test for each).
- First install needs root; later updates only need to own `/opt/codex`, so the
  gateway service user updates without sudo. The `/usr/local/bin` wrappers are
  version-independent and rewritten only when their content changes.

## 8. Test strategy (what is proven, and by what)

| Layer | Command | Proves | Does not prove |
|---|---|---|---|
| Unit, offline | `test/unit.sh` | metadata parsing (both shapes), probe JSON contract, no hardcoded paths | anything about the board |
| Staging, x86_64 | `CODEX_ALLOW_ANY_ARCH=1 CODEX_OPT=… bash install.sh` | download, published-checksum verification, unpack, wrapper generation, idempotence, dry run | 32-bit behaviour |
| **Real armv7l userland** | `test/install-armv7-docker.sh` | the whole installer under a 32-bit libc/coreutils, `uname -m = armv7l`, no systemd, no binfmt, unprivileged degradation — **and that the emulated binary answers** | TUI stability, a real turn, thermals, RSS on the H3 |
| Pad | `test/pad-smoke.sh user@pad` | everything | — |

On an x86_64/aarch64 host the container's armv7 userland is itself driven by
`qemu-arm`, so the payload runs **nested**: our aarch64 qemu (an armv7 binary)
inside the host's arm qemu. That nesting was expected to be the weak point and
turned out to work — measured on an Apple Silicon host, Debian bookworm
`linux/arm/v7`, codex 0.146.0:

| Engine | `codex --version` |
|---|---|
| fork 9.2.4-yumi (default) | **9.9 s**, rc=0 |
| vendored qemu 7.2 | **6.4 s**, rc=0 |

and, going further than a version string:

| Exercise | Result |
|---|---|
| `codex --help` | full clap output, every subcommand listed |
| `codex exec "say hi"` in a git repo, no credentials | reaches the network: opens `wss://api.openai.com/v1/responses`, falls back to HTTPS, retries 5×, ends on the expected **401 Missing bearer** — so **rustls/aws-lc, DNS, TLS and WebSockets all work under emulation** |
| `codex login --device-auth` (under a pty) | prints the `auth.openai.com/codex/device` URL **and a one-time code** — the headless sign-in path works |
| RSS of the emulated process | **~83 MB** during a `--version` run |
| `CODEX_TB_SIZE` 32 / 128 / 256 | 18.3 s / 27.9 s / 7.9 s — **inconclusive**: nesting adds more noise than the effect. Measure on the pad (`test/pad-smoke.sh`) before changing the 128 MiB default. |

Two layers of emulation where the pad has one, on faster cores. This does not
predict TUI stability, a full agent turn or thermals — it does mean the binary,
its TLS stack and its login flow are not fundamentally incompatible with 64-on-32
user-mode emulation, which was the open risk before touching hardware. The smoke
test therefore runs by default in `test/install-armv7-docker.sh` (a timeout only
warns, unless `CODEX_SMOKE_STRICT=1`).

### Measured on the pad (Smart Pi One, DietPi / Debian 13 trixie, 2026-08-04)

Allwinner H3, 4× Cortex-A7, 991 MB RAM, SD card, codex 0.146.0 emulated:

| Exercise | Result |
|---|---|
| `install.sh` end to end (as root) | complete: qemu fork + 269 MB payload + wrappers + config, `binfmt_misc` registered, `earlyoom` active |
| `codex --version`, fork engine (default) | **2.33 s** |
| `codex --version`, qemu 7.2 | **1.99 s** |
| `CODEX_TB_SIZE` 32 / 128 / 256 | 2.29 / 2.29 / 2.29 s — no measurable effect on a short run; the 128 MiB default stands until a long agentic session says otherwise |
| `codex --help` | renders fully |
| `codex exec "say hi"`, no credentials | opens `wss://api.openai.com/v1/responses`, falls back to HTTPS, retries, ends on the expected **401 Missing bearer** — TLS, DNS and WebSockets all work through the emulator |
| `codex-check-update` | `{"cli":"codex","installed":"0.146.0","engine":"emulated","latest":"0.146.0","update_available":false}` |
| Disk footprint | `/opt/codex` = **297 MB** |
| Temperature | 39 °C idle, **44 °C** after the run sequence (throttling starts at 75 °C) |
| Memory | 146 MB used of 991 during the session |

### Native vs emulated, same board, same wrapper (2026-08-04)

The native armv7 binary built by this repo was installed next to the emulated one
(`CODEX_KEEP_EMULATION=1`) and both were run through the same `codex-bin`:

| | native armv7 | emulated aarch64 |
|---|---|---|
| `codex --version` | **0.084 s** | **2.40 s** (~29×) |
| `codex --help` | 3.1 s first run, then instant | ~3 s |
| `codex exec` with no credentials | reaches `api.openai.com`, expected 401 | same |
| `codex login --device-auth` | prints the URL and one-time code | same |
| Binary on disk | 211 MB | 269 MB (+ 35 MB emulator) |
| Shared libraries | libssl.so.3, libcrypto.so.3, libz, libgcc_s, libc, libm — all present on DietPi/trixie | none, static musl |
| Temperature | 41-46 °C | 42-46 °C |

Startup dominates short commands, which is where emulation costs the most; a long
agent turn is bound by the API, so the gap there will be smaller. The comparison
is one variable away on a board that has both: `CODEX_ENGINE=emulated codex …`.

Note the native binary tested here was built from `main` and therefore reports
`0.0.0`; a build from a release tag carries the real version.

Still to do by hand, in an interactive session on the board:

```bash
codex login --device-auth     # headless sign-in (validated in a container: prints URL + code)
codex                         # the TUI: does it render, does it stay stable over a long session?
codex exec "…"                # a real authenticated turn, watching the temperature
```

`test/pad-smoke.sh user@pad` runs the measured part again in one pass; add a
`-J jumphost` in `~/.ssh/config` when the board is behind a VPN.

### Open questions for the next session on the board

1. Does the **ratatui TUI** render and stay stable over a long session (this is
   where the Grok CLI needed the correct-atomics fork)?
2. Does a full authenticated `codex exec` turn survive — tool calls spawn native
   armv7 `/bin/bash` children through the emulator's `execve`?
3. Thermals on a sustained agentic run, 4 cores vs `CODEX_CPUS=0,1`.
4. Does `CODEX_TB_SIZE=256` pay for itself on a long session, where it did
   nothing on a short one?
