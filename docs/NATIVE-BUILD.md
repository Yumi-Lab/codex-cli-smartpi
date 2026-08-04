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

## What this means in practice

- **codex 0.146.0 cannot be built natively for armv7** — V8 is in the CLI graph.
  The pad runs the emulated aarch64 binary, which is what `install.sh` installs
  today, and it works (see the measured numbers in
  [METHODOLOGY.md](METHODOLOGY.md)).
- **The moment upstream ships a release without V8 in the CLI graph**, the daily
  watcher builds it, publishes an armv7 asset, and `install.sh` starts installing
  the native binary on its own — `CODEX_ENGINE=auto` asks the release, no manual
  step, nothing to bump.
- Everything else on the way there is already solved and committed: toolchain,
  multiarch, the `pagable` patch, the ssh rewrite, the release/publish pipeline.

## Two things still worth knowing about a native build

**The sandbox will not exist there either.** `linux-sandbox/src/landlock.rs`
selects the seccomp target architecture with a `cfg!` chain ending in
`unimplemented!("unsupported architecture for seccomp filter")` for anything that
is not x86_64 or aarch64. Native or emulated, this board runs with
`sandbox_mode = "danger-full-access"` and approvals as the safety net.

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
