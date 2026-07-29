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
# any repo). Global ~/.grok config/plugins may still load; that is documented in the
# README caveats, not claimed-away. --permission-mode plan overrides a machine
# always-approve config. --deny '*' removes every tool so a malicious PR cannot
# make Grok read secrets from the host filesystem (the built-in read-only sandbox
# still allows reading everywhere). --sandbox read-only is the OS write barrier
# (needs a working sandbox on Linux — typically bubblewrap + user namespaces);
# child network is blocked, so we never tell Grok to run `gh` — the complete diff
# is always in the prompt-file.
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
  local grok_bin timeout_bin

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

  # Resolve binaries BEFORE cd so a relative PATH entry cannot resolve differently
  # (or vanish) inside iso_cwd — same class of guard as opencode_review.
  # A shell function named `grok` would shadow the binary; drop it first.
  unset -f grok 2>/dev/null || true
  grok_bin="$(command -v grok 2>/dev/null)" || {
    echo "grok_review: grok not found on PATH" >&2
    return 127
  }
  # Reject a non-file (e.g. residual function name resolved oddly).
  [ -f "$grok_bin" ] || [ -x "$grok_bin" ] || {
    echo "grok_review: 'grok' is not an executable file ($grok_bin)" >&2
    return 127
  }
  case "$grok_bin" in /*) ;; *) grok_bin="$(cd -- "$(dirname "$grok_bin")" && pwd)/$(basename "$grok_bin")";; esac
  # Refuse a PATH symlink (or binary) that resolves inside the repo under review —
  # same containment as opencode_reject_if_in_repo (already sourced via lib-opencode).
  if command -v opencode_reject_if_in_repo >/dev/null 2>&1; then
    opencode_reject_if_in_repo "$grok_bin"
  fi
  timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  case "$timeout_bin" in
    '') ;;
    /*) ;;
    *) timeout_bin="$(cd -- "$(dirname "$timeout_bin")" && pwd)/$(basename "$timeout_bin")";;
  esac

  # Absolute errf before cd (relative TMPDIR would otherwise write into iso_cwd).
  case "$errf" in /*) ;; *) errf="$(cd -- "$(dirname "$errf")" && pwd)/$(basename "$errf")";; esac

  # Pin PATH to absolute entries so nothing resolves relative to iso_cwd after cd.
  local _p _np="" _IFS="$IFS"
  IFS=':'
  for _p in $PATH; do
    [ -n "$_p" ] || continue
    case "$_p" in
      /*) _np="${_np:+$_np:}$_p";;
      *)
        if [ -d "$_p" ]; then
          _abs="$(cd -- "$_p" 2>/dev/null && pwd)" || continue
          _np="${_np:+$_np:}$_abs"
        fi;;
    esac
  done
  IFS="$_IFS"
  [ -n "$_np" ] && PATH="$_np"
  export PATH

  # Isolated cwd under attach_dir so EXIT trap (which removes ATTACH_DIR) cleans it
  # even if we are interrupted mid-run. Outside any git checkout.
  iso_cwd="$(mktemp -d "$attach_dir/iso-grok.XXXXXX")" || {
    echo "grok_review: cannot create isolated cwd under $attach_dir" >&2
    return 1
  }
  prompt_file="$(mktemp "$attach_dir/grok-prompt.XXXXXX")" || {
    echo "grok_review: cannot create prompt-file under $attach_dir" >&2
    return 1
  }
  case "$prompt_file" in /*) ;; *) prompt_file="$(cd -- "$(dirname "$prompt_file")" && pwd)/$(basename "$prompt_file")";; esac
  case "$iso_cwd" in /*) ;; *) iso_cwd="$(cd -- "$iso_cwd" && pwd)";; esac

  # Build the full prompt. ALWAYS embed the complete diff — Grok cannot run gh
  # under --sandbox read-only, and headless ignores stdin. Do not reuse the
  # relay's size-thresholded $PROMPT (which may omit the diff and tell agents to fetch).
  body="$(printf '%s\n\nYou are reviewing %s.\nThe COMPLETE change is in the fenced DIFF section below. Review that content only - do not require a git checkout, and do not run gh or other network commands. DO NOT modify anything. Be concise. Group findings by severity: Blocker / Should-fix / Nit. If it looks good, say so in one line.\n\n--- DIFF ---\n```diff\n%s\n```\n--- END DIFF ---\n' \
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

  # Pinned argv. No --no-leader (not a top-level flag).
  # --deny '*' : no tools (blocks host filesystem reads via tools; sandbox alone allows reads).
  # --verbatim : send the prompt-file literally (untrusted diff).
  # cd into iso_cwd AND pass --cwd for process-level + project-discovery isolation.
  # </dev/null: avoid inheriting a piped stdin from the relay parent.
  (
    cd "$iso_cwd" || exit 1
    if [ -n "$timeout_bin" ]; then
      "$timeout_bin" "$agent_timeout" "$grok_bin" \
        --prompt-file "$prompt_file" \
        --cwd "$iso_cwd" \
        -m "$model" \
        --reasoning-effort "$effort" \
        --permission-mode plan \
        --sandbox read-only \
        --deny '*' \
        --verbatim \
        --no-memory \
        --no-subagents \
        --disable-web-search \
        --max-turns 40 \
        </dev/null 2>"$errf"
    else
      "$grok_bin" \
        --prompt-file "$prompt_file" \
        --cwd "$iso_cwd" \
        -m "$model" \
        --reasoning-effort "$effort" \
        --permission-mode plan \
        --sandbox read-only \
        --deny '*' \
        --verbatim \
        --no-memory \
        --no-subagents \
        --disable-web-search \
        --max-turns 40 \
        </dev/null 2>"$errf"
    fi
  )
  rc=$?

  # Surface a clearer reason when the sandbox cannot start (missing/unusable bwrap,
  # disabled user namespaces, etc.) — leave the raw stderr in errf for the caller.
  if [ "$rc" -ne 0 ] && [ -s "$errf" ] && grep -qiE 'sandbox|bubblewrap|bwrap|namespace' "$errf" 2>/dev/null; then
    echo "  ! grok: sandbox unavailable (read-only profile needs a working sandbox on Linux — check bubblewrap and user namespaces). See stderr." >&2
  fi
  return "$rc"
}
