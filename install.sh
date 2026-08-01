#!/usr/bin/env bash
# Official OpenAI Codex CLI on Yumi Smart Pi One / SmartPad — 32-bit ARM (armv7l)
#
# One-line install (also the UPDATER — re-run any time to move to the newest):
#   curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/codex-cli-smartpi/main/install.sh | bash
#
# The upstream installer (chatgpt.com/codex/install.sh) refuses armv7l: OpenAI
# ships codex for x86_64 and aarch64 only. The aarch64 build is a STATIC musl
# Rust binary, so it runs on the H3 through 64-on-32 user-mode emulation — the
# path already proven on this hardware for the Grok CLI.
#
# Installed layout:
#   $OPT/qemu-aarch64-static     user-mode emulator 7.2 (fallback engine)
#   $OPT/qemu-aarch64-fork       Yumi qemu fork 9.2.4 (DEFAULT engine: correct
#                                64-bit atomics — codex is a tokio/ratatui Rust
#                                app, it shares 64-bit state across threads)
#   $OPT/QEMU_FORK_VERSION       installed fork tag
#   $OPT/codex-aarch64           official codex binary (~269 MB, static musl)
#   $OPT/VERSION                 installed version (read by codex-check-update)
#   $OPT/lib/codex-release.sh    release endpoints + parsers (shared with the probe)
#   $BINDIR/codex-bin            wrapper (cores + nice + qemu engine)
#   $BINDIR/codex                dispatcher (single-emulator guard → codex-bin)
#   $BINDIR/codex-check-update   update probe (JSON one-liner, OTA contract)
#   ~/.codex/config.toml         created ONLY if absent: sandbox off + approvals on
#                                (codex's Landlock/seccomp/bwrap sandbox cannot
#                                work under emulation — see README)
#   binfmt_misc aarch64          → the fork engine (root, and only if free)
#   earlyoom                     anti-freeze memory safety net
#
# OTA contract (shared by every Yumi-Lab/*-smartpi repo):
#   * re-running this script IS the update; it exits fast when already newest
#     (CODEX_FORCE=1 to reinstall anyway, CODEX_VERSION=x.y.z to pin);
#   * `codex-check-update` prints one JSON line {cli, installed, latest,
#     update_available} — what the Yumi AI Gateway polls for its update badge;
#   * privileges: root (or sudo) for the FIRST install; a plain user that OWNS
#     $OPT for updates — the gateway service user updates WITHOUT sudo (the
#     $BINDIR wrappers are version-independent, only rewritten when their
#     content actually changes).
#
# Knobs (all optional):
#   CODEX_VERSION=x.y.z   pin a version          CODEX_FORCE=1     reinstall anyway
#   CODEX_CPUS=0,1        thermal throttle       CODEX_QEMU=7.2    fallback engine
#   CODEX_TB_SIZE=256     translation cache MiB  CODEX_SOLO=0      no co-tenancy warning
#   CODEX_OPT=/path       payload prefix         CODEX_BINDIR=/path  wrapper prefix
#   CODEX_DRY_RUN=1       resolve + print the plan, write nothing
#   CODEX_SMOKE=0         skip the final `codex --version`
#   CODEX_ALLOW_ANY_ARCH=1  run on a non-armv7l host (CI / VM staging only)
#
# See docs/METHODOLOGY.md for the reasoning behind every choice.
set -euo pipefail

# ---------------------------------------------------------------- configuration
RAW="https://raw.githubusercontent.com/Yumi-Lab/codex-cli-smartpi/main"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || true)"
OPT="${CODEX_OPT:-/opt/codex}"
BINDIR="${CODEX_BINDIR:-/usr/local/bin}"

# QEMU 7.2 (Debian bookworm, vendored) — last generation able to run a 64-bit
# guest on a 32-bit host. Kept as the fallback engine.
QEMU_SHA256="a26fb51967c49bd100d8d9f4865f643c1a7084cc60de583cde55ac33c62f30a6"
# Yumi fork of 9.2.4 — default engine (correct single-copy-atomic 64-bit guest
# accesses, termios2 backport, sizeable translation cache).
QEMU_FORK_TAG="v9.2.4-yumi.1"
QEMU_FORK_SHA256="cfdcb2f95299ada9ef5a0d3fb384df0a3a412b06a1c7271fc3e55c7d46680218"
QEMU_FORK_URL="https://github.com/Yumi-Lab/qemu-64on32-smartpi/releases/download/${QEMU_FORK_TAG}/qemu-aarch64"

PINNED_VER="0.146.0"   # last resort when both metadata sources are unreachable
NEED_FREE_MB=700       # tarball + new binary + previous binary
SMOKE_TIMEOUT=180      # first emulated start translates a lot of code

log()  { printf '\033[1;36m[codex-smartpi]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[codex-smartpi]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[codex-smartpi]\033[0m %s\n' "$*" >&2; exit 1; }

# Fetch one of our repo files to a temp path: local clone if present, else raw
# GitHub. Used for vendored payloads and for the shared release library.
fetch_tmp() { # $1 repo-relative path → prints temp file path
  local tmpf; tmpf="$(mktemp)"
  if [ -n "$HERE" ] && [ -f "$HERE/$1" ]; then
    cat "$HERE/$1" > "$tmpf"
  else
    curl -fsSL "$RAW/$1" -o "$tmpf" || { rm -f "$tmpf"; return 1; }
  fi
  printf '%s' "$tmpf"
}

# Release endpoints, version resolution and checksum lookup live in ONE place,
# shared with codex-check-update (installed under $OPT/lib).
RELEASE_LIB="$(fetch_tmp lib/codex-release.sh)" || fail "cannot fetch lib/codex-release.sh"
# shellcheck source=lib/codex-release.sh
. "$RELEASE_LIB"

# Sourced by the unit tests: everything above is pure, nothing has run yet.
[ -n "${CODEX_LIB_ONLY:-}" ] && return 0

# ---------------------------------------------------------------- preflight
if [ "$(uname -m)" != "armv7l" ] && [ -z "${CODEX_ALLOW_ANY_ARCH:-}" ]; then
  fail "This script targets armv7l (detected: $(uname -m)). On 64-bit, use https://chatgpt.com/codex/install.sh — or set CODEX_ALLOW_ANY_ARCH=1 to stage the payload anyway."
fi
command -v curl >/dev/null || fail "curl is required"
command -v tar  >/dev/null || fail "tar is required"

DRY="${CODEX_DRY_RUN:-}"
[ -z "$DRY" ] || log "DRY RUN — resolving everything, writing nothing."

# --- Privilege model. Root → no sudo. Non-root owning $OPT (the gateway service
#     user doing an OTA update) → plain writes, NO sudo at all. Anything else →
#     sudo (first install; may prompt for a password).
if [ "$(id -u)" -eq 0 ]; then SUDO=""
elif [ -d "$OPT" ] && [ -w "$OPT" ]; then SUDO=""
elif command -v sudo >/dev/null 2>&1; then SUDO="sudo"
else SUDO=""
fi
# Remember who owns an existing payload: a root re-run over a service-owned tree
# must give it back at the end, or the next unprivileged OTA update would break.
OPT_OWNER="$(stat -c %U "$OPT" 2>/dev/null || echo)"

# Install a file without sudo when the target allows it.
put() { # $1 src, $2 dest, $3 mode (default 755)
  local dir; dir="$(dirname "$2")"
  [ -z "$DRY" ] || { log "would install $2 (mode ${3:-755})"; return 0; }
  if [ -w "$dir" ] || { [ -e "$2" ] && [ -w "$2" ]; }; then
    install -m "${3:-755}" "$1" "$2"
  else
    $SUDO install -m "${3:-755}" "$1" "$2"
  fi
}

# Write $2 (a temp file) to $1 only when the content differs — routine updates
# never touch $BINDIR (root-owned), so the unprivileged OTA path stays clean.
put_if_changed() { # $1 dest, $2 src, $3 mode
  if [ -e "$1" ] && cmp -s "$1" "$2"; then rm -f "$2"; return 0; fi
  local rc=0
  put "$2" "$1" "${3:-755}" || rc=$?
  rm -f "$2"; return $rc
}

install_repo_file() { # $1 repo-relative path, $2 destination, $3 mode
  local t; t="$(fetch_tmp "$1")" || { warn "cannot fetch $1 (non-fatal)"; return 0; }
  put_if_changed "$2" "$t" "${3:-755}" \
    || warn "cannot write $2 (no privileges) — existing copy kept."
}

mkdirp() { [ -n "$DRY" ] || { mkdir -p "$1" 2>/dev/null || $SUDO mkdir -p "$1"; }; }

mkdirp "$OPT"
[ -n "$DRY" ] || [ -w "$OPT" ] || [ -n "$SUDO" ] || fail "$OPT is not writable and sudo is unavailable."

# Disk guard: the binary alone is ~269 MB, and an update keeps the old one until
# the new one lands. Failing here is far kinder than a half-written binary.
free_mb="$(df -Pm "$OPT" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [ -n "${free_mb:-}" ] && [ "$free_mb" -lt "$NEED_FREE_MB" ]; then
  fail "only ${free_mb} MB free on $(df -Pm "$OPT" | awk 'NR==2 {print $6}') — codex needs about ${NEED_FREE_MB} MB (269 MB binary + download + previous version)."
fi

# ---------------------------------------------------------------- 1. engines
# 1a. QEMU 7.2, vendored in the repo: NO dependency on Debian mirrors (the exact
#     .deb disappears from the pool at every point release).
if [ ! -x "$OPT/qemu-aarch64-static" ]; then
  log "Installing qemu-aarch64-static 7.2 (64-on-32 fallback engine)…"
  t="$(fetch_tmp vendor/qemu-aarch64-static)" || fail "cannot fetch vendor/qemu-aarch64-static"
  put "$t" "$OPT/qemu-aarch64-static" 755; rm -f "$t"
fi
if [ -z "$DRY" ] && command -v sha256sum >/dev/null; then
  echo "$QEMU_SHA256  $OPT/qemu-aarch64-static" | sha256sum -c --quiet \
    || fail "qemu-aarch64-static checksum mismatch — corrupted download?"
fi

# 1b. Yumi qemu fork 9.2.4 — DEFAULT engine. 7.2 tears 64-bit guest accesses;
#     that is what makes long multithreaded runs and TUIs die. Non-fatal on
#     failure: everything still works on 7.2.
cur_fork="$(head -1 "$OPT/QEMU_FORK_VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$cur_fork" != "$QEMU_FORK_TAG" ] || [ ! -x "$OPT/qemu-aarch64-fork" ] || [ -n "${CODEX_FORCE:-}" ]; then
  if [ -n "$DRY" ]; then
    log "would download qemu fork $QEMU_FORK_TAG (~35 MB)"
  else
    log "Downloading qemu fork ${QEMU_FORK_TAG} (correct-atomics 64-on-32, ~35 MB)…"
    tmpq="$(mktemp -p /var/tmp codex-qemu-fork.XXXXXX)"
    if curl -fSL --progress-bar -o "$tmpq" "$QEMU_FORK_URL"; then
      if command -v sha256sum >/dev/null \
         && ! echo "$QEMU_FORK_SHA256  $tmpq" | sha256sum -c --quiet 2>/dev/null; then
        rm -f "$tmpq"; warn "qemu fork checksum mismatch — keeping the 7.2-only setup."
      else
        put "$tmpq" "$OPT/qemu-aarch64-fork" 755; rm -f "$tmpq"
        tv="$(mktemp)"; printf '%s\n' "$QEMU_FORK_TAG" > "$tv"
        put "$tv" "$OPT/QEMU_FORK_VERSION" 644; rm -f "$tv"
        log "qemu fork installed → default engine (CODEX_QEMU=7.2 to fall back)."
      fi
    else
      rm -f "$tmpq"; warn "cannot download the qemu fork (offline?) — 7.2 stays the only engine."
    fi
  fi
fi

# ---------------------------------------------------------------- 2. codex
if [ -n "${CODEX_VERSION:-}" ]; then
  VER="$CODEX_VERSION"
else
  VER="$(codex_latest_version || true)"
  [ -n "$VER" ] || { VER="$PINNED_VER"; warn "release metadata unreachable — using pinned version $VER"; }
fi
case "$VER" in ''|*[!0-9.]*) fail "invalid codex version: '$VER'" ;; esac
log "Target version: codex $VER"

CURRENT="$(head -1 "$OPT/VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
if [ "$CURRENT" = "$VER" ] && [ -x "$OPT/codex-aarch64" ] && [ -z "${CODEX_FORCE:-}" ]; then
  log "codex $VER is already installed — refreshing helpers only (CODEX_FORCE=1 to reinstall)."
elif [ -n "$DRY" ]; then
  log "would download $CODEX_ASSET ($(codex_asset_urls "$VER" | head -1)) and unpack it to $OPT/codex-aarch64"
else
  # Published checksum for this exact asset — no constant to bump when codex
  # releases, it comes from the same metadata as the version.
  ASSET_SHA="$(codex_release_metadata "$VER" | codex_asset_digest || true)"

  log "Downloading codex $VER (linux-aarch64-musl, ~105 MB compressed)…"
  # /var/tmp, NOT /tmp: /tmp is often a tmpfs (RAM) on Armbian — a 105 MB
  # download in RAM is asking for an OOM freeze on a 1 GB board.
  tmpb="$(mktemp -p /var/tmp codex-smartpi.XXXXXX)"
  ok=""
  for url in $(codex_asset_urls "$VER"); do
    curl -fSL --progress-bar -o "$tmpb" "$url" && { ok=1; break; }
    warn "download failed from $url — trying the next source."
  done
  [ -n "$ok" ] || { rm -f "$tmpb"; fail "could not download codex $VER (all sources failed)"; }

  if [ -n "$ASSET_SHA" ] && command -v sha256sum >/dev/null; then
    echo "$ASSET_SHA  $tmpb" | sha256sum -c --quiet \
      || { rm -f "$tmpb"; fail "codex download checksum mismatch — aborting."; }
    log "checksum verified (sha256 ${ASSET_SHA%"${ASSET_SHA#????????}"}…)"
  else
    warn "no published checksum available for $CODEX_ASSET — skipping verification."
  fi

  # Extract straight to its final home (single-file archive): unpacking to a
  # temp dir and copying would cost 269 MB more on the SD card.
  log "Unpacking (269 MB)…"
  if [ -w "$OPT" ]; then
    tar -xzOf "$tmpb" > "$OPT/codex-aarch64.new"
    chmod 755 "$OPT/codex-aarch64.new"; mv -f "$OPT/codex-aarch64.new" "$OPT/codex-aarch64"
  else
    $SUDO sh -c "tar -xzOf '$tmpb' > '$OPT/codex-aarch64.new'"
    $SUDO chmod 755 "$OPT/codex-aarch64.new"; $SUDO mv -f "$OPT/codex-aarch64.new" "$OPT/codex-aarch64"
  fi
  rm -f "$tmpb"
  tv="$(mktemp)"; printf '%s\n' "$VER" > "$tv"
  put "$tv" "$OPT/VERSION" 644; rm -f "$tv"
fi

# ---------------------------------------------------------------- 3. wrappers
# codex-bin: the real CLI, all 4 cores at low priority, fork engine first.
# Watch thermals on sustained agentic loads: on this SoC a 4-core emulated run
# once reached ~102 °C → machine freeze. Throttle without reinstalling:
# CODEX_CPUS=0,1 codex …
# CODEX_TB_SIZE sizes the translation cache (MiB, fork only): codex is 269 MB of
# code and the stock 32 MiB cache means permanent retranslation.
# Paths are expanded here (single source of truth: $OPT), runtime variables are
# escaped so they stay dynamic in the wrapper.
w="$(mktemp)"
cat > "$w" <<EOF
#!/bin/sh
# codex-bin — official codex binary through the 64-on-32 qemu engine.
# Generated by install.sh (Yumi-Lab/codex-cli-smartpi) — do not edit by hand.
Q=$OPT/qemu-aarch64-fork
case "\${CODEX_QEMU:-fork}" in 7.2|72|static|system) Q=$OPT/qemu-aarch64-static ;; esac
[ -x "\$Q" ] || Q=$OPT/qemu-aarch64-static
QEMU_TB_SIZE="\${CODEX_TB_SIZE:-128}"; export QEMU_TB_SIZE
if command -v taskset >/dev/null 2>&1; then
  exec taskset -c "\${CODEX_CPUS:-0,1,2,3}" nice -n 5 "\$Q" $OPT/codex-aarch64 "\$@"
fi
exec nice -n 5 "\$Q" $OPT/codex-aarch64 "\$@"
EOF
# shellcheck disable=SC2015  # deliberate: warn when a wrapper already exists, fail when none does
put_if_changed "$BINDIR/codex-bin" "$w" 755 \
  || { [ -x "$BINDIR/codex-bin" ] && warn "cannot rewrite $BINDIR/codex-bin — existing wrapper kept." \
       || fail "cannot install $BINDIR/codex-bin (run once as root/sudo first)."; }

# codex dispatcher: one emulated runtime at a time on a 1 GB board (two of them
# means swap on SD, then a full freeze). Warn, never block — CODEX_SOLO=0 mutes.
w="$(mktemp)"
cat > "$w" <<EOF
#!/bin/sh
# codex — OpenAI Codex CLI for armv7l (dispatcher).
# Generated by install.sh (Yumi-Lab/codex-cli-smartpi) — do not edit by hand.
if [ "\${CODEX_SOLO:-1}" != "0" ] && command -v pgrep >/dev/null 2>&1; then
  if pgrep -f 'qemu-aarch64' >/dev/null 2>&1; then
    printf '\033[1;33m[codex]\033[0m another emulated runtime (qemu-aarch64) is already running — on 1 GB of RAM, run one at a time.\n' >&2
  fi
fi
exec $BINDIR/codex-bin "\$@"
EOF
# shellcheck disable=SC2015  # deliberate: warn when a dispatcher already exists, fail when none does
put_if_changed "$BINDIR/codex" "$w" 755 \
  || { [ -x "$BINDIR/codex" ] && warn "cannot rewrite $BINDIR/codex — existing dispatcher kept." \
       || fail "cannot install $BINDIR/codex (run once as root/sudo first)."; }

# ---------------------------------------------------------------- 4. helpers
log "Installing the shared release library and codex-check-update…"
mkdirp "$OPT/lib"
install_repo_file lib/codex-release.sh "$OPT/lib/codex-release.sh" 644
install_repo_file bin/codex-check-update "$BINDIR/codex-check-update" 755

# ---------------------------------------------------------------- 5. config
# Written ONLY when the user has none. codex's Linux sandbox (Landlock+seccomp,
# or the bundled bwrap) cannot work here: the seccomp filter it installs is
# written in aarch64 syscall numbers while the kernel is armv7, and both bwrap
# and the re-exec'd codex-linux-sandbox helper are aarch64 binaries the kernel
# cannot load on its own. Sandbox off + approvals on is the honest combination.
USER_NAME="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$USER_NAME" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$USER_HOME" ] || USER_HOME="$HOME"
CFG="$USER_HOME/.codex/config.toml"
if [ -n "$DRY" ]; then
  log "would write $CFG if absent"
elif [ ! -e "$CFG" ]; then
  log "Writing default config → $CFG"
  tmpc="$(mktemp)"
  cat > "$tmpc" <<'EOF'
# Yumi Smart Pi One (armv7l) — codex runs through 64-on-32 qemu user-mode
# emulation. Its own Linux sandbox cannot work there (aarch64 seccomp filters
# on an armv7 kernel, aarch64 bwrap/codex-linux-sandbox helpers), so it is
# disabled and approvals are the safety net: codex asks before running a
# command. Loosen to "on-request" once you trust a workspace; never leave BOTH
# the sandbox off and approvals off on this board.
sandbox_mode = "danger-full-access"
approval_policy = "untrusted"
EOF
  # Under `sudo bash install.sh` the script is root while the config belongs to
  # SUDO_USER: create it as root and hand it over, never re-enter sudo.
  if [ "$(id -un)" = "$USER_NAME" ]; then
    mkdir -p "$USER_HOME/.codex" && install -m 644 "$tmpc" "$CFG"
  elif [ "$(id -u)" -eq 0 ]; then
    mkdir -p "$USER_HOME/.codex" && chown "$USER_NAME" "$USER_HOME/.codex" \
      && install -o "$USER_NAME" -m 644 "$tmpc" "$CFG"
  else
    warn "cannot write $CFG for $USER_NAME — create it by hand (see README §4)."
  fi
  rm -f "$tmpc"
else
  grep -q 'sandbox_mode' "$CFG" 2>/dev/null \
    || warn "$CFG exists without sandbox_mode — add  sandbox_mode = \"danger-full-access\"  (codex's own sandbox cannot run under emulation)."
fi

# ---------------------------------------------------------------- 6. binfmt
# Let the kernel run ANY aarch64 binary through the fork engine: codex re-execs
# itself (codex-linux-sandbox) and can spawn vendored aarch64 helpers; without
# this the kernel answers ENOEXEC. Root only, and only when nothing is
# registered yet — an existing qemu-user-static setup wins.
BINFMT_NAME="qemu-aarch64-yumi"
BINFMT_MAGIC='\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00'
BINFMT_MASK='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
if [ -z "$DRY" ] && [ "$(id -u)" -eq 0 ] && [ -w /proc/sys/fs/binfmt_misc/register ] \
   && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
   && [ ! -e "/proc/sys/fs/binfmt_misc/$BINFMT_NAME" ] \
   && [ -x "$OPT/qemu-aarch64-fork" ]; then
  # The registration line is written to a file once, and both the immediate
  # registration and the boot unit `cat` it: the \x escapes are parsed by
  # binfmt_misc itself, so nothing must ever re-interpret them (`printf` in the
  # unit would depend on whether /bin/sh understands \xNN — dash does not).
  printf ':%s:M::%s:%s:%s:OC\n' "$BINFMT_NAME" "$BINFMT_MAGIC" "$BINFMT_MASK" "$OPT/qemu-aarch64-fork" \
    > "$OPT/binfmt.register"
  if cat "$OPT/binfmt.register" > /proc/sys/fs/binfmt_misc/register 2>/dev/null; then
    log "binfmt_misc: aarch64 binaries now run through the fork engine (undo: echo -1 > /proc/sys/fs/binfmt_misc/$BINFMT_NAME)"
    # binfmt_misc lives in tmpfs — re-register at boot.
    cat > /etc/systemd/system/codex-binfmt.service <<EOF
[Unit]
Description=Register the aarch64 binfmt handler for codex (Yumi 64-on-32 qemu fork)
After=proc-sys-fs-binfmt_misc.mount
ConditionPathExists=$OPT/binfmt.register

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'cat $OPT/binfmt.register > /proc/sys/fs/binfmt_misc/register'

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable codex-binfmt.service >/dev/null 2>&1 || true
  else
    rm -f "$OPT/binfmt.register"
  fi
fi

# ---------------------------------------------------------------- 7. earlyoom
# Anti-freeze safety net: kills the largest process before memory exhaustion
# (1 GB of RAM + SD-card swap = full machine freeze otherwise). Optional:
# root/passwordless-sudo only — an unprivileged OTA update silently skips it.
if [ -z "$DRY" ] && command -v apt-get >/dev/null; then
  if [ "$(id -u)" -eq 0 ]; then
    apt-get install -y -qq earlyoom >/dev/null 2>&1 \
      && systemctl enable --now earlyoom >/dev/null 2>&1 && log "earlyoom active" || true
  elif sudo -n true 2>/dev/null; then
    sudo apt-get install -y -qq earlyoom >/dev/null 2>&1 \
      && sudo systemctl enable --now earlyoom >/dev/null 2>&1 && log "earlyoom active" || true
  fi
fi

# A root re-run over a service-owned payload gives ownership back (the gateway
# service user must keep updating without sudo).
if [ -z "$DRY" ] && [ "$(id -u)" -eq 0 ] && [ -n "$OPT_OWNER" ] && [ "$OPT_OWNER" != "root" ] \
   && id "$OPT_OWNER" >/dev/null 2>&1; then
  chown -R "$OPT_OWNER" "$OPT" && log "ownership of $OPT returned to $OPT_OWNER"
fi

# ---------------------------------------------------------------- 8. smoke test
if [ -n "$DRY" ]; then
  log "DRY RUN complete — nothing was written."
  exit 0
fi
if [ "${CODEX_SMOKE:-1}" != "0" ]; then
  log "Check: $(timeout "$SMOKE_TIMEOUT" "$BINDIR/codex" --version 2>&1 | tail -1 \
    || echo "codex --version did not answer in ${SMOKE_TIMEOUT}s — retry on an idle board (README → Troubleshooting)")"
fi

cat <<'MSG'

✔ Install complete.

Sign in (ChatGPT Plus/Pro/Business account — no browser needed on the pad):
    codex login --device-auth
  → open the displayed URL on any machine, enter the one-time code.
  API key instead:
    printenv OPENAI_API_KEY | codex login --with-api-key

Usage:
    codex                     interactive TUI
    codex exec "task"         one-shot, non-interactive
    codex --version           sanity check (emulated: expect a few seconds)

Engine:
    fork 9.2.4-yumi (default) — correct 64-bit atomics, survives long runs
    CODEX_QEMU=7.2 codex …    — vendored qemu 7.2 (fallback engine)
    CODEX_CPUS=0,1 codex …    — thermal throttle (the H3 freezes near 100 °C)
    CODEX_TB_SIZE=256 codex … — bigger translation cache (MiB, fork only)

Update:
    codex-check-update        →  {"installed":…,"latest":…,"update_available":…}
    re-run install.sh         installs the newest version (that IS the updater)

DO NOT:
    codex update / the upstream installer  (they would drop an aarch64 binary
    outside the qemu wrapper — re-run install.sh instead)
MSG
