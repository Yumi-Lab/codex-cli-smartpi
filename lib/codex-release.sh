# shellcheck shell=sh
# codex-release.sh — single source of truth for "where does the codex binary
# come from and which version is the newest". POSIX sh, no jq/python3.
#
# Sourced by install.sh (at install time) and by codex-check-update (installed
# to $CODEX_OPT/lib/codex-release.sh). Change an endpoint here, everything
# follows.
#
# Public interface:
#   CODEX_ASSET                     asset name for this board's architecture
#   codex_latest_version            → newest published version, or empty
#   codex_release_metadata VERSION  → release JSON on stdout (empty on failure)
#   codex_asset_digest JSON         → sha256 of $CODEX_ASSET in that JSON
#   codex_asset_urls VERSION        → download URLs, best source first (one/line)

# The Smart Pi One is armv7l, but codex only ships x86_64 and aarch64 builds:
# we take the aarch64 STATIC musl build and run it under 64-on-32 emulation.
CODEX_ASSET="codex-aarch64-unknown-linux-musl.tar.gz"

CODEX_RELEASES_BASE="https://releases.openai.com/codex"
CODEX_GITHUB_REPO="openai/codex"
# Upstream tags releases "rust-vX.Y.Z"; the version alone is what we store.
CODEX_TAG_PREFIX="rust-v"

CODEX_CURL_TIMEOUT="${CODEX_CURL_TIMEOUT:-20}"

# Fetch a URL as text; empty output + non-zero status on failure.
codex_fetch_text() { curl -fsSL --max-time "$CODEX_CURL_TIMEOUT" "$1" 2>/dev/null; }

# One JSON field per line so the rest can be plain grep/awk. Splitting on
# commas AND on the opening braces/brackets is what keeps the first field of an
# object (`{"name":"…"`) on a line of its own. The metadata is machine-generated
# and flat enough for this to be reliable, and it keeps the pad free of a
# jq/python3 dependency.
# shellcheck disable=SC2020  # mapping three characters to newline is the intent
codex_json_lines() { tr -d ' \t\n' | tr ',{[' '\n\n\n'; }

# First "tag_name": "rust-vX.Y.Z" found → X.Y.Z
codex_tag_version() {
  codex_json_lines | grep -m1 "\"tag_name\":\"$CODEX_TAG_PREFIX" \
    | sed "s/.*\"$CODEX_TAG_PREFIX//; s/\".*//"
}

# Newest published version. releases.openai.com first (what the official
# installer prefers), GitHub Releases as fallback. Empty when both are down.
codex_latest_version() {
  v="$(codex_fetch_text "$CODEX_RELEASES_BASE/channels/latest" | codex_tag_version || true)"
  [ -n "$v" ] || v="$(codex_fetch_text "https://api.github.com/repos/$CODEX_GITHUB_REPO/releases/latest" | codex_tag_version || true)"
  case "$v" in *[!0-9.]*|"") printf '' ;; *) printf '%s' "$v" ;; esac
}

# Release metadata for one version (used for the published checksum).
codex_release_metadata() {
  m="$(codex_fetch_text "$CODEX_RELEASES_BASE/releases/$1/release.json" || true)"
  [ -n "$m" ] || m="$(codex_fetch_text "https://api.github.com/repos/$CODEX_GITHUB_REPO/releases/tags/$CODEX_TAG_PREFIX$1" || true)"
  printf '%s' "$m"
}

# sha256 of $CODEX_ASSET inside a release JSON passed on stdin.
# Both sources publish a "digest": "sha256:…" inside the asset object, but not
# at the same offset (GitHub inserts a whole "uploader" object after the name),
# so we take the first digest that follows the exact name field.
codex_asset_digest() {
  codex_json_lines | awk -v name="\"name\":\"$CODEX_ASSET\"" '
    $0 == name { found = 1; next }
    found && /"digest":"sha256:/ {
      sub(/.*sha256:/, ""); sub(/".*/, ""); print; exit
    }'
}

# Download URLs for one version, best source first.
codex_asset_urls() {
  printf '%s/releases/%s/%s\n' "$CODEX_RELEASES_BASE" "$1" "$CODEX_ASSET"
  printf 'https://github.com/%s/releases/download/%s%s/%s\n' \
    "$CODEX_GITHUB_REPO" "$CODEX_TAG_PREFIX" "$1" "$CODEX_ASSET"
}
