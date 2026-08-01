# Can codex be built natively for armv7l? (and is there JS/Python inside?)

Assessment done on **codex 0.146.0** (`rust-v0.146.0`), source read from
[openai/codex](https://github.com/openai/codex) at that tag. Conclusion first:

> **The source is fully public (Apache-2.0) — nothing needs decompiling.** There
> is no embedded JavaScript or Python interpreter in the `codex` binary to
> extract. A native `armv7-unknown-linux-gnueabihf` build is *plausible* but not
> free: three real blockers, listed below. Emulation ships today; a native build
> is a follow-up project.

## 1. What the binary actually is

`codex-aarch64-unknown-linux-musl` is a 269 MB **statically linked Rust binary**,
stripped. Not Bun, not Node, not PyInstaller — so the extraction trick used for
[Claude Code](https://github.com/Yumi-Lab/claude-code-smartpi) (recovering the JS
bundle from a Bun-compiled binary) has no equivalent here, and no need for one:

- Rust workspace of ~150 crates under `codex-rs/`, toolchain pinned to **1.95.0**
  (`codex-rs/rust-toolchain.toml`), Cargo + Bazel build files, Apache-2.0.
- The only embedded web-ish assets are static HTML/CSS strings:
  `login/src/assets/{success,error}.html` (the page shown after a browser login)
  and `tui/src/inline_visualization/assets/{visualize.html,visualize.css}`. Those
  are the `--primary-foreground` / `--radius-lg` CSS variables one finds with
  `strings` — a stylesheet, not an application.
- **V8 is in the workspace but not in this binary.** `v8 150.4.0` is a dependency
  of `code-mode-runtime`, used only by the separate `codex-code-mode-host`
  executable (the upstream installer wires it on macOS only). The `codex` binary
  (`codex-rs/cli`) does not pull it in — which is precisely what makes a 32-bit
  build conceivable at all, since `rusty_v8` publishes no armv7 prebuilt.

## 2. Blockers for `armv7-unknown-linux-gnueabihf`

**(a) rustls uses the `aws_lc_rs` provider.** The workspace pins
`rustls = { default-features = false, features = ["aws_lc_rs", "std"] }` (and
`rcgen` likewise), so `aws-lc-sys` 0.39 must compile for 32-bit ARM — a C/CMake
build with hand-written assembly whose armv7 support is best-effort. This is the
most likely thing to fail first. `ring` 0.17 is already in the lockfile (pulled
by other crates) and does support armv7, so switching the provider is the
obvious escape hatch — it is a workspace-level patch, not a fork of the code.

**(b) the sandbox does not exist on 32-bit ARM.** `linux-sandbox/src/landlock.rs`
selects the seccomp target architecture with a `cfg!` chain that ends in
`unimplemented!("unsupported architecture for seccomp filter")` for anything that
is not x86_64 or aarch64. A native armv7 build must therefore run with
`sandbox_mode = "danger-full-access"` too — exactly like the emulated one — or
carry a patch adding `TargetArch::arm`. **This is the same conclusion the
emulated setup reaches, for a different reason.**

**(c) `arg0` multi-call dispatch is known-broken on ARM.** Upstream's own test
suite says so:

```rust
// Skipped on arm because the ctor logic to handle arg0 doesn't work on ARM
#[cfg(not(target_arch = "arm"))]
async fn unified_exec_formats_large_output_summary() -> Result<()> {
```

`codex-arg0` is the busybox-style dispatcher that lets the binary re-exec itself
as `codex-linux-sandbox` / `apply_patch`. Encouraging (someone upstream *does*
compile for arm32) and limiting (that path needs verification, or the features
that rely on it need to be disabled).

Not blockers, worth noting: 64-bit atomics are fine on armv7 (LDREXD/STREXD),
`zstd-sys`/`openssl-sys` build for armhf routinely, and `usize` being 32-bit is a
risk only in code that assumes 64-bit — the workspace has ~100 `AtomicU64` /
`u64 as usize` sites that a first build would flag.

## 3. If someone takes it on

Never on the pad (1 GB of RAM will not link this). Cross-compile in Docker on the
Mac, the way `qemu-64on32-smartpi` already does for qemu:

```bash
rustup target add armv7-unknown-linux-gnueabihf
# in a debian:bookworm container with gcc-arm-linux-gnueabihf + cmake + clang
cargo build --release --target armv7-unknown-linux-gnueabihf -p codex-cli
```

Expected order of events: `aws-lc-sys` fails → patch the workspace onto the
`ring` provider → the build gets far → drop/stub the linux-sandbox crate → a
binary that must run with sandboxing off. Compare it against the emulated setup
on the *same* pad before switching anything: an emulated aarch64 build with good
codegen is not automatically slower than a native armv7 build of a program that
was never tuned for in-order Cortex-A7.

Until that comparison exists, this repo ships emulation — it works, it is one
`curl | bash`, and it tracks upstream releases the day they ship.
