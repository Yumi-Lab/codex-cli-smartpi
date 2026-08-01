#!/usr/bin/env bash
# Run install.sh in a REAL 32-bit ARM userland (armv7l), without a pad.
#
# A linux/arm/v7 container gives `uname -m` = armv7l, a 32-bit libc and 32-bit
# coreutils — everything the installer branches on. On an x86_64/aarch64 host it
# is driven by qemu-arm (binfmt), so the codex binary itself would run *nested*
# (our aarch64 qemu inside the host's arm qemu): that part is unreliable and the
# smoke test stays off by default. What this proves is the installer: arch gate,
# download, published-checksum verification, unpack, wrapper generation, probe.
#
#   test/install-armv7-docker.sh              # install + layout assertions
#   CODEX_SMOKE=1 test/install-armv7-docker.sh  # also attempt `codex --version`
#
# Requires: docker (colima or Docker Desktop) with binfmt for arm.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${IMAGE:-debian:bookworm}"
SMOKE="${CODEX_SMOKE:-0}"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

echo "==> registering arm binfmt handlers (idempotent)"
docker run --privileged --rm tonistiigi/binfmt --install arm >/dev/null 2>&1 || true

echo "==> running install.sh inside $IMAGE (linux/arm/v7)"
docker run --rm --platform linux/arm/v7 \
  -v "$REPO:/repo:ro" \
  -e "CODEX_SMOKE=$SMOKE" \
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

    echo "--- idempotence (a second run is the OTA update path)"
    bash /repo/install.sh | tail -3

    echo "ALL ASSERTIONS PASSED"
  '
