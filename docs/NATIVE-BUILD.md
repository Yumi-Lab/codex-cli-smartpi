# The native armv7 track — building codex from source for the pad

OpenAI ships codex for x86_64 and aarch64 only. This repo therefore builds the
Apache-2.0 source itself for `armv7-unknown-linux-gnueabihf` and publishes the
binary as a release, so the pad can run a **native** CLI with no emulator in the
picture. [`build/cross-armv7.sh`](../build/cross-armv7.sh) is the whole recipe;
[`.github/workflows/native-armv7.yml`](../.github/workflows/native-armv7.yml)
runs it and publishes, and
[`watch-upstream.yml`](../.github/workflows/watch-upstream.yml) checks once a day
whether upstream shipped a version we have not built yet.

Reproduce it anywhere with Docker — the CI job runs this exact command:

```bash
docker run --rm -v "$PWD:/repo" -w /repo rust:bookworm bash build/cross-armv7.sh
```

## What the source actually is

Full Rust workspace, ~150 crates, toolchain pinned to 1.95.0
(`codex-rs/rust-toolchain.toml`), Apache-2.0. **Nothing to decompile and no
embedded interpreter**: the only web-ish assets are static HTML/CSS strings
(`login/src/assets/*.html`, `tui/src/inline_visualization/assets/*`) — those are
the `--primary-foreground` / `--radius-lg` CSS variables one finds with
`strings`, a stylesheet, not an application.

## The blockers, in the order the build hits them

Every one of these was found by running the build, not by reading tea leaves.

**1. `rustup target add` on the wrong toolchain.** codex pins its own toolchain
in the source tree, so adding the target from our checkout installs std for the
runner's default toolchain and the first crate dies with *"can't find crate for
`core`"*. The target is added from inside the source tree.

**2. `openssl-sys` and `libz-sys` need real armhf libraries.** Not vendored in
this dependency graph, so the build runs in **Debian** (armhf lives in the same
mirror): `dpkg --add-architecture armhf` plus `libssl-dev:armhf`,
`zlib1g-dev:armhf`, and `PKG_CONFIG_LIBDIR` pointed at the armhf `.pc` files so
`-sys` crates do not link the amd64 ones. `aws-lc-sys`, the one everybody expects
to be the problem, cross-compiles fine with cmake + a C++ cross compiler +
libclang.

**3. `pagable 0.4.1` refuses to compile on 32-bit ARM.** Pulled in by `starlark`
(the exec-policy engine). It carries

```rust
#[cfg(target_pointer_width = "32")]
static_assertions::assert_eq_size!(PagableArcInner<[usize; 4]>, [usize; 12]);
```

calibrated on wasm32; on armv7 the same struct packs into 10 usizes and the
build stops. It is a size canary, not a layout invariant — nothing computes
offsets from it — so [`patches/crates/pagable-0.4.1.patch`](../patches/crates/pagable-0.4.1.patch)
keeps the assertion on wasm32 and drops it elsewhere. Patches are applied to the
**extracted registry source**, never through `[patch.crates-io]`: a patch entry
makes cargo re-resolve the whole graph, and a re-resolved graph is not the one
upstream tested (see below).

**4. The workspace patches a dependency over `ssh://git@github.com`.** Without an
SSH key cargo cannot resolve it and re-resolves everything; the build script
rewrites ssh→https so the lockfile resolves as written.

**5. V8 — the one that decides everything.** At **rust-v0.146.0**,
`code-mode/Cargo.toml` has `v8 = { workspace = true }`, and `code-mode` is in the
CLI's dependency graph (`codex-cli → codex-exec → codex-app-server →
codex-code-mode`). The `v8` crate's build script downloads a prebuilt V8 and
there is **no armv7 flavour** — it 404s. Building V8 for 32-bit ARM from source
is not a realistic option.

Upstream has since moved `v8` out of `code-mode` into `code-mode-runtime`, which
the CLI does not use — so newer commits build. The script checks this in seconds
with `cargo tree -p codex-cli -i v8` and refuses early with an explanation
rather than dying twenty minutes later on what reads like a network error:

```
[cross-armv7] codex at rust-v0.146.0 links V8 into the CLI, and there is no armv7 build of V8.
              Build a commit where code-mode no longer depends on the v8 crate
              (CODEX_REF=main), or wait for the next upstream release.
```

**6. `codex-linux-sandbox` assumes 64-bit syscall numbers.** `libc::SYS_*` is
i64 on 64-bit targets and i32 on arm, while seccompiler's rule map is keyed by
i64 — 23 errors of one kind — and the architecture selection ends in
`unimplemented!()`. [`patches/0001-linux-sandbox-build-on-32-bit-arm.sh`](../patches/0001-linux-sandbox-build-on-32-bit-arm.sh)
converts the numbers and returns an error instead of panicking. It edits by
pattern: upstream keeps reshaping this code, and the diff it replaced stopped
applying at rust-v0.155.0 — no native build from 2026-09-18 to 2026-10-12.

## It builds

Validated in CI on 2026-08-04 against upstream `main` (`CODEX_REF=main`), after
the patches above:

```
Finished `release` profile [optimized + debuginfo] target(s) in 46m 53s
codex: ELF 32-bit LSB pie executable, ARM, EABI5, dynamically linked,
       interpreter /lib/ld-linux-armhf.so.3, stripped
dist/codex-<version>-armv7-unknown-linux-gnueabihf.tar.gz   85 MB
```

So the recipe is complete: ~1000 crates cross-compiled for armv7, ~47 minutes on
a GitHub runner (cached afterwards), and an 85 MB tarball against the 105 MB
aarch64 one that needs an emulator. Note it is **dynamically linked** (glibc,
libssl, libz from the board) where the official binary is static musl — the
install path checks it runs before trusting it.

## Releases: tags versus snapshots

| Built from | Release tag | Prerelease | Picked up by `install.sh` on its own |
|---|---|---|---|
| `rust-vX.Y.Z` (a codex release) | `vX.Y.Z` | no | **yes** — `CODEX_ENGINE=auto` asks for exactly this |
| a branch (`CODEX_REF=main`) | `snapshot-main-<sha>` | yes | no — install it with `CODEX_NATIVE_TARBALL=<url>` |

The distinction is not bureaucracy: a build from `main` is a different codebase
from the release it is ahead of, and publishing it under that version's tag would
hand every board a binary that claims to be something it is not. Snapshots also
report `0.0.0`, because upstream stamps crate versions only when it tags.

Measured end to end on the pad, installing a published snapshot straight from
GitHub: **1 min 6 s** for 89 MB downloaded, checksum verified, unpacked and
wrappers written; `codex --version` answers in 0.11 s afterwards.

## What this means in practice

- **Up to 0.146.0, no native build was possible** — V8 was in the CLI graph.
- **From 0.147.0 (2026-08-07) on, the native build follows upstream.** Once a
  day the watcher compares the newest upstream release with the releases here,
  builds it if it is missing and publishes it; `install.sh` then installs it on
  its own — `CODEX_ENGINE=auto` asks the release, nothing to bump. Only the
  newest release is built: versions superseded within the same day are skipped.
- Emulation remains the fallback for the hours between an upstream release and
  its build, and for any future version that cannot be built for armv7.

## Two things still worth knowing about a native build

**The sandbox will not exist there either.** `linux-sandbox/src/seccomp.rs`
selects the seccomp target architecture with a `cfg!` chain ending in
`unimplemented!("unsupported architecture for seccomp filter")` for anything that
is not x86_64 or aarch64. Native or emulated, this board runs with
`sandbox_mode = "danger-full-access"` (README: what still asks before a command).

**`arg0` multi-call dispatch is known-broken on arm.** Upstream's own test suite
says so:

```rust
// Skipped on arm because the ctor logic to handle arg0 doesn't work on ARM
#[cfg(not(target_arch = "arm"))]
```

`codex-arg0` is what lets the binary re-exec itself as `codex-linux-sandbox` or
`apply_patch`. Encouraging (someone upstream does compile for arm32) and
limiting: that path needs verification on the first native binary that boots.

## When comparing the two engines

Do it on the same pad, same version, same workload. An emulated aarch64 build
with good codegen is not automatically slower than a native armv7 build of a
program that was never tuned for an in-order Cortex-A7 — `CODEX_KEEP_EMULATION=1`
installs both so the comparison is one environment variable away.
