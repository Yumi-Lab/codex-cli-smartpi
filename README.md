# Codex CLI for Yumi Smart Pi One (32-bit ARM)

The **official OpenAI Codex CLI** on **Allwinner H3 / armv7l** (Smart Pi One, Yumi
SmartPad) — hardware the official installer rejects: OpenAI ships codex for
x86_64 and aarch64 only.

Sign in with a **ChatGPT Plus/Pro/Business account** (device code, no browser on
the pad) or with an API key. One command installs everything, and the same
command is the updater.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/codex-cli-smartpi/main/install.sh | bash
```

Pin a version instead of the newest:

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/codex-cli-smartpi/main/install.sh | CODEX_VERSION=0.146.0 bash
```

Then sign in (headless — the pad never needs a browser):

```bash
codex login --device-auth        # open the URL on any machine, type the code
printenv OPENAI_API_KEY | codex login --with-api-key    # or use an API key
```

## Usage

| Command | Purpose |
|---|---|
| `codex` | Interactive TUI |
| `codex exec "task"` | One-shot, non-interactive (scripts, the gateway, cron) |
| `codex exec --dangerously-bypass-approvals-and-sandbox "task"` | Unattended: no prompt, no sandbox. The only flavour that runs without a human on this board — **do not** use `--full-auto` here, it asks for a sandbox the kernel cannot give (see below). Run it in a directory you control. |
| `codex --version` | Sanity check |
| `codex-check-update` | `{"cli":"codex","installed":…,"latest":…,"update_available":…}` |
| `codex-bin …` | The wrapper without the dispatcher's co-tenancy warning |

Environment knobs (no reinstall needed):

| Variable | Effect |
|---|---|
| `CODEX_ENGINE=native\|emulated\|auto` | Which payload to install (default `auto`), and at run time which one to use when both are present |
| `CODEX_CPUS=0,1` | Thermal throttle — default is all 4 cores, both engines |
| `CODEX_QEMU=7.2` | Fall back to the vendored qemu 7.2 engine (emulated only) |
| `CODEX_TB_SIZE=256` | Translation-cache size in MiB (default 128, fork engine only) |
| `CODEX_SOLO=0` | Silence the "another emulated runtime is running" warning |
| `CODEX_VERSION` / `CODEX_FORCE` | Pin a version / reinstall even when up to date |
| `CODEX_KEEP_EMULATION=1` | Install the emulated payload next to the native one (install time) |
| `CODEX_NATIVE_TARBALL=<path\|url>` | Install a native build you produced yourself with `build/cross-armv7.sh` |

⚠️ **Never run** `codex update` or the upstream installer on this board — both
would drop an aarch64 binary outside the qemu wrapper. Re-run `install.sh`.

## How it works

0. **Native first.** When a release of this repo carries an armv7 build for the
   resolved version, that binary is installed and nothing below applies — no
   emulator is even downloaded. Everything from here on describes the emulated
   fallback, which is what runs when upstream's version cannot be built for
   armv7 (see [docs/NATIVE-BUILD.md](docs/NATIVE-BUILD.md)).
1. The official codex binary is **static Rust (musl, aarch64)** — 269 MB, no
   dynamic linking, exactly the shape that emulates well in user mode.
2. QEMU removed "64-bit guest on a 32-bit host" in version 10, so two engines
   are installed: the **[Yumi qemu fork 9.2.4](https://github.com/Yumi-Lab/qemu-64on32-smartpi)**
   (default — restores *correct* single-copy-atomic 64-bit accesses on
   Cortex-A7, which is what a tokio-based multithreaded Rust app needs, plus a
   sizeable translation cache) and **qemu-aarch64-static 7.2 from Debian
   bookworm** (vendored in [`vendor/`](vendor/), reachable with `CODEX_QEMU=7.2`).
3. A wrapper runs the emulation at low priority on all 4 cores. Watch thermals
   on long agentic runs: on this SoC a 4-core emulated load has reached ~102 °C
   and frozen the board — `CODEX_CPUS=0,1` throttles it. `earlyoom` (installed
   too) is the memory safety net; on 1 GB with SD-card swap, memory exhaustion
   freezes the machine before the kernel OOM killer reacts.
4. `~/.codex/config.toml` is created (only if you have none) with
   `sandbox_mode = "danger-full-access"` and `approval_policy = "untrusted"`.
   **This is a real trade-off**: codex's Linux sandbox cannot work here — the
   seccomp filter it installs is written in aarch64 syscall numbers while the
   kernel is armv7, and both the bundled `bwrap` and the re-exec'd
   `codex-linux-sandbox` helper are aarch64 binaries. Upstream does not support
   32-bit ARM sandboxing either ([`linux-sandbox/src/landlock.rs`](https://github.com/openai/codex/blob/main/codex-rs/linux-sandbox/src/landlock.rs)
   only knows x86_64 and aarch64). Approvals are therefore the safety net:
   codex asks before running a command. Keep it that way on a board you expose
   to the network.
5. Optional, root only: an `aarch64` **binfmt_misc** handler pointing at the fork
   engine, so any aarch64 helper codex re-execs is loaded by the kernel instead
   of failing with `ENOEXEC` (`echo -1 > /proc/sys/fs/binfmt_misc/qemu-aarch64-yumi`
   to remove it; a `codex-binfmt.service` re-registers it at boot).

Full reasoning, measurements and dead ends: [docs/METHODOLOGY.md](docs/METHODOLOGY.md).
Native (emulation-free) armv7 build assessment: [docs/NATIVE-BUILD.md](docs/NATIVE-BUILD.md).

## Updating (OTA)

- **Check:** `codex-check-update` prints one JSON line — the probe the [Yumi AI
  Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway) console polls for its
  update badge. `--latest` / `--installed` print a single version.
- **Update:** re-run `install.sh` — that IS the updater. It exits fast when
  already newest, verifies the **published sha256** of the download, and keeps
  the previous binary until the new one is in place.
- **Privileges:** root/sudo for the *first* install only. Updates run as any
  user that owns `/opt/codex` — the gateway service user updates without sudo
  (the `/usr/local/bin` wrappers are version-independent and only rewritten when
  their content actually changes).

## Requirements

armv7l board, Debian/Armbian bookworm or newer, ≥ 1 GB RAM, `curl` and `tar`.
Disk: **≥ 700 MB free** for the emulated payload (269 MB binary + 105 MB download
+ the previous version during an update), **≈ 300 MB** for the native one
(211 MB binary, no emulator). The installer checks free space before touching
anything. The native build is dynamically linked and needs `libssl.so.3`,
`libcrypto.so.3`, `libz` and `libgcc_s` from the distribution — present by
default on Debian bookworm/trixie and DietPi.

## Development / CI

The installer is testable without a pad — [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
runs all of this on every push:

```bash
test/unit.sh                  # offline: metadata parsing, OTA probe, no hardcoded paths
test/install-armv7-docker.sh  # full install + emulated smoke in a real armv7l userland
test/pad-smoke.sh pi@pad      # on-device: timings per engine, cache sizing, RSS, thermals
CODEX_ALLOW_ANY_ARCH=1 CODEX_OPT=/tmp/opt CODEX_BINDIR=/tmp/bin CODEX_SMOKE=0 bash install.sh
CODEX_DRY_RUN=1 bash install.sh   # resolve everything, write nothing
```

`CODEX_OPT` / `CODEX_BINDIR` relocate the whole install, so nothing needs root
and a runner can assert the resulting layout.

## Two engines: native or emulated

| | native | emulated |
|---|---|---|
| What runs | the armv7 binary **this repo builds** from the Apache-2.0 source | the official aarch64 musl binary under 64-on-32 qemu |
| Availability | when a release of this repo carries an armv7 asset for that version | always, the day upstream ships |
| Chosen by | `CODEX_ENGINE=auto` (default) — native if published, else emulated | `CODEX_ENGINE=emulated` forces it |

`install.sh` asks the releases of this repo whether a native build exists for the
version it resolved. If it does, it installs it and **downloads no emulator at
all**; `CODEX_KEEP_EMULATION=1` installs both so the two can be compared on one
board. `codex-check-update` reports which one is in use.

The native track is built by [`build/cross-armv7.sh`](build/cross-armv7.sh) in CI
and a daily cron watches upstream, so a new codex release becomes an armv7 asset
without anyone bumping a version anywhere. Whether a given codex version *can* be
built for armv7 depends on one thing — whether the CLI links V8 — and that story
is in [docs/NATIVE-BUILD.md](docs/NATIVE-BUILD.md).

## Status

- ✅ **Validated on the real board** (Smart Pi One, DietPi/trixie, 2026-08-04):
  `install.sh` end to end as root, `codex --version` in **2.3 s** on the fork
  engine (2.0 s on qemu 7.2), `--help` rendering, `codex exec` reaching
  `api.openai.com` over TLS + WebSockets and ending on the expected 401 without
  credentials, `codex-check-update` answering, 297 MB on the SD card, 44 °C.
  Numbers in [docs/METHODOLOGY.md](docs/METHODOLOGY.md).
- ✅ Installer validated in CI on every push: unit tests, a staged install on an
  x86_64 runner, and a full install **plus emulated smoke test** inside a real
  armv7l userland.
- ✅ **The native armv7 build works — and it is ~29× faster to start on the
  board**: `codex --version` in **0.084 s** native against **2.40 s** emulated,
  same pad, same wrapper. Built in ~47 min on a runner (85 MB tarball),
  installed through `install.sh` with `CODEX_NATIVE_TARBALL`, `codex exec` and
  `codex login --device-auth` both reaching OpenAI over TLS. Pipeline complete
  (toolchain, armhf multiarch, the `pagable` and `linux-sandbox` 32-bit patches,
  release publishing, daily watcher).
- ⏳ codex **0.146.0 cannot be built natively** — it links V8 into the CLI and
  there is no armv7 V8. Upstream already moved v8 out of `code-mode` on `main`,
  so the first release carrying that change will be built and published
  automatically, and `install.sh` will switch to it on its own.
- ⏳ Not yet exercised on the board: the TUI over a long session, an
  authenticated agent turn, thermals under sustained load.

## Sister projects (same board, other CLIs)

- [claude-code-smartpi](https://github.com/Yumi-Lab/claude-code-smartpi) — official Anthropic Claude Code, native.
- [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi) — official xAI Grok CLI, same 64-on-32 emulation path.
- [kimi-cli-smartpi](https://github.com/Yumi-Lab/kimi-cli-smartpi) / [kimi-code-smartpi](https://github.com/Yumi-Lab/kimi-code-smartpi) — Moonshot CLIs, native.
- [vibe-cli-smartpi](https://github.com/Yumi-Lab/vibe-cli-smartpi) — official Mistral Vibe CLI, native.
- [qemu-64on32-smartpi](https://github.com/Yumi-Lab/qemu-64on32-smartpi) — the qemu fork both emulated CLIs run on.

## Licensing

- Scripts in this repo: MIT (Yumi Lab)
- `vendor/qemu-aarch64-static`: GPL-2.0, extracted as-is from the Debian bookworm
  package (provenance: [vendor/README.md](vendor/README.md))
- The codex binary is downloaded at install time from OpenAI's official release
  channel (it is not redistributed here). Codex itself is Apache-2.0:
  [openai/codex](https://github.com/openai/codex)
