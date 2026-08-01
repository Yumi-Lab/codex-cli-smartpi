#!/usr/bin/env bash
# On-device validation — the part no container or CI job can prove: that the
# emulated codex binary actually RUNS on the board.
#
#   test/pad-smoke.sh pi@192.168.1.108          # install + measure
#   SKIP_INSTALL=1 test/pad-smoke.sh pi@pad      # measure an existing install
#
# Prints timings and temperatures, writes nothing to the repo. Everything is
# wrapped in `timeout` so a hung emulator ends the test instead of the session.
# shellcheck disable=SC2016  # the single-quoted commands must expand on the pad, not here
set -uo pipefail

PAD="${1:-}"
[ -n "$PAD" ] || { echo "usage: $0 user@host" >&2; exit 2; }
SSH=(ssh -o ConnectTimeout=8 "$PAD")

step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

step "board"
"${SSH[@]}" 'uname -a; nproc; free -m | head -2; df -Pm / | tail -1'

if [ -z "${SKIP_INSTALL:-}" ]; then
  step "install (this is also the updater)"
  "${SSH[@]}" 'curl -fsSL https://raw.githubusercontent.com/Yumi-Lab/codex-cli-smartpi/main/install.sh | bash'
fi

step "version + startup cost, fork engine (default)"
"${SSH[@]}" 'cd /tmp && time timeout 300 codex --version; echo "rc=$?"'

step "version, qemu 7.2 fallback engine"
"${SSH[@]}" 'cd /tmp && time timeout 300 env CODEX_QEMU=7.2 codex-bin --version; echo "rc=$?"'

step "translation cache: 128 MiB (default) vs 256 MiB"
"${SSH[@]}" 'cd /tmp && for tb in 128 256; do echo "TB=$tb"; time timeout 300 env CODEX_TB_SIZE=$tb codex-bin --version >/dev/null; done'

step "resident memory of a run"
"${SSH[@]}" 'cd /tmp && (timeout 120 codex-bin --version >/dev/null &) ; sleep 20; ps -o rss=,comm= -C qemu-aarch64-fork | head -3'

step "update probe (OTA contract)"
"${SSH[@]}" 'codex-check-update'

step "thermals"
"${SSH[@]}" 'echo "$(( $(cat /sys/class/thermal/thermal_zone0/temp) / 1000 )) C"'

cat <<'MSG'

Still to check by hand, in an interactive session on the pad:
  codex login --device-auth     # headless sign-in
  codex                         # the TUI: does it render, does it stay stable?
  codex exec "list the files here and tell me what this project is"
                                # a real turn: tool calls spawn native armv7
                                # children through the emulator's execve
Watch the temperature during the run; CODEX_CPUS=0,1 throttles it.
Record what you get in docs/METHODOLOGY.md (section 8).
MSG
