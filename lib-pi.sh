# lib-pi.sh — the pi reviewer seats (pi_glm, pi_grok), shared by pr-review-relay and review-local.
#
# Why a shared lib: the same anti-drift reason as lib-opencode.sh and lib-grok.sh. Both callers
# must build an identical, fail-closed invocation, and a posture kept in two places drifts.
#
# Public API (callers source this file after lib-grok.sh, so relay_trim, opencode_abs_path and
# opencode_target_in_repo from lib-opencode.sh exist):
#   PI_BIN              resolved absolute path, or the bare name `pi` when it is not installed
#   pi_is_selected      is pi_glm or pi_grok in $REVIEWERS and not $AUTHOR?
#   pi_resolve_bin      populate PI_BIN; exits 2 when pi resolves inside the checkout under review
#   pi_resolve_model / pi_resolve_effort <seat>
#   pi_review           run one review; prints it on stdout, returns the seat's exit code
#   PI_FINAL_TEXT_JS    the json stream reader (node), a fixed literal
#
# One binary, two seats: pi (https://pi.dev, tested with 1.1.0) talks to many providers, and each
# seat is one model through it. Default models: pi_glm = zai/glm-5.3, pi_grok = xai/grok-4.7.
# Pinned by MODEL_<seat> / EFFORT_<seat> in ~/.config/pr-review-relay/config, or
# PI_GLM_REVIEW_MODEL / PI_GLM_REVIEW_EFFORT / PI_GROK_REVIEW_MODEL / PI_GROK_REVIEW_EFFORT.
#
# Posture: the seat has NO tools (--no-tools), runs from an empty directory under $attach_dir,
# and gets the whole prompt — context, instructions, the complete diff — on stdin. It cannot read
# the checkout or the host, so a PR cannot talk it into reading secrets into a public comment. The
# other --no-* flags keep pi's own discovery out of the run: no extensions (an installed one could
# forward the diff), no MCP servers, no skills, no prompt templates, no themes, no AGENTS.md
# context files, no project-local files, no saved session (it would keep the diff under ~/.pi), and
# no startup network calls. Every flag is in pi 1.1.0's --help, and pi refuses an option it does
# not know, so a later pi that renames one fails both seats loudly ("Unknown option").
#
# Why json mode and a reader, not plain text: pi's exit code does not say whether a review came
# back. In text mode a `length` stop (the model ran out of output tokens) exits 0 with a truncated
# or empty review; in json mode even an API error exits 0. The seat decides from the final
# assistant message's stopReason instead: only `stop` with some text is a review. Everything else
# prints nothing on stdout and one reason line on stderr — the line the relay shows, and the text
# its quota bench reads (an out-of-quota error arrives as that message's errorMessage).
#
# The effort goes to --thinking. pi does NOT refuse a level it does not know: it warns, falls back
# to the level in the user's own settings, and exits 0 (measured with 1.1.0). So the level is
# checked here, against the list pi prints, before anything starts.

# Defined at source time so `set -u` callers can read it when no pi seat was selected and
# pi_resolve_bin therefore never ran.
PI_BIN=pi

# The levels pi 1.1.0 accepts for --thinking, from its own "Invalid thinking level" warning.
PI_EFFORT_LEVELS="off minimal low medium high xhigh max"

# --- Model and effort --------------------------------------------------------
# One resolver each, used by pi_review AND by the dispatch line (panel_seat_pins), so the line
# always shows what the seat actually runs.
#
# Both efforts default to `low`. Measured on a 298 KB diff with a 33 KB context file: glm-5.3 at
# `low` finished in 120 s, grok-4.7 at `low` in 352 s — both inside the shipped 500 s AGENT_TIMEOUT. At
# `medium` they took 731 s and 792 s, which fit only a 900 s timeout. Pin `medium` in the config
# together with AGENT_TIMEOUT=900 or more.
pi_resolve_model() { # <seat>
  case "$1" in
    pi_glm)  panel_resolve PI_GLM_REVIEW_MODEL MODEL_pi_glm zai/glm-5.3 ;;
    pi_grok) panel_resolve PI_GROK_REVIEW_MODEL MODEL_pi_grok xai/grok-4.7 ;;
  esac
}
pi_resolve_effort() { # <seat>
  case "$1" in
    pi_glm)  panel_resolve PI_GLM_REVIEW_EFFORT EFFORT_pi_glm low ;;
    pi_grok) panel_resolve PI_GROK_REVIEW_EFFORT EFFORT_pi_grok low ;;
  esac
}

# --- Reviewer selection ------------------------------------------------------
# Reads $REVIEWERS and $AUTHOR from the caller. Same trim rules as opencode_is_selected.
pi_is_selected() {
  local _r; local -a _list=()
  IFS=',' read -ra _list <<< "$REVIEWERS"
  for _r in ${_list[@]+"${_list[@]}"}; do
    _r="$(relay_trim "$_r")"
    case "$_r" in
      pi_glm|pi_grok) [ "$_r" != "$AUTHOR" ] && return 0 ;;
    esac
  done
  return 1
}

# --- Binary resolution -------------------------------------------------------
# Runs at startup, where opencode_resolve_bin runs, so a refusal stops the whole relay before any
# seat starts. That is opencode's posture, chosen on purpose: a `pi` on a trusted PATH directory
# that resolves into the branch under review means the branch author already steers the
# environment, and relay_assert_path_outside_repo answers a hostile PATH entry the same way.
#
# Not opencode_reject_if_in_repo: its text tells the user to change PR_RELAY_OPENCODE_BIN, which
# has nothing to do with pi. There is no PR_RELAY_PI_BIN override on purpose: nothing needs one,
# and every override lib-opencode.sh grew became a containment case of its own.
pi_resolve_bin() {
  local _t
  # A shell FUNCTION named `pi` would shadow the binary in `command -v`.
  unset -f pi 2>/dev/null || true
  if command -v pi >/dev/null 2>&1; then
    PI_BIN="$(opencode_abs_path "$(command -v pi)")"
    if _t="$(opencode_target_in_repo "$PI_BIN")"; then
      echo "✖ refusing to run pi: '$PI_BIN' resolves to '$_t', inside the repository being reviewed." >&2
      echo "  A PATH lookup found it in the checkout (a '.' entry, a repo-local bin dir, or a symlink" >&2
      echo "  from a trusted directory). Fix PATH so that 'pi' resolves outside the repository." >&2
      exit 2
    fi
  else
    PI_BIN=pi   # keep the bare name so the caller's "not installed" path reports it
  fi
}

# --- The stream reader -------------------------------------------------------
# Reads pi's --mode json event stream on stdin, one line at a time (the largest line is the prompt
# echo, about the prompt's size). Keeps the LAST message_end whose message.role is "assistant",
# and at the end reads exactly these fields of it: stopReason, content[] entries of type "text",
# errorMessage, usage.output.
#   stop + non-blank text -> print the text, exit 0
#   anything else         -> nothing on stdout, ONE line on stderr, exit 3
# A line that is not JSON is skipped. A missing field never throws: the reason line is the only
# stderr output, never a stack trace.
IFS= read -r -d '' PI_FINAL_TEXT_JS <<'JS' || true
const rl = require("readline").createInterface({ input: process.stdin, crlfDelay: Infinity });
let last = null;
rl.on("line", (line) => {
  let e;
  try { e = JSON.parse(line); } catch (_) { return; }
  if (e && e.type === "message_end" && e.message && e.message.role === "assistant") last = e.message;
});
rl.on("close", () => {
  if (!last) {
    process.stderr.write("pi: the event stream ended without a final assistant message\n");
    process.exitCode = 3;
    return;
  }
  const parts = Array.isArray(last.content) ? last.content : [];
  const text = parts
    .filter((p) => p && p.type === "text" && typeof p.text === "string")
    .map((p) => p.text)
    .join("\n");
  const stop = typeof last.stopReason === "string" ? last.stopReason : "?";
  if (stop === "stop" && text.trim() !== "") {
    process.stdout.write(text.endsWith("\n") ? text : text + "\n");
    return;
  }
  const tokens = last.usage && last.usage.output != null ? String(last.usage.output) : "?";
  let reason = `pi: no usable review (stopReason=${stop}, output tokens=${tokens}, text chars=${text.length})`;
  if (typeof last.errorMessage === "string" && last.errorMessage !== "") {
    reason += ": " + last.errorMessage.replace(/[\r\n]+/g, " ");
  }
  process.stderr.write(reason + "\n");
  process.exitCode = 3;
});
JS

# pi_review <seat> <attach_dir> <diff> <context_block> <subject> <errfile> <timeout>
#
# Writes a prompt file under attach_dir (NOT STATUS_DIR — that would poison the outcome tally),
# runs pi from an isolated cwd under attach_dir with the prompt on stdin, prints the review on
# stdout. The exit code: pi's own non-zero status wins (124 stays 124, so the caller still says
# "timed out"), otherwise the reader's (0, or 3 with the reason on the errfile).
# Every refusal before the model call writes its reason to the errfile and returns 1.
pi_review() {
  local seat="$1" attach_dir="$2" diff="$3" context_block="$4" subject="$5" errf="$6" agent_timeout="$7"
  local model effort pi_bin timeout_bin node_bin iso_cwd prompt_file body expected_bytes actual_bytes
  local _p _abs _np="" _IFS rc=0

  [ -n "$attach_dir" ] && [ -d "$attach_dir" ] || {
    echo "pi_review: attach_dir missing or not a directory" >&2
    return 1
  }
  [ -n "$errf" ] || {
    echo "pi_review: errfile path required" >&2
    return 1
  }
  # Absolute errf before any cd (a relative TMPDIR would otherwise write into iso_cwd).
  errf="$(opencode_abs_path "$errf")"

  case "$seat" in
    pi_glm|pi_grok) ;;
    *) echo "pi_review: unknown seat '$seat'" >> "$errf"; return 1 ;;
  esac
  model="$(pi_resolve_model "$seat")"
  effort="$(pi_resolve_effort "$seat")"
  # Exact alternatives, never a match against the list: the value is config text, so as a pattern
  # `low medium`, `*` or `l?w` would pass. Keep in step with PI_EFFORT_LEVELS (a test pins it).
  case "$effort" in
    off|minimal|low|medium|high|xhigh|max) ;;
    *)
      echo "pi: invalid effort '$effort' for $seat (EFFORT_$seat / $(printf '%s' "$seat" | tr '[:lower:]' '[:upper:]')_REVIEW_EFFORT); valid: $PI_EFFORT_LEVELS" >> "$errf"
      return 1 ;;
  esac

  # Resolve every binary BEFORE anything starts and before the cd: the model call never starts
  # without its wall-clock limit or its reader. The asymmetry with pi_resolve_bin is deliberate:
  # a missing tool is an environment gap that costs only this seat; a pi inside the branch under
  # review is the branch steering the relay, which stops everything.
  pi_bin="$PI_BIN"
  case "$pi_bin" in
    /*) ;;
    *) echo "pi: PI_BIN is not an absolute path ($pi_bin) — pi_resolve_bin did not run" >> "$errf"; return 1 ;;
  esac
  { [ -f "$pi_bin" ] && [ -x "$pi_bin" ]; } || {
    echo "pi: '$pi_bin' is not an executable file" >> "$errf"
    return 1
  }
  timeout_bin="$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || true)"
  [ -n "$timeout_bin" ] || {
    # Without a wall-clock limit a hung pi burns the round forever. (macOS: brew install coreutils)
    echo "pi: neither timeout nor gtimeout found — refuse to run without a wall-clock limit" >> "$errf"
    return 1
  }
  timeout_bin="$(opencode_abs_path "$timeout_bin")"
  node_bin="$(command -v node 2>/dev/null || true)"
  [ -n "$node_bin" ] || {
    echo "pi: node not found — it reads pi's json stream; refuse to start the model call without it" >> "$errf"
    return 1
  }
  node_bin="$(opencode_abs_path "$node_bin")"

  # PATH from absolute entries only, so nothing resolves relative to iso_cwd after the cd.
  _IFS="$IFS"; IFS=':'
  for _p in $PATH; do
    [ -n "$_p" ] || continue
    case "$_p" in
      /*) _np="${_np:+$_np:}$_p" ;;
      *)
        if [ -d "$_p" ]; then
          _abs="$(cd -- "$_p" 2>/dev/null && pwd)" || continue
          _np="${_np:+$_np:}$_abs"
        fi ;;
    esac
  done
  IFS="$_IFS"
  [ -n "$_np" ] || _np="$PATH"

  # Isolated cwd under attach_dir, so the caller's EXIT trap (which removes ATTACH_DIR) cleans it
  # even when the run is interrupted. Outside any git checkout, and empty.
  iso_cwd="$(mktemp -d "$attach_dir/iso-pi.XXXXXX")" || {
    echo "pi: cannot create an isolated cwd under $attach_dir" >> "$errf"
    return 1
  }
  prompt_file="$(mktemp "$attach_dir/pi-prompt.XXXXXX")" || {
    echo "pi: cannot create a prompt file under $attach_dir" >> "$errf"
    return 1
  }
  iso_cwd="$(opencode_abs_path "$iso_cwd")"
  prompt_file="$(opencode_abs_path "$prompt_file")"

  # The full prompt. ALWAYS the complete diff: the seat has no checkout, no tool and no network.
  # Do not reuse the relay's size-thresholded $PROMPT, which may omit the diff and tell agents to
  # fetch it.
  body="$(printf '%s\n\nYou are reviewing %s.\nYou have no checkout, no tools and no network. The COMPLETE change is in the fenced DIFF section below: review that content only. DO NOT modify anything. Look for correctness bugs, security issues, broken edge cases, regressions, missing or inadequate tests for the behaviour the change touches, and clear design or maintainability problems. Give a file and line reference for every finding where one applies. Report missing tests as Should-fix, unless the untested path is itself a Blocker. Be concise. Group findings by severity: Blocker / Should-fix / Nit. If it looks good, say so in one line.%s\n\n--- DIFF ---\n```diff\n%s\n```\n--- END DIFF ---\n' \
    "${context_block}" \
    "$subject" \
    "${PR_RELAY_VERDICT_RULES:+ $PR_RELAY_VERDICT_RULES}" \
    "$diff")"

  # Write, then verify it is complete (same guard as grok's prompt file).
  if ! printf '%s' "$body" > "$prompt_file"; then
    echo "pi: failed to write the prompt file" >> "$errf"
    return 1
  fi
  expected_bytes=$(printf '%s' "$body" | wc -c | tr -d ' ')
  actual_bytes=$(wc -c < "$prompt_file" | tr -d ' ')
  if [ -z "$actual_bytes" ] || [ "$actual_bytes" = 0 ] || [ "$actual_bytes" != "$expected_bytes" ]; then
    echo "pi: prompt file write incomplete (expected ${expected_bytes}B, got ${actual_bytes:-0}B)" >> "$errf"
    return 1
  fi

  # The cd, the pipeline and the exit decision run in ONE subshell, so PIPESTATUS is read in the
  # shell that ran the pipeline and saved whole before any other command resets it. Reading
  # PIPESTATUS[1] after an assignment to PIPESTATUS[0]'s value is an unbound variable under set -u.
  # -p: run once and exit; with no message argument, stdin is the whole prompt.
  (
    cd "$iso_cwd" || exit 1
    export PATH="$_np"
    "$timeout_bin" "$agent_timeout" "$pi_bin" -p --mode json --model "$model" --thinking "$effort" \
      --no-tools --no-extensions --no-mcp --no-skills --no-prompt-templates --no-themes \
      --no-context-files --no-approve --no-session --offline \
      < "$prompt_file" 2>> "$errf" \
    | "$node_bin" -e "$PI_FINAL_TEXT_JS" 2>> "$errf"
    _ps=("${PIPESTATUS[@]}")
    [ "${_ps[0]}" -ne 0 ] && exit "${_ps[0]}"
    exit "${_ps[1]}"
  )
  rc=$?
  return "$rc"
}
