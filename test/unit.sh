#!/usr/bin/env bash
# Offline unit tests: release metadata parsing, the OTA probe contract, and the
# no-hardcoded-paths rule. No network, no root, runs anywhere (macOS, CI, pad).
#
#   test/unit.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="$REPO/test/fixtures"
PASS=0; FAIL=0

ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "$2" "$3"; fi; }

# The installer stops right after defining its pure helpers when CODEX_LIB_ONLY
# is set, so the tests exercise the very code the pad runs.
# shellcheck source=/dev/null
CODEX_LIB_ONLY=1 . "$REPO/install.sh"

echo "release metadata (releases.openai.com shape)"
is "version from the channel JSON" "0.146.0" \
   "$(codex_tag_version < "$FIX/release-openai.json")"
is "asset digest" "975bac91562abeedeb8f79636d51a86649b31f34a9de6a3bcb059565b6cf1f87" \
   "$(codex_asset_digest < "$FIX/release-openai.json")"

echo "release metadata (GitHub API shape — an \"uploader\" object sits between name and digest)"
is "version from the GitHub JSON" "0.146.0" \
   "$(codex_tag_version < "$FIX/release-github.json")"
is "asset digest" "975bac91562abeedeb8f79636d51a86649b31f34a9de6a3bcb059565b6cf1f87" \
   "$(codex_asset_digest < "$FIX/release-github.json")"

echo "robustness"
is "no digest for an absent asset" "" \
   "$(CODEX_ASSET=codex-riscv64-unknown-linux-musl.tar.gz codex_asset_digest < "$FIX/release-openai.json")"
is "no version in unrelated JSON" "" \
   "$(printf '{"hello":"world"}' | codex_tag_version)"

echo "download sources"
urls="$(codex_asset_urls 1.2.3)"
is "two sources" "2" "$(printf '%s\n' "$urls" | wc -l | tr -d ' ')"
is "official CDN first" "https://releases.openai.com/codex/releases/1.2.3/codex-aarch64-unknown-linux-musl.tar.gz" \
   "$(printf '%s\n' "$urls" | sed -n 1p)"
is "GitHub Releases second" "https://github.com/openai/codex/releases/download/rust-v1.2.3/codex-aarch64-unknown-linux-musl.tar.gz" \
   "$(printf '%s\n' "$urls" | sed -n 2p)"

echo "OTA probe contract"
tmp="$(mktemp -d)"; mkdir -p "$tmp/lib"
printf '0.146.0\n' > "$tmp/VERSION"
cat > "$tmp/lib/codex-release.sh" <<'STUB'
codex_latest_version() { printf '0.147.0'; }
STUB
out="$(CODEX_OPT="$tmp" sh "$REPO/bin/codex-check-update")"
is "JSON line" '{"cli":"codex","installed":"0.146.0","latest":"0.147.0","update_available":true}' "$out"
is "--installed" "0.146.0" "$(CODEX_OPT="$tmp" sh "$REPO/bin/codex-check-update" --installed)"
is "--latest"    "0.147.0" "$(CODEX_OPT="$tmp" sh "$REPO/bin/codex-check-update" --latest)"
printf '0.147.0\n' > "$tmp/VERSION"
is "up to date → update_available false" \
   '{"cli":"codex","installed":"0.147.0","latest":"0.147.0","update_available":false}' \
   "$(CODEX_OPT="$tmp" sh "$REPO/bin/codex-check-update")"
rm -f "$tmp/VERSION"
is "nothing installed → null" \
   '{"cli":"codex","installed":null,"latest":"0.147.0","update_available":false}' \
   "$(PATH=/usr/bin:/bin CODEX_OPT="$tmp" sh "$REPO/bin/codex-check-update")"
rm -rf "$tmp"

echo "no hardcoded install paths (a prefix change must not need a second edit)"
stray="$(grep -n '/opt/codex' "$REPO/install.sh" | grep -v '^\s*[0-9]*:\s*#' | grep -v 'CODEX_OPT:-/opt/codex' | grep -vc '^$' || true)"
is "install.sh derives every path from \$OPT" "0" "$stray"
stray="$(grep -c '/opt/codex' "$REPO/lib/codex-release.sh" || true)"
is "the release library holds no install path" "0" "$stray"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n' "$PASS"; exit 0
fi
printf '\033[31m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"; exit 1
