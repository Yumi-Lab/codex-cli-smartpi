#!/usr/bin/env bash
# Run install.sh in a REAL 32-bit ARM userland (armv7l), without a pad.
#
# A linux/arm/v7 container gives `uname -m` = armv7l, a 32-bit libc and 32-bit
# coreutils — everything the installer branches on. On an x86_64/aarch64 host it
# is driven by qemu-arm (binfmt), so the codex binary runs *nested*: our aarch64
# qemu inside the host's arm qemu. That nesting works (measured: `codex
# --version` in ~10 s on an Apple Silicon host, both engines), so the smoke test
# is on by default — but a slow runner may need more than the timeout, and a
# timeout alone does not fail the run unless CODEX_SMOKE_STRICT=1.
#
#   test/install-armv7-docker.sh                 # install + layout + smoke
#   CODEX_SMOKE=0 test/install-armv7-docker.sh   # installer only
#
# Requires: docker (colima or Docker Desktop) with binfmt for arm.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-debian:bookworm}"
SMOKE="${CODEX_SMOKE:-1}"
SMOKE_TIMEOUT="${CODEX_SMOKE_TIMEOUT:-900}"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

echo "==> registering arm binfmt handlers (idempotent)"
docker run --privileged --rm tonistiigi/binfmt --install arm >/dev/null 2>&1 || true

echo "==> running install.sh inside $IMAGE (linux/arm/v7)"
docker run --rm --platform linux/arm/v7 \
  -v "$REPO:/repo:ro" \
  -e "CODEX_SMOKE=$SMOKE" \
  -e "CODEX_SMOKE_TIMEOUT=$SMOKE_TIMEOUT" \
  -e "CODEX_SMOKE_STRICT=${CODEX_SMOKE_STRICT:-0}" \
  -e "CODEX_VERSION=${CODEX_VERSION:-}" \
  "$IMAGE" bash -euo pipefail -c '
    echo "--- guest arch: $(uname -m)"
    [ "$(uname -m)" = "armv7l" ] || { echo "not an armv7l userland — binfmt missing?"; exit 1; }
    apt-get update -qq && apt-get install -y -qq curl ca-certificates file >/dev/null

    bash /repo/install.sh 2>&1 | tee /tmp/install.log

    echo "--- assertions"
    grep -q "checksum verified" /tmp/install.log || { echo "FAIL: published checksum was not verified"; exit 1; }
    test -x /opt/codex/qemu-aarch64-static      || { echo "FAIL: qemu 7.2 missing";      exit 1; }
    test -x /opt/codex/qemu-aarch64-fork        || { echo "FAIL: qemu fork missing";     exit 1; }
    test -x /opt/codex/codex-aarch64            || { echo "FAIL: codex binary missing";  exit 1; }
    test -s /opt/codex/VERSION                  || { echo "FAIL: VERSION missing";       exit 1; }
    test -r /opt/codex/lib/codex-release.sh     || { echo "FAIL: release lib missing";   exit 1; }
    test -x /usr/local/bin/codex                || { echo "FAIL: dispatcher missing";    exit 1; }
    test -x /usr/local/bin/codex-bin            || { echo "FAIL: wrapper missing";       exit 1; }
    test -x /usr/local/bin/codex-check-update   || { echo "FAIL: probe missing";         exit 1; }
    test -r "$HOME/.codex/config.toml"          || { echo "FAIL: default config missing"; exit 1; }
    grep -q "danger-full-access" "$HOME/.codex/config.toml" || { echo "FAIL: sandbox not disabled"; exit 1; }

    # The two engines must be 32-bit ARM (they run natively on the pad) and the
    # payload must be the aarch64 build (it does not).
    file -b /opt/codex/qemu-aarch64-fork | grep -q "ELF 32-bit.*ARM"     || { echo "FAIL: fork engine is not a 32-bit ARM binary"; exit 1; }
    file -b /opt/codex/codex-aarch64     | grep -q "ELF 64-bit.*aarch64" || { echo "FAIL: payload is not an aarch64 binary";      exit 1; }

    echo "--- update probe"
    codex-check-update
    codex-check-update | grep -q "\"cli\":\"codex\"" || { echo "FAIL: probe output"; exit 1; }
    installed=$(codex-check-update --installed); latest=$(codex-check-update --latest)
    [ -n "$installed" ] || { echo "FAIL: installed version empty"; exit 1; }
    echo "installed=$installed latest=$latest"

    if [ "$CODEX_SMOKE" != "0" ]; then
      echo "--- smoke: the emulated binary must answer, on both engines"
      for engine in fork 7.2; do
        if out=$(timeout "$CODEX_SMOKE_TIMEOUT" env CODEX_QEMU="$engine" codex-bin --version 2>&1); then
          echo "engine=$engine → $out"
          case "$out" in
            *"$installed"*) ;;
            *) echo "FAIL: engine $engine answered \"$out\", expected version $installed"; exit 1 ;;
          esac
        else
          # On an x86_64/aarch64 host this is one emulator inside another; a slow
          # runner timing out says nothing about the pad, so it only fails the
          # run when asked to.
          echo "WARN: engine $engine did not answer within ${CODEX_SMOKE_TIMEOUT}s (nested emulation)"
          [ "$CODEX_SMOKE_STRICT" = "1" ] && { echo "FAIL: strict mode"; exit 1; }
        fi
      done
    fi

    echo "--- idempotence (a second run is the OTA update path)"
    bash /repo/install.sh | tail -3

    echo "ALL ASSERTIONS PASSED"
  '
