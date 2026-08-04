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

log() { printf '\033[1;36m[cross-armv7]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[cross-armv7]\033[0m %s\n' "$*" >&2; exit 1; }

# Version resolution reuses the one place that knows the release endpoints.
# shellcheck source=lib/codex-release.sh
. "$HERE/lib/codex-release.sh"
[ -n "$VER" ] || VER="$(codex_latest_version)"
[ -n "$VER" ] || fail "cannot resolve the newest codex version (offline?)"
log "building codex $VER for $TARGET with $JOBS jobs"

# --- toolchain -------------------------------------------------------------
# aws-lc-sys (rustls' crypto provider) is a CMake/C project: it needs cmake, a
# C++ cross compiler and clang, not just gcc.
if [ "$(id -u)" -eq 0 ] && command -v apt-get >/dev/null; then
  log "installing the cross toolchain"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf libc6-dev-armhf-cross \
    cmake clang perl pkg-config git ca-certificates >/dev/null
fi
command -v arm-linux-gnueabihf-gcc >/dev/null \
  || fail "missing arm-linux-gnueabihf-gcc — apt-get install gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf libc6-dev-armhf-cross cmake clang"
command -v cargo >/dev/null || fail "missing cargo (use the rust:latest image, or install rustup)"
rustup target add "$TARGET"

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
  git -C "$SRC" checkout -q FETCH_HEAD
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

# --- build -----------------------------------------------------------------
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER=arm-linux-gnueabihf-gcc
export CC_armv7_unknown_linux_gnueabihf=arm-linux-gnueabihf-gcc
export CXX_armv7_unknown_linux_gnueabihf=arm-linux-gnueabihf-g++
export AR_armv7_unknown_linux_gnueabihf=arm-linux-gnueabihf-ar
# The Smart Pi One is a Cortex-A7: NEON + hard float are guaranteed.
export CFLAGS_armv7_unknown_linux_gnueabihf="-march=armv7-a -mfpu=neon-vfpv4 -mfloat-abi=hard"
export CXXFLAGS_armv7_unknown_linux_gnueabihf="$CFLAGS_armv7_unknown_linux_gnueabihf"
export CARGO_TERM_COLOR=never

log "cargo build --release -p codex-cli --bin codex"
( cd "$SRC/codex-rs" && cargo build --release --target "$TARGET" -j "$JOBS" -p codex-cli --bin codex )

BIN="$SRC/codex-rs/target/$TARGET/release/codex"
[ -x "$BIN" ] || fail "the build produced no binary"
arm-linux-gnueabihf-strip "$BIN" || true

mkdir -p "$OUT"
NAME="codex-$VER-$TARGET"
tar -czf "$OUT/$NAME.tar.gz" -C "$(dirname "$BIN")" codex
( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

log "done: $OUT/$NAME.tar.gz ($(du -h "$OUT/$NAME.tar.gz" | cut -f1))"
file "$BIN" || true
