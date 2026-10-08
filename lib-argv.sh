# lib-argv.sh — the argv size guard, shared by pr-review-relay, review-local and lib-opencode.sh.
#
# Linux caps ONE argv string at MAX_ARG_STRLEN = 131072 bytes, and that count includes the
# terminating NUL. A seat that gets its prompt as one argv element (`qwen -p "$PROMPT"`,
# `agy -p ...`, `opencode -- "$oc_prompt"`) cannot start when the string is over the cap: exec fails
# with E2BIG, the shell reports exit 126, and the round is void with no reason a reader can use.
# This guard refuses such a seat BEFORE it starts, with a named reason.
#
# The default limit is below the kernel's on purpose (a conservative margin). A prompt of 122880-
# 131071 bytes ran before for qwen and antigravity and is now refused.
#
# Sourced, never executed. It sets no shell options and defines functions only.

ARG_STRLEN_DEFAULT=122880
ARG_STRLEN_KERNEL=131072

# Prints the active limit. PR_RELAY_ARGV_MAX_BYTES overrides it FOR TESTS ONLY; a value that is not
# a number, is 0, or is above the kernel's 131072 is rejected (rc 1, nothing printed). The scripts
# run `set -u`, so the variable is read with a default.
argv_limit() {
  local v="${PR_RELAY_ARGV_MAX_BYTES:-}"
  if [ -z "$v" ]; then printf '%s\n' "$ARG_STRLEN_DEFAULT"; return 0; fi
  case "$v" in *[!0-9]*) return 1;; esac
  [ "$v" -ge 1 ] && [ "$v" -le "$ARG_STRLEN_KERNEL" ] || return 1
  printf '%s\n' "$v"
}

# Startup check for the scripts: rc 1 with a message when the override is unusable.
argv_limit_check() {
  argv_limit >/dev/null && return 0
  echo "invalid PR_RELAY_ARGV_MAX_BYTES: '${PR_RELAY_ARGV_MAX_BYTES:-}' (want 1-$ARG_STRLEN_KERNEL; tests only)" >&2
  return 1
}

# Byte count of a string — bytes, not characters ("é" is 2).
argv_bytes() { printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '; }

# True when an argv element of $1 bytes (plus its NUL) is within the limit.
argv_fits() {
  case "${1:-}" in ''|*[!0-9]*) return 1;; esac   # fail closed: an empty or non-numeric size never "fits"
  local lim; lim="$(argv_limit)" || return 1
  [ $(( $1 + 1 )) -le "$lim" ]
}

# The refusal: a named reason on STDERR only. Stdout stays empty, because a non-empty stdout is
# posted as a PR comment even when the exit code is non-zero.
argv_refuse() {
  local seat="$1" bytes="$2" hint="$3" lim
  lim="$(argv_limit 2>/dev/null || printf '%s' "$ARG_STRLEN_DEFAULT")"
  echo "  ! $seat: prompt is $bytes B, over the argv limit ($lim B, counting the terminating NUL) — $hint" >&2
}
