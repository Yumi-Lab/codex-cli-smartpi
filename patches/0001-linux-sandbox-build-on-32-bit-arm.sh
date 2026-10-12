#!/usr/bin/env bash
# Make codex-linux-sandbox compile on 32-bit ARM.
#
#   patches/0001-linux-sandbox-build-on-32-bit-arm.sh <codex source dir>
#
# 1. `libc::SYS_*` is i64 on 64-bit targets and i32 on arm, while seccompiler's
#    rule map is keyed by i64: the deny_syscall helper takes impl Into<i64> and
#    the direct inserts convert — correct on both.
# 2. The architecture selection ends in unimplemented!() for anything that is not
#    x86_64 or aarch64, a panic in the middle of sandbox setup. seccompiler has no
#    32-bit ARM target, and a filter written in another architecture's syscall
#    numbering would deny the wrong calls, so it returns LandlockRestrict instead:
#    the caller reports that the sandbox could not be enforced, which is the truth.
#    This board runs with the sandbox off either way (see README).
#
# Edits by pattern, not by line: upstream moves this code around (landlock.rs ->
# seccomp.rs between 0.162 and 0.163) and a positional diff broke on the first
# move. Every edit must hit, or this fails — a silent no-op would only show up as
# 23 compile errors twenty minutes later.
set -euo pipefail

dir="$1/codex-rs/linux-sandbox/src"
files="$(grep -rl 'unsupported architecture for seccomp filter' "$dir")" \
  || { echo "no seccomp filter source under $dir" >&2; exit 1; }
[ "$(printf '%s\n' "$files" | wc -l)" -eq 1 ] \
  || { printf 'several seccomp filter sources, expected one:\n%s\n' "$files" >&2; exit 1; }

perl -0777 -i -pe '
  s/nr: i64\) \{(\s*)rules\.insert\(nr,/nr: impl Into<i64>) {$1rules.insert(nr.into(),/
    or die "deny_syscall helper not found\n";
  s/rules\.insert\(libc::(SYS_\w+),/rules.insert(i64::from(libc::$1),/g
    or die "no direct libc::SYS_* insert found\n";
  s/unimplemented!\("unsupported architecture for seccomp filter"\);/return Err(SandboxErr::LandlockRestrict);/
    or die "architecture fallback not found\n";
' "$files"
echo "patched $files"
