#!/usr/bin/env bash
# lib-opencode.sh — the OpenCode reviewer, shared by pr-review-relay and review-local.
#
# Sourced, not executed. It exists because the two callers previously carried a
# verbatim copy of the binary resolution, the permission policy and the invocation.
# Cross-review flagged that duplication repeatedly: a security policy kept in two
# places drifts, and here the two copies had already drifted once.
#
# Provides:
#   OPENCODE_BIN            resolved absolute path (or a bare name if unresolvable)
#   OPENCODE_RO_CONFIG      the read-only permission policy, as JSON
#   opencode_resolve_bin    populate OPENCODE_BIN; exits 2 on a bad explicit override
#   opencode_review         run one review; prints it on stdout
#
# Callers must be Bash 3.2-safe (macOS ships 3.2) and run under `set -u`.

# --- Binary resolution -------------------------------------------------------
# OpenCode's official installer puts the binary in ~/.opencode/bin, which is NOT on
# PATH, so a plain `command -v opencode` misses it and the reviewer is skipped
# before anything else can go wrong.
#
# Everything is canonicalized to an ABSOLUTE path because opencode_review() runs
# the agent from a different working directory: a relative override, or even a
# `command -v` result that came from a relative PATH entry, would resolve here and
# then fail to execute there.
#
# "${HOME:-}" rather than "$HOME": under `set -u` a bare $HOME aborts the whole
# script wherever HOME is unset (cron, systemd units, minimal containers).
opencode_abs_path() {
  case "$1" in
    /*) printf '%s' "$1";;
    *)  printf '%s/%s' "$(cd "$(dirname "$1")" 2>/dev/null && pwd)" "$(basename "$1")";;
  esac
}

opencode_resolve_bin() {
  OPENCODE_BIN="${PR_RELAY_OPENCODE_BIN:-}"
  if [ -n "$OPENCODE_BIN" ]; then
    case "$OPENCODE_BIN" in
      */*) ;;                                              # path-ish: canonicalize below
      *)   OPENCODE_BIN="$(command -v "$OPENCODE_BIN" 2>/dev/null || printf '%s' "$OPENCODE_BIN")";;
    esac
    OPENCODE_BIN="$(opencode_abs_path "$OPENCODE_BIN")"
    # Fail fast: a user-supplied override that cannot run is a configuration error,
    # not something to surface minutes later as a vague "not installed" skip.
    [ -x "$OPENCODE_BIN" ] || {
      echo "✖ PR_RELAY_OPENCODE_BIN=${PR_RELAY_OPENCODE_BIN} did not resolve to an executable." >&2
      echo "  Give an absolute path, a relative path, or a name on PATH (a leading ~ is not expanded)." >&2
      exit 2
    }
  elif command -v opencode >/dev/null 2>&1; then
    OPENCODE_BIN="$(opencode_abs_path "$(command -v opencode)")"
  elif [ -x "${HOME:-}/.opencode/bin/opencode" ]; then
    OPENCODE_BIN="${HOME:-}/.opencode/bin/opencode"
  else
    OPENCODE_BIN=opencode   # keep the bare name so the caller's "not installed" path reports it
  fi
}

# --- Read-only policy --------------------------------------------------------
# Applied per invocation through OPENCODE_CONFIG_CONTENT, a runtime override that
# outranks the user's own opencode.json.
#
# DEFAULT-DENY with an explicit read-only allowlist. Five weaker designs were tried
# during cross-review and every one was verified broken by hand before being
# discarded — each looked airtight until it was actually run:
#
#  1. `--agent plan` and nothing else. The Plan agent's permissions stay
#     user-configurable, so on a permissive machine it runs shell straight from PR
#     text — asked to run `id`, it did, and returned real uid/gid.
#  2. Global deny plus a `gh pr view*`/`gh pr diff*` allowlist, so link mode could
#     still fetch. Defeated by shell redirection: `gh pr view N > victim` matches
#     the allowed prefix and overwrote the file despite edit+write deny. Prefix
#     matching cannot make a shell command read-only.
#  3. Global deny with no agent.plan mirror. OpenCode applies agent-scoped
#     permissions AFTER the global ones, so `agent.plan.permission.bash: allow` in
#     a user's config reinstated shell — verified, `id` ran again.
#  4. Denying tools by NAME. Anything not named stays allowed by default, so custom
#     tools and MCP servers remained reachable from prompt-injected PR text.
#  5. Running elsewhere but still reading project config. An `mcp` server declared
#     in the reviewed repo's opencode.json is LAUNCHED at startup, before any
#     permission applies — verified: a planted entry ran its command with
#     '"*": "deny"' and --pure both in force. Hence OPENCODE_DISABLE_PROJECT_CONFIG.
#
# KNOWN, ACCEPTED RESIDUAL: this is not OpenCode's final config layer — managed
# (organization) config merges after it and could re-allow bash. Deliberately not
# defended against, because it is not reachable by the threat this exists for. The
# attacker is whoever authored the branch under review; managed config lives in
# /etc/opencode or /Library/Application Support/opencode, root-owned and not
# writable by a pull request. A permissive org-wide policy is an administrator's
# deliberate machine-wide choice, not something a diff can reach. OPENCODE_PERMISSION
# is not a fix either: it applies later still but sets only the TOP-LEVEL permission
# block, so an agent-scoped allow still wins — verified, bash ran.
OPENCODE_RO_CONFIG='{"permission":{"*":"deny","read":"allow","grep":"allow","glob":"allow","list":"allow"},"agent":{"plan":{"permission":{"*":"deny","read":"allow","grep":"allow","glob":"allow","list":"allow"}}}}'

# --- The invocation ----------------------------------------------------------
# opencode_review <attach_dir> <diff> <prompt> <errfile> <timeout>
#
# Prints the review on stdout; returns the agent's exit code.
#
# The diff is ATTACHED as a file rather than inlined: shell is denied, so the agent
# can never fetch anything itself, and attaching keeps a large diff off the argv
# (Windows caps it near 32K) and sidesteps any inline-fallback size threshold that
# would otherwise leave the reviewer with nothing to read on a big PR.
#
# Run from <attach_dir>, never the repo, AND with OPENCODE_DISABLE_PROJECT_CONFIG=1.
# Both, because the config loader walks UP from its working directory to the
# worktree root: a directory outside the repo is not sufficient on its own if
# TMPDIR happens to sit inside it. Every single-layer defence here has turned out
# to be bypassable, so these stay stacked.
#
# `--pure` skips external plugins, which load and can execute code at startup
# regardless of permissions. `-f` takes an array, so `--` must precede the prompt or
# it is swallowed as another filename and opencode dies with "File not found".
opencode_review() {
  local attach_dir="$1" diff="$2" prompt="$3" errf="$4" agent_timeout="$5"
  local diff_file oc_prompt
  local -a model=()
  [ -n "${PR_RELAY_OPENCODE_MODEL:-}" ] && model=(-m "$PR_RELAY_OPENCODE_MODEL")

  diff_file="$attach_dir/oc-diff"
  printf '%s' "$diff" > "$diff_file"

  # Both callers' base prompts tell the reviewer the change is on stdin, appended,
  # or fetchable with gh. None of that is true here, so say so explicitly instead of
  # leaving the agent to look in a place that no longer exists.
  oc_prompt="$(printf '%s\n\n---\nNOTE — this overrides any instruction above about how to obtain the change:\n- Shell access is disabled for you. `gh` and every other command will be refused; do not attempt them.\n- Nothing is on stdin, nothing is appended below, and you do not have the repository checked out.\n- The complete diff is ATTACHED to this message as a file. It is your only source; review it on its own merits.' "$prompt")"

  ( cd "$attach_dir" && \
    OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_CONFIG_CONTENT="$OPENCODE_RO_CONFIG" \
    timeout "$agent_timeout" "$OPENCODE_BIN" --pure run \
      -f "$diff_file" --agent plan ${model[@]+"${model[@]}"} -- "$oc_prompt" 2>"$errf" )
}
