#!/usr/bin/env bash
# Cross-compile the official OpenAI Codex CLI for armv7-unknown-linux-gnueabihf —
# the native track: no emulation on the pad at all.
#
#   build/cross-armv7.sh [version] [outdir]
#     version   codex version like 0.146.0 (default: the newest published)
#     outdir    where the tarball lands (default: ./dist)
#
# The same recipe runs in GitHub Actions (.github/workflows/native-armv7.yml) and
# on any Linux box with Docker:
#   docker run --rm -v "$PWD:/repo" -w /repo rust:latest build/cross-armv7.sh
#
# Never on the pad: linking this workspace needs several GB of RAM.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET=armv7-unknown-linux-gnueabihf
VER="${1:-}"
OUT="${2:-$HERE/dist}"
SRC="${CODEX_SRC:-/tmp/codex-src}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

log()  { printf '\033[1;36m[cross-armv7]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[cross-armv7]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[cross-armv7]\033[0m %s\n' "$*" >&2; exit 1; }

# Version resolution reuses the one place that knows the release endpoints.
# shellcheck source=lib/codex-release.sh
. "$HERE/lib/codex-release.sh"
[ -n "$VER" ] || VER="$(codex_latest_version)"
[ -n "$VER" ] || fail "cannot resolve the newest codex version (offline?)"
log "building codex $VER for $TARGET with $JOBS jobs"

# --- toolchain -------------------------------------------------------------
# Debian, because armhf lives in the SAME mirror: `dpkg --add-architecture armhf`
# then apt gives real armhf -dev packages. Some crates in this workspace are not
# pure Rust and need them:
#   openssl-sys → libssl-dev:armhf (no vendored build in this dependency graph)
#   libz-sys    → zlib1g-dev:armhf
#   aws-lc-sys  → cmake + a C++ cross compiler + libclang (bindgen has no
#                 pre-generated bindings for armv7)
if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null; then
  log "installing the cross toolchain (+ armhf multiarch)"
  dpkg --add-architecture armhf
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf libc6-dev-armhf-cross \
    pkg-config \
    cmake clang libclang-dev perl git ca-certificates file \
    libssl-dev:armhf zlib1g-dev:armhf >/dev/null
fi
command -v arm-linux-gnueabihf-gcc >/dev/null \
  || fail "missing arm-linux-gnueabihf-gcc — apt-get install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf libc6-dev-armhf-cross cmake clang"
command -v cargo >/dev/null || fail "missing cargo (use the rust:latest image, or install rustup)"
# NOTE: the target is added AFTER the source is fetched — codex pins its own
# toolchain in rust-toolchain.toml, and `rustup target add` only serves the
# toolchain active in the current directory. Doing it here would install std for
# the runner's default toolchain and the build would then fail with
# "can't find crate for `core`".

# --- source ----------------------------------------------------------------
# Shallow, sparse: the Rust workspace only. The tag scheme is upstream's.
if [ ! -d "$SRC/.git" ]; then
  log "cloning openai/codex at rust-v$VER"
  git clone --depth 1 --filter=blob:none --no-checkout \
    --branch "rust-v$VER" https://github.com/openai/codex.git "$SRC"
  git -C "$SRC" sparse-checkout init --cone
  git -C "$SRC" sparse-checkout set codex-rs
  git -C "$SRC" checkout
else
  log "reusing $SRC (fetching rust-v$VER)"
  git -C "$SRC" fetch --depth 1 origin "rust-v$VER"
  git -C "$SRC" checkout -q -f FETCH_HEAD
  git -C "$SRC" reset -q --hard FETCH_HEAD   # drop a previous run's [patch] section
fi

# --- patches ---------------------------------------------------------------
# Anything upstream cannot do on 32-bit ARM lives in patches/, applied in order.
# Keep each one minimal and explain it in its header: this set has to survive
# every upstream release.
if compgen -G "$HERE/patches/*.patch" >/dev/null; then
  for p in "$HERE"/patches/*.patch; do
    log "applying $(basename "$p")"
    git -C "$SRC" apply --verbose "$p" || fail "patch $(basename "$p") no longer applies to rust-v$VER"
  done
fi

# --- third-party crates that assume 64 bits --------------------------------
# Some dependencies fail to COMPILE on 32-bit ARM for reasons that have nothing
# to do with codex (see patches/crates/*.patch for the case-by-case reasoning).
#
# They are patched IN THE EXTRACTED REGISTRY SOURCE, not through
# [patch.crates-io]: a patch entry forces cargo to re-resolve the whole graph,
# and a re-resolved graph is not the one upstream tested — the first attempt
# dragged in a v8 dependency that the pinned lockfile does not contain, and the
# build died trying to download a V8 prebuilt that has no armv7 flavour.
# Patching the extracted source keeps `--locked` valid and the graph identical.
apply_crate_patches() {
  compgen -G "$HERE/patches/crates/*.patch" >/dev/null || return 0
  local src_root="${CARGO_HOME:-$HOME/.cargo}/registry/src"
  for p in "$HERE"/patches/crates/*.patch; do
    local nv name ver dir
    nv="$(basename "$p" .patch)"          # e.g. pagable-0.4.1
    name="${nv%-*}"; ver="${nv##*-}"
    # The dependency graph must actually contain that exact version, otherwise
    # the patch is stale and would silently do nothing.
    grep -q "^name = \"$name\"" "$SRC/codex-rs/Cargo.lock" \
      || fail "patches/crates/$nv.patch: $name is no longer a dependency of codex $VER"
    grep -A1 "^name = \"$name\"" "$SRC/codex-rs/Cargo.lock" | grep -q "^version = \"$ver\"" \
      || fail "patches/crates/$nv.patch: codex $VER uses a different version of $name — rebase the patch"

    dir="$(find "$src_root" -maxdepth 2 -type d -name "$nv" 2>/dev/null | head -1)"
    [ -n "$dir" ] || return 1          # not extracted yet — caller retries later
    if [ -e "$dir/.yumi-patched" ]; then
      log "$nv already patched"
    else
      ( cd "$dir" && patch -p1 --silent < "$p" ) || fail "patches/crates/$nv.patch does not apply to $nv"
      touch "$dir/.yumi-patched"
      log "patched $nv in the registry source"
    fi
  done
}

# --- toolchain, take two ---------------------------------------------------
# Inside the source tree rust-toolchain.toml decides which rustc runs; `rustup
# show` installs it if needed, then the target lands on that exact toolchain.
log "pinned toolchain: $(cd "$SRC/codex-rs" && rustup show active-toolchain 2>/dev/null || echo unknown)"
( cd "$SRC/codex-rs" && rustup target add "$TARGET" )

# --- build -----------------------------------------------------------------
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER=arm-linux-gnueabihf-gcc
export CC_armv7_unknown_linux_gnueabihf=arm-linux-gnueabihf-gcc
export CXX_armv7_unknown_linux_gnueabihf=arm-linux-gnueabihf-g++
export AR_armv7_unknown_linux_gnueabihf=arm-linux-gnueabihf-ar
# The Smart Pi One is a Cortex-A7: NEON + hard float are guaranteed.
export CFLAGS_armv7_unknown_linux_gnueabihf="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"
export CXXFLAGS_armv7_unknown_linux_gnueabihf="$CFLAGS_armv7_unknown_linux_gnueabihf"
# -sys crates must resolve the armhf .pc files, not the host ones, or they find
# the amd64 libraries and link garbage. bookworm has no per-triplet pkg-config
# wrapper package, so the search path is set directly.
export PKG_CONFIG_ALLOW_CROSS=1
export PKG_CONFIG_LIBDIR=/usr/lib/arm-linux-gnueabihf/pkgconfig:/usr/share/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=/
export OPENSSL_NO_VENDOR=1
# bindgen (aws-lc-sys) needs the cross headers explicitly.
export BINDGEN_EXTRA_CLANG_ARGS_armv7_unknown_linux_gnueabihf="--target=arm-linux-gnueabihf --sysroot=/usr/arm-linux-gnueabihf -I/usr/include/arm-linux-gnueabihf"
export CARGO_TERM_COLOR=never

# `cargo fetch` populates the registry; crates are only unpacked when something
# needs them, so a first (expected to fail) build is the fallback that forces it.
# codex's workspace patches one dependency through an ssh:// URL. Without an SSH
# key cargo cannot resolve it, re-resolves the graph instead, and that graph is
# NOT the one upstream tested — it pulled in a v8 dependency whose build script
# downloads a V8 prebuilt that has no armv7 flavour. Rewriting ssh→https lets
# cargo resolve exactly what the lockfile says, so --locked can hold.
git config --global url."https://github.com/".insteadOf "ssh://git@github.com/"
git config --global url."https://github.com/".insteadOf "git@github.com:"

log "fetching the dependency graph (locked)"
if ! ( cd "$SRC/codex-rs" && cargo fetch --locked --target "$TARGET" ); then
  warn "the pinned lockfile needs an update — resolving without --locked"
  LOCKED=""
  ( cd "$SRC/codex-rs" && cargo fetch --target "$TARGET" )
  # Leave a trace of what the re-resolution dragged in: this is where a v8
  # dependency would appear, and it is the reason a build suddenly needs a
  # prebuilt that does not exist for this architecture.
  if grep -q '^name = "v8"' "$SRC/codex-rs/Cargo.lock"; then
    warn "v8 is in the resolved graph — dependency drift, see docs/NATIVE-BUILD.md"
    ( cd "$SRC/codex-rs" && cargo tree --target "$TARGET" -p codex-cli -i v8 2>&1 | head -20 ) || true
  fi
else
  LOCKED="--locked"
fi
if ! apply_crate_patches; then
  log "sources not unpacked yet — priming the build to extract them"
  ( cd "$SRC/codex-rs" && cargo build --release $LOCKED --target "$TARGET" -j "$JOBS" -p codex-cli --bin codex ) || true
  apply_crate_patches || fail "a crate to patch was never extracted — check patches/crates/"
fi

log "cargo build --release $LOCKED -p codex-cli --bin codex"
# shellcheck disable=SC2086  # $LOCKED is either empty or exactly --locked
( cd "$SRC/codex-rs" && cargo build --release $LOCKED --target "$TARGET" -j "$JOBS" -p codex-cli --bin codex )

BIN="$SRC/codex-rs/target/$TARGET/release/codex"
[ -x "$BIN" ] || fail "the build produced no binary"
arm-linux-gnueabihf-strip "$BIN" || true

mkdir -p "$OUT"
NAME="codex-$VER-$TARGET"
tar -czf "$OUT/$NAME.tar.gz" -C "$(dirname "$BIN")" codex
( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

log "done: $OUT/$NAME.tar.gz ($(du -h "$OUT/$NAME.tar.gz" | cut -f1))"
file "$BIN" || true
