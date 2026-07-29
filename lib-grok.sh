# lib-grok.sh — the Grok reviewer, shared by pr-review-relay and review-local.
#
# Why a shared lib: the same anti-drift reason as lib-opencode.sh. Both callers
# must build an identical, fail-closed invocation (isolated cwd, full diff in a
# prompt-file, explicit permission/sandbox flags). Duplicating the case arm is
# how flags and safety posture drift between scripts.
#
# Public API (callers source this file after lib-opencode.sh so relay_trim exists):
#   grok_is_selected   is grok in $REVIEWERS and not $AUTHOR?
#   grok_review        run one review; prints it on stdout, returns the agent's exit code
#
# Grok headless does NOT read piped stdin — the plan/diff MUST go in --prompt-file.
# Project discovery loads checkout-scoped .grok from cwd before tool permissions,
# so we always run with --cwd pointed at an empty dir under $attach_dir (outside
# any repo). Global ~/.grok config/plugins may still load; that is documented, not
# claimed-away. --permission-mode plan overrides a machine always-approve config.
# --sandbox read-only is the OS write barrier (needs a working sandbox on Linux —
# typically bubblewrap + user namespaces); child network is blocked, so we never
# tell Grok to run `gh` — the complete diff is always in the prompt-file.
#
# Default model: grok-4.5. Default PR-review effort: medium (plan-review uses a
# different name/effort in ship-feature). Override with GROK_REVIEW_MODEL /
# GROK_REVIEW_EFFORT env if needed later; not advertised yet.

# --- Reviewer selection ------------------------------------------------------
# Reads $REVIEWERS and $AUTHOR from the caller. Same trim rules as opencode_is_selected.
grok_is_selected() {
  local _r; local -a _list=()
  IFS=',' read -ra _list <<< "$REVIEWERS"
  for _r in ${_list[@]+"${_list[@]}"}; do
    _r="$(relay_trim "$_r")"
    [ "$_r" = grok ] && [ "$_r" != "$AUTHOR" ] && return 0
  done
  return 1
}

# grok_review <attach_dir> <diff> <context_block> <subject> <errfile> <timeout>
#
# Writes a prompt-file under attach_dir (NOT STATUS_DIR — that would poison the
# outcome tally) containing context + full diff, runs grok from an isolated cwd
# under attach_dir, prints the review on stdout, returns the agent exit code.
# Fail-closed on prompt write failures (empty/truncated).
grok_review() {
  local attach_dir="$1" diff="$2" context_block="$3" subject="$4" errf="$5" agent_timeout="$6"
  local iso_cwd prompt_file body expected_bytes actual_bytes model effort rc=0

  [ -n "$attach_dir" ] && [ -d "$attach_dir" ] || {
    echo "grok_review: attach_dir missing or not a directory" >&2
    return 1
  }
  [ -n "$errf" ] || {
    echo "grok_review: errfile path required" >&2
    return 1
  }

  model="${GROK_REVIEW_MODEL:-grok-4.5}"
  effort="${GROK_REVIEW_EFFORT:-medium}"

  # Isolated cwd under attach_dir so EXIT trap (which removes ATTACH_DIR) cleans it
  # even if we are interrupted mid-run. Outside any git checkout.
  iso_cwd="$(mktemp -d "$attach_dir/iso-grok.XXXXXX")" || {
    echo "grok_review: cannot create isolated cwd under $attach_dir" >&2
    return 1
  }
  prompt_file="$attach_dir/grok-prompt-$$.txt"
  # Absolute path: after we cd into iso_cwd the relative form would break.
  case "$prompt_file" in /*) ;; *) prompt_file="$(cd -- "$(dirname "$prompt_file")" && pwd)/$(basename "$prompt_file")";; esac
  case "$iso_cwd" in /*) ;; *) iso_cwd="$(cd -- "$iso_cwd" && pwd)";; esac

  # Build the full prompt. ALWAYS embed the complete diff — Grok cannot run gh
  # under --sandbox read-only, and headless ignores stdin. Do not reuse the
  # relay's size-thresholded $PROMPT (which may omit the diff and tell agents to fetch).
  body="$(printf '%s\n\nYou are reviewing %s.\nThe COMPLETE change is in the DIFF section below. Review that content only - do not require a git checkout, and do not run gh or other network commands. DO NOT modify anything. Be concise. Group findings by severity: Blocker / Should-fix / Nit. If it looks good, say so in one line.\n\n--- DIFF ---\n%s\n' \
    "${context_block}" \
    "$subject" \
    "$diff")"

  # Write + verify complete (same class of guard as opencode's attach path).
  if ! printf '%s' "$body" > "$prompt_file"; then
    echo "grok_review: failed to write prompt-file" >&2
    return 1
  fi
  expected_bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')
  actual_bytes=$(wc -c < "$prompt_file" | tr -d ' ')
  if [ -z "$actual_bytes" ] || [ "$actual_bytes" = 0 ] || [ "$actual_bytes" != "$expected_bytes" ]; then
    echo "grok_review: prompt-file write incomplete (expected ${expected_bytes}B, got ${actual_bytes:-0}B)" >&2
    return 1
  fi

  # Pinned argv (see ship-feature plan 2026-07-29). No --no-leader (not a top-level flag).
  # stderr → errf; stdout is the review text the caller posts/prints.
  # cd into iso_cwd AND pass --cwd: process-level isolation (kimi3 pattern) so a
  # stub/test can see the cwd, and Grok's own project discovery uses the empty dir.
  # </dev/null: avoid inheriting a piped stdin from the relay parent.
  # prompt_file stays under attach_dir (absolute path), so it remains readable after cd.
  (
    cd "$iso_cwd" || exit 1
    timeout "$agent_timeout" grok \
      --prompt-file "$prompt_file" \
      --cwd "$iso_cwd" \
      -m "$model" \
      --reasoning-effort "$effort" \
      --permission-mode plan \
      --sandbox read-only \
      --no-memory \
      --no-subagents \
      --disable-web-search \
      --max-turns 40 \
      </dev/null 2>"$errf"
  )
  rc=$?

  # Surface a clearer reason when the sandbox cannot start (missing/unusable bwrap,
  # disabled user namespaces, etc.) — leave the raw stderr in errf for the caller.
  if [ "$rc" -ne 0 ] && [ -s "$errf" ] && grep -qiE 'sandbox|bubblewrap|bwrap|namespace' "$errf" 2>/dev/null; then
    echo "  ! grok: sandbox unavailable (read-only profile needs a working sandbox on Linux — check bubblewrap and user namespaces). See stderr." >&2
  fi
  return "$rc"
}
