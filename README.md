# Codex CLI for Yumi Smart Pi One (32-bit ARM)

The **official OpenAI Codex CLI** on **Allwinner H3 / armv7l** (Smart Pi One, Yumi
SmartPad) — hardware the official installer rejects, because OpenAI ships codex
for x86_64 and aarch64 only.

Two ways to get it running on the board, and the installer picks for you:

- **native** — this project cross-compiles the Apache-2.0 source for armv7 and
  publishes the binary. No emulator. `codex --version` in **0.084 s** on the pad.
- **emulated** — the official aarch64 binary under 64-on-32 qemu, available the
  day upstream ships. Same command, **2.40 s**.

Sign in with a **ChatGPT Plus/Pro/Business account** (device code, no browser on
the board) or an API key. One command installs everything, and the same command
is the updater.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/codex-cli-smartpi/main/install.sh | bash
```

Then sign in — the board never needs a browser:

```bash
codex login --device-auth        # open the URL on any machine, type the code
printenv OPENAI_API_KEY | codex login --with-api-key    # or use an API key
```

`CODEX_VERSION=x.y.z` pins a version, `CODEX_FORCE=1` reinstalls anyway.

## Usage

| Command | Purpose |
|---|---|
| `codex` | Interactive TUI |
| `codex exec "task"` | One-shot, non-interactive (scripts, the gateway, cron) |
| `codex exec --dangerously-bypass-approvals-and-sandbox "task"` | Unattended: no prompt, no sandbox. The only flavour that runs without a human here — **do not** use `--full-auto`, it asks for a sandbox this kernel cannot give (see below). Run it in a directory you control. |
| `codex-check-update` | OTA probe: `{"cli","installed","engine","latest","update_available"}` |
| `codex-bin …` | The wrapper without the dispatcher's co-tenancy warning |

Environment knobs, no reinstall needed:

| Variable | Effect |
|---|---|
| `CODEX_ENGINE=native\|emulated\|auto` | Which payload to install (default `auto`), and which one to run when both are present |
| `CODEX_CPUS=0,1` | Thermal throttle — default is all 4 cores, both engines |
| `CODEX_QEMU=7.2` | Fall back to the vendored qemu 7.2 engine (emulated only) |
| `CODEX_TB_SIZE=256` | Translation-cache size in MiB (default 128, fork engine only) |
| `CODEX_KEEP_EMULATION=1` | Install the emulated payload next to the native one |
| `CODEX_NATIVE_TARBALL=<path\|url>` | Install a native build from a snapshot release, or one you built yourself |
| `CODEX_SOLO=0` | Silence the "another emulated runtime is running" warning |

⚠️ **Never run** `codex update` or the upstream installer on this board — both
would drop a 64-bit binary outside the wrapper. Re-run `install.sh`.

## Which engine you get

`install.sh` asks the releases of this repo whether a native armv7 build exists
for the version it resolved. If it does, it installs that and **downloads no
emulator at all**. Otherwise it falls back to emulation. `codex-check-update`
reports which one is in use.

Whether a codex version *can* be built for armv7 comes down to one thing: whether
the CLI links **V8**, which has no armv7 build. At the current release it does,
so the board runs emulated today — and upstream has already moved v8 out of the
CLI's dependency graph on `main`, so the next release will be built and published
automatically. The whole story: [docs/NATIVE-BUILD.md](docs/NATIVE-BUILD.md).

Meanwhile the newest native binary is published as a **snapshot prerelease**
built from `main`. Install it explicitly — one minute end to end on the board:

```bash
curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/codex-cli-smartpi/main/install.sh | \
  CODEX_NATIVE_TARBALL=<url of the snapshot .tar.gz> bash
```

The URL is on the [releases page](https://github.com/Yumi-Lab/codex-cli-smartpi/releases)
and the checksum beside it is verified during the install. A snapshot reports
version `0.0.0` (upstream stamps versions only when it tags) and `install.sh`
never picks one up on its own.

## What the emulated path does

1. The official binary is **static Rust (musl, aarch64)**, 269 MB — the shape
   that emulates well in user mode.
2. QEMU dropped "64-bit guest on a 32-bit host" in version 10, so two engines are
   installed: the **[Yumi qemu fork 9.2.4](https://github.com/Yumi-Lab/qemu-64on32-smartpi)**
   (default — restores *correct* single-copy-atomic 64-bit accesses on Cortex-A7,
   which a tokio-based Rust app needs, plus a sizeable translation cache) and
   **qemu-aarch64-static 7.2** from Debian bookworm (vendored in
   [`vendor/`](vendor/), reachable with `CODEX_QEMU=7.2`).
3. A wrapper runs it at low priority on all 4 cores. Watch thermals on long
   agentic runs: this SoC has reached ~102 °C under a sustained 4-core emulated
   load and frozen — `CODEX_CPUS=0,1` throttles it. `earlyoom` is installed as
   the memory safety net, and the rule on 1 GB is **one heavy CLI at a time**.
4. Optional, root only: an `aarch64` **binfmt_misc** handler pointing at the fork
   engine, so any aarch64 helper codex re-execs is loaded instead of failing with
   `ENOEXEC` (`echo -1 > /proc/sys/fs/binfmt_misc/qemu-aarch64-yumi` removes it).

## Sandboxing is off — read this once

`~/.codex/config.toml` is created, only if you have none, with:

```toml
sandbox_mode = "danger-full-access"
approval_policy = "untrusted"
```

**This is a real trade-off, not a shortcut.** Codex's Linux sandbox cannot work
on this board: the seccomp filter it builds exists for x86_64 and aarch64 only
(upstream's [`landlock.rs`](https://github.com/openai/codex/blob/main/codex-rs/linux-sandbox/src/landlock.rs)
ends in `unimplemented!()` for anything else), and `bwrap` and the re-exec'd
`codex-linux-sandbox` are 64-bit binaries. A native armv7 build hits the same
wall. **Approvals are therefore the safety net** — codex asks before running a
command. Never leave both the sandbox off *and* approvals off on a board exposed
to the network.

## Updating (OTA)

- **Check:** `codex-check-update` prints one JSON line — the probe the [Yumi AI
  Gateway](https://github.com/Yumi-Lab/yumi-ai-gateway) console polls for its
  update badge. `--latest` / `--installed` / `--engine` print a single value.
- **Update:** re-run `install.sh` — that IS the updater. It exits fast when
  already newest, verifies the **published sha256**, and keeps the previous
  binary until the new one is in place.
- **Automatic upstream tracking:** a daily GitHub Actions cron compares upstream
  against the releases here and builds + publishes the armv7 binary when a new
  version lands. Nothing to bump anywhere; a version that cannot be built for
  armv7 is reported as a skip, not a failure.
- **Privileges:** root/sudo for the *first* install only. Updates run as any user
  that owns `/opt/codex`, so the gateway service user updates without sudo.

## Requirements

armv7l board, Debian/Armbian bookworm or newer, ≥ 1 GB RAM, `curl` and `tar`.
Disk: **≈ 300 MB** for the native payload (211 MB binary, no emulator),
**≥ 700 MB** for the emulated one (269 MB binary + 105 MB download + the previous
version during an update) — the installer checks before touching anything. The
native build is dynamically linked and needs `libssl.so.3`, `libcrypto.so.3`,
`libz` and `libgcc_s`, present by default on Debian bookworm/trixie and DietPi.

## Status

Validated on a real Smart Pi One (DietPi / Debian 13 trixie, 2026-08-04):

| | native armv7 | emulated aarch64 |
|---|---|---|
| `codex --version` | **0.084 s** | **2.40 s** |
| `codex exec`, no credentials | reaches `api.openai.com` over TLS + WebSockets, expected 401 | same |
| `codex login --device-auth` | prints URL + one-time code | same |
| On disk | 211 MB | 269 MB + 35 MB emulator |
| Temperature | 41-46 °C | 42-46 °C |

Also green: the cross-build pipeline (~47 min on a runner, 85 MB tarball), the
daily watcher, and CI on every push — unit tests, a staged install on x86_64, and
a full install **plus emulated smoke test** inside a real armv7l userland.

Not yet exercised on the board: the TUI over a long session, an authenticated
agent turn, thermals under sustained load. `test/pad-smoke.sh user@pad` collects
the measurable part in one pass.

Full reasoning, measurements and dead ends: [docs/METHODOLOGY.md](docs/METHODOLOGY.md).

## Development / CI

No board needed — [`.github/workflows/ci.yml`](.github/workflows/ci.yml) runs all
of this on every push:

```bash
test/unit.sh                  # offline: metadata parsing, OTA probe, no hardcoded paths
test/install-armv7-docker.sh  # full install + emulated smoke in a real armv7l userland
CODEX_DRY_RUN=1 bash install.sh              # resolve everything, write nothing
CODEX_OPT=/tmp/opt CODEX_BINDIR=/tmp/bin …   # relocate the install, no root required
```

The native binary is built by [`build/cross-armv7.sh`](build/cross-armv7.sh),
reproducible anywhere with Docker:

```bash
docker run --rm -v "$PWD:/repo" -w /repo rust:bookworm bash build/cross-armv7.sh
```

## Sister projects (same board, other CLIs)

- [claude-code-smartpi](https://github.com/Yumi-Lab/claude-code-smartpi) — official Anthropic Claude Code, native.
- [grok-cli-smartpi](https://github.com/Yumi-Lab/grok-cli-smartpi) — official xAI Grok CLI, same 64-on-32 emulation path.
- [kimi-cli-smartpi](https://github.com/Yumi-Lab/kimi-cli-smartpi) / [kimi-code-smartpi](https://github.com/Yumi-Lab/kimi-code-smartpi) — Moonshot CLIs, native.
- [vibe-cli-smartpi](https://github.com/Yumi-Lab/vibe-cli-smartpi) — official Mistral Vibe CLI, native.
- [qemu-64on32-smartpi](https://github.com/Yumi-Lab/qemu-64on32-smartpi) — the qemu fork the emulated CLIs run on.

## Licensing

- Scripts in this repo: MIT (Yumi Lab)
- `vendor/qemu-aarch64-static`: GPL-2.0, extracted as-is from the Debian bookworm
  package ([vendor/README.md](vendor/README.md))
- Codex itself is Apache-2.0 ([openai/codex](https://github.com/openai/codex)).
  The official binary is downloaded from OpenAI at install time, not
  redistributed here; the native binary is built from that same public source.
