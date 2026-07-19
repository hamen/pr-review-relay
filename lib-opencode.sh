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
#   opencode_review         run one review; prints it on stdout, returns the agent's exit code
#   opencode_is_selected    is opencode in $REVIEWERS and not $AUTHOR?
#   relay_trim              trim surrounding whitespace (shared normalization)
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
  local _dir
  case "$1" in
    /*) printf '%s' "$1"; return;;
  esac
  # If the directory doesn't exist the cd fails and $(...) is empty, which would
  # fabricate "/opencode" and make the validation error name a file the user never
  # typed. Hand the original back instead, so the message quotes what they wrote.
  # pwd -P: the containment check below compares this against the git toplevel, and
  # git reports a PHYSICAL path. Entering the checkout through a symlink would
  # otherwise give /symlink/opencode vs /real/repo — no prefix match, guard bypassed.
  _dir="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || _dir=""
  if [ -n "$_dir" ]; then printf '%s/%s' "$_dir" "$(basename "$1")"
  else printf '%s' "$1"; fi
}

# Defined at source time so `set -u` callers can reference it even when the
# reviewer was never selected and opencode_resolve_bin() therefore never ran.
OPENCODE_BIN=opencode

# A PATH lookup can resolve a file from the checkout we are about to review — a "."
# entry, or a repo-local bin dir. That file is written by the same person as the
# diff, and executing it precedes every OpenCode-level defence: --pure, the deny
# policy, all of it. So ANY resolution that went through PATH is checked, including
# a bare PR_RELAY_OPENCODE_BIN, which is a PATH lookup and not a trusted path.
#
# Only an override containing a "/" is exempt: naming a specific file is the user's
# deliberate decision, and cannot be caused by a pull request.
#
# Both sides are compared physically (pwd -P): git reports a physical toplevel while
# $PWD stays logical, so entering the checkout through a symlink would otherwise
# slip past a prefix comparison.
# Follow the whole symlink chain. `readlink -f` is not portable (older macOS has no
# -f), so walk it. Bounded, because a symlink loop would otherwise hang.
opencode_resolve_symlinks() {
  local _p="$1" _t _n=0
  while [ -L "$_p" ]; do
    if [ "$_n" -gt 40 ]; then
      echo "✖ '$1' has a symlink chain over 40 links deep, or a loop — refusing to resolve it." >&2
      echo "  If this is a legitimate deep install, point PR_RELAY_OPENCODE_BIN at the real file." >&2
      exit 2
    fi
    _t="$(readlink "$_p")" || break
    case "$_t" in
      /*) _p="$_t";;
      *)  _p="$(dirname "$_p")/$_t";;
    esac
    _n=$((_n + 1))
  done
  local _d
  _d="$(cd "$(dirname "$_p")" 2>/dev/null && pwd -P)" || _d=""
  # A broken chain would otherwise fabricate "/name"; hand back what we have so the
  # caller compares something real.
  if [ -n "$_d" ]; then printf '%s/%s' "$_d" "$(basename "$_p")"; else printf '%s' "$_p"; fi
}

# Shared by the hard refusal and the softer warning: prints the resolved target if
# it is inside the worktree, nothing otherwise.
opencode_target_in_repo() {
  local _root _target
  _root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$_root" ] || return 1
  _root="$(cd "$_root" 2>/dev/null && pwd -P)" || return 1
  _target="$(opencode_resolve_symlinks "$1")" || return 1
  case "$_target" in "$_root"/*) printf '%s' "$_target";; *) return 1;; esac
}

opencode_warn_if_in_repo() {
  local _t
  _t="$(opencode_target_in_repo "$1")" || return 0
  echo "  ! PR_RELAY_OPENCODE_BIN resolves to '$_t', inside the repository being reviewed." >&2
  echo "    Running it anyway because you named a path explicitly — but if that was a typo," >&2
  echo "    you are about to execute a file from the branch under review." >&2
}

opencode_reject_if_in_repo() {
  local _root _target
  _root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$_root" ] || return 0          # no worktree → nothing under review to contain
  _root="$(cd "$_root" 2>/dev/null && pwd -P)" || return 0
  # Check what the name actually RESOLVES to, not the name itself: a trusted PATH
  # directory can hold `opencode -> <reviewed-repo>/malicious`, and canonicalizing
  # only the parent directory would wave that straight through.
  _target="$(opencode_target_in_repo "$1")" || return 0
  echo "✖ refusing to run '$1': it resolves to '$_target', inside the repository being reviewed." >&2
  echo "  A PATH lookup found it in the checkout (a '.' entry, a repo-local bin dir, or a" >&2
  echo "  bare PR_RELAY_OPENCODE_BIN). Fix PATH, or give PR_RELAY_OPENCODE_BIN a path" >&2
  echo "  containing '/' that points outside the repository." >&2
  exit 2
}

# Only call this when the opencode reviewer is actually selected: it exits 2 on an
# unusable explicit override, and an optional reviewer must not break a run that
# didn't ask for it.
# The relay runs `gh`, `git`, `mktemp`, `node`, `timeout`, `stat`, `sed`, `awk` and
# more, all resolved through PATH. If PATH contains a directory inside the checkout
# under review, the branch author controls every one of those — `gh` runs before
# anything else, so this is decided long before any OpenCode-level policy applies.
#
# Hardening one command (say, `timeout`) would be theatre while the rest stay
# exposed, so the check is on PATH itself: refuse to run at all. One check, whole
# class.
#
# LIMIT, stated rather than papered over: this cannot protect the INTERPRETER. By
# the time any line of the script runs, `#!/usr/bin/env bash` has already chosen a
# bash — through the same PATH. A hostile PATH is therefore only fully defensible
# before invocation, which is outside this script's reach: if PATH already points
# into an untrusted checkout, every command the user types is compromised, not just
# this one. What the guard does cover is everything from the first line onward, and
# SCRIPT_DIR is computed with builtins so even the library path cannot be steered. Entries are compared physically, since a symlinked PATH entry pointing
# into the checkout is the same problem wearing a different name.
# Find the worktree root using ONLY shell builtins — cd, pwd, [ — and no external
# command. `git rev-parse` cannot be used here: git is itself resolved through the
# PATH this function exists to validate, so a repo-local `git` could report an empty
# root and switch the guard off. Bootstrapping a PATH check with a PATH lookup is
# circular; walking up for .git is not.
relay_worktree_root() {
  local _d
  _d="$(pwd -P)" || return 1
  while [ "$_d" != "/" ] && [ -n "$_d" ]; do
    [ -e "$_d/.git" ] && { printf '%s' "$_d"; return 0; }
    _d="$(cd "$_d/.." 2>/dev/null && pwd -P)" || return 1
  done
  [ -e "/.git" ] && { printf '/'; return 0; }
  return 1
}

# Print the leading comment block as help, using only builtins. `awk`/`sed` are
# PATH-resolved and --help is parsed before the PATH guard can run, so rendering
# help used to execute a repo-controlled binary on a hostile PATH — for a flag whose
# entire job is to print text.
relay_print_header() {
  local _file="$1" _max="${2:-0}" _line _n=0
  while IFS= read -r _line; do
    _n=$((_n + 1))
    [ "$_n" = 1 ] && continue                    # shebang
    [ "$_max" != 0 ] && [ "$_n" -gt "$_max" ] && break
    case "$_line" in
      '#'*) _line="${_line#\#}"; printf '%s\n' "${_line# }";;
      *) [ "$_max" = 0 ] && break;;
    esac
  done < "$_file"
}

# Walk up until something exists, so a not-yet-created PATH entry is still judged
# against where it WOULD live. Builtins only, same reason as relay_worktree_root.
relay_nearest_existing_dir() {
  local _d="$1" _out="" _seg _rest
  case "$_d" in /*) ;; *) _d="$(pwd -P)/$_d";; esac
  # Collapse "." and ".." textually first: without this, "/trusted/../repo/bin" is
  # judged against /trusted instead of the repo it actually points into.
  _rest="${_d#/}/"
  while [ -n "$_rest" ] && [ "$_rest" != "/" ]; do
    _seg="${_rest%%/*}"; _rest="${_rest#*/}"
    case "$_seg" in
      ''|'.') ;;
      '..')   _out="${_out%/*}";;
      *)      _out="$_out/$_seg";;
    esac
  done
  _d="${_out:-/}"
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    if [ -d "$_d" ]; then (cd "$_d" 2>/dev/null && pwd -P); return 0; fi
    _d="${_d%/*}"
    [ -n "$_d" ] || _d="/"
  done
  printf '/'
}

relay_assert_path_outside_repo() {
  local _root _entry _resolved _rest
  _root="$(relay_worktree_root)" || return 0
  [ -n "$_root" ] || return 0
  # Split manually rather than with `for _entry in $PATH` under IFS=':'. Word
  # splitting DROPS a trailing empty field, and an empty field means "the current
  # directory" — so "PATH=/usr/bin:" would have sailed past this check while the
  # shell happily resolved commands from the checkout. Same for a leading or
  # doubled colon. The sentinel makes every field, including empty ones, iterate.
  [ -n "${PATH:-}" ] || { echo "✖ PATH is empty — refusing to run." >&2; exit 2; }
  _rest="$PATH:"
  while [ -n "$_rest" ]; do
    _entry="${_rest%%:*}"
    _rest="${_rest#*:}"
    [ -n "$_entry" ] || _entry="."          # empty field == current directory
    # An entry that does not exist YET is not safe to skip: the unsandboxed
    # reviewers run with write access, so one of them can create it mid-round and
    # every later command resolves from there. Judge it by its nearest existing
    # ancestor — if that is inside the checkout, so is anything created under it.
    _resolved="$(cd "$_entry" 2>/dev/null && pwd -P)" || _resolved="$(relay_nearest_existing_dir "$_entry")"
    [ -n "$_resolved" ] || continue
    case "$_resolved" in
      "$_root"|"$_root"/*)
        echo "✖ PATH entry '$_entry' is inside the repository being reviewed." >&2
        echo "  Every command the relay runs (gh, git, timeout, node, …) would be resolved from" >&2
        echo "  the branch under review. Remove that entry from PATH and re-run." >&2
        exit 2;;
    esac
  done
}

opencode_resolve_bin() {
  # A shell FUNCTION named `opencode` would shadow the binary in `command -v` and
  # leave OPENCODE_BIN pointing at something that is not a file. Nothing here
  # defines one, but a sourced profile could. (Aliases need no handling: they are
  # not expanded in a non-interactive shell.)
  unset -f opencode 2>/dev/null || true
  OPENCODE_BIN="${PR_RELAY_OPENCODE_BIN:-}"
  if [ -n "$OPENCODE_BIN" ]; then
    # A leading "~" is shell syntax, not part of a path: by the time it reaches an
    # env var it is a literal character, so expand it rather than failing on a form
    # users reasonably expect to work.
    case "$OPENCODE_BIN" in
      '~/'*) OPENCODE_BIN="${HOME:-}/${OPENCODE_BIN#\~/}";;
    esac
    case "$OPENCODE_BIN" in
      */*)
        OPENCODE_BIN="$(opencode_abs_path "$OPENCODE_BIN")"
        # A path you typed is exempt from the hard refusal — that is the escape
        # hatch — but a typo or a stale relative path can still land inside the
        # checkout, so say so rather than letting it pass in silence.
        opencode_warn_if_in_repo "$OPENCODE_BIN";;
      *)
        # A BARE name means "on PATH", so resolve it there and nowhere else — never
        # fall back to the literal name, which opencode_abs_path would turn into
        # $PWD/opencode. And because this IS a PATH lookup, it gets the same
        # containment check as implicit resolution.
        OPENCODE_BIN="$(command -v "$OPENCODE_BIN" 2>/dev/null || true)"
        [ -n "$OPENCODE_BIN" ] || {
          echo "✖ PR_RELAY_OPENCODE_BIN=${PR_RELAY_OPENCODE_BIN} is not on PATH." >&2
          echo "  Give a path (absolute or relative) if you did not mean a PATH lookup." >&2
          exit 2
        }
        OPENCODE_BIN="$(opencode_abs_path "$OPENCODE_BIN")"
        opencode_reject_if_in_repo "$OPENCODE_BIN";;
    esac
    # Fail fast: a user-supplied override that cannot run is a configuration error,
    # not something to surface minutes later as a vague "not installed" skip.
    # -x alone is true for a DIRECTORY, which would pass here and then fail at
    # launch with a confusing error; require a regular file too.
    { [ -f "$OPENCODE_BIN" ] && [ -x "$OPENCODE_BIN" ]; } || {
      echo "✖ PR_RELAY_OPENCODE_BIN=${PR_RELAY_OPENCODE_BIN} did not resolve to an executable." >&2
      echo "  Give an absolute path, a relative path, or a name on PATH (a leading ~ is not expanded)." >&2
      exit 2
    }
  elif command -v opencode >/dev/null 2>&1; then
    OPENCODE_BIN="$(opencode_abs_path "$(command -v opencode)")"
    opencode_reject_if_in_repo "$OPENCODE_BIN"
  elif [ -n "${HOME:-}" ] && [ -f "$HOME/.opencode/bin/opencode" ] && [ -x "$HOME/.opencode/bin/opencode" ]; then
    # Guard on HOME being set, not just default it to empty: with HOME unset the
    # test would probe "/.opencode/bin/opencode", a path in the filesystem root
    # that nothing should ever be looking at.
    OPENCODE_BIN="$(opencode_abs_path "$HOME/.opencode/bin/opencode")"
    # HOME can itself sit inside the checkout, in which case .opencode/bin/opencode
    # is PR-controlled. Every resolution branch gets the same check — this is the
    # third time a branch was missing it.
    opencode_reject_if_in_repo "$OPENCODE_BIN"
  else
    OPENCODE_BIN=opencode   # keep the bare name so the caller's "not installed" path reports it
  fi
}

# --- Read-only policy --------------------------------------------------------
# Applied per invocation through OPENCODE_CONFIG_CONTENT, a runtime override that
# outranks the user's own opencode.json.
#
# DEFAULT-DENY with an explicit read-only allowlist. Seven weaker designs were tried
# during cross-review and every one was verified broken by hand before being
# discarded — each looked airtight until it was actually run:
#
#  0'. Selecting OpenCode's built-in `plan` agent. Its MODE is configurable: a
#     config with `agent.plan.mode: "subagent"` makes OpenCode warn and fall back to
#     `build`, which then picks up whatever permissions that agent has — verified,
#     `id` ran. So the relay defines and selects its OWN primary agent instead, whose
#     mode and permissions are both fixed here and cannot be redirected.
#  0. The original invocation, `--dangerously-skip-permissions`. Absent from
#     `opencode run --help`, which is misleading: the binary accepts it as an
#     undocumented alias for --auto, so it approved everything rather than erroring.
#  1. `--agent pr-review-relay-ro` and nothing else. The Plan agent's permissions stay
#     user-configurable, so on a permissive machine it runs shell straight from PR
#     text — asked to run `id`, it did, and returned real uid/gid.
#  2. Global deny plus a `gh pr view*`/`gh pr diff*` allowlist, so link mode could
#     still fetch. Defeated by shell redirection: `gh pr view N > victim` matches
#     the allowed prefix and overwrote the file despite edit+write deny. Prefix
#     matching cannot make a shell command read-only.
#  3. Global deny without repeating it on the agent actually selected. OpenCode
#     applies agent-scoped permissions AFTER the global ones, so
#     `agent.<name>.permission.bash: allow` in a user's config reinstated shell —
#     verified, `id` ran again.
#  4. Denying tools by NAME. Anything not named stays allowed by default, so custom
#     tools and MCP servers remained reachable from prompt-injected PR text.
#  5. Running elsewhere but still reading project config. An `mcp` server declared
#     in the reviewed repo's opencode.json is LAUNCHED at startup, before any
#     permission applies — verified: a planted entry ran its command with
#     '"*": "deny"' and --pure both in force. Hence OPENCODE_DISABLE_PROJECT_CONFIG.
#
# "share": "disabled" is not incidental. With a user config set to `"share":"auto"`
# — OpenCode's own docs warn about it for proprietary code — the session, including
# the attached diff, is published to a public link. For a private PR that is silent
# exfiltration triggered by someone else's setting, so the policy pins it off.
#
# KNOWN, ACCEPTED RESIDUAL: this is not OpenCode's final config layer — managed
# (organization) config merges after it and could re-allow bash. Deliberately not
# defended against, because it is not reachable by the threat this exists for. The
# attacker is whoever authored the branch under review; managed config lives in
# /etc/opencode or /Library/Application Support/opencode, root-owned and not
# writable by a pull request. A permissive org-wide policy is an administrator's
# deliberate machine-wide choice, not something a diff can reach. OPENCODE_PERMISSION
# (a real OpenCode env var — it is present in the 1.18.3 binary) is not a fix
# either: it applies later still, but sets only the TOP-LEVEL permission block, so
# an agent-scoped allow still wins — verified, bash ran.
OPENCODE_RO_CONFIG='{"share":"disabled","permission":{"*":"deny","read":"allow","grep":"allow","glob":"allow","list":"allow"},"agent":{"pr-review-relay-ro":{"mode":"primary","description":"read-only cross-review agent","permission":{"*":"deny","read":"allow","grep":"allow","glob":"allow","list":"allow"}}}}'

# --- The invocation ----------------------------------------------------------
# opencode_review <attach_dir> <diff> <context_block> <subject> <errfile> <timeout>
#
# <subject> identifies what is under review in one line, e.g.
#   "PR #6 in owner/repo (https://...)"  or  "local branch 'x', diffed against 'main'"
# <context_block> is the caller's optional --context-file preamble, or "".
#
# The prompt is built HERE rather than taken from the caller. The callers' own
# prompts tell reviewers the change is on stdin, appended below, or fetchable with
# `gh`, and that they may read the repo — none of which is true for this reviewer.
# Appending a correction produced a prompt that stated both things and relied on
# the model preferring the later one. Composing an accurate prompt instead removes
# the contradiction rather than papering over it.
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
# relay_assert_tmpdir_outside_repo <dir>
#
# mktemp honours TMPDIR, so a TMPDIR inside the checkout puts the attachment dir —
# and therefore opencode's working directory — back inside the repository under
# review. read/grep/glob stay allowed, so that hands a prompt-injected diff the
# rest of the tree. Fail closed rather than quietly losing the isolation.
relay_assert_tmpdir_outside_repo() {
  # NB this compares against the worktree we are RUNNING IN, which the relay
  # requires to be the repo under review (`--pr N` resolves that repo's PR). Run it
  # from somewhere else with an explicit --pr and the comparison is against the
  # wrong repo — the README's "run it from inside the repo" is load-bearing here.
  local _root _dir
  _root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$_root" ] || return 0
  _root="$(cd "$_root" 2>/dev/null && pwd -P)" || return 0
  _dir="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  case "$_dir" in
    "$_root"/*|"$_root")
      echo "✖ the attachment dir '$_dir' is inside the repository being reviewed." >&2
      echo "  TMPDIR points into the checkout, so the reviewer would run there. Set TMPDIR" >&2
      echo "  to a path outside the repository." >&2
      exit 2;;
  esac
}

opencode_review() {
  local attach_dir="$1" diff="$2" context_block="$3" subject="$4" errf="$5" agent_timeout="$6"
  local diff_file oc_prompt
  local -a model=()
  [ -n "${PR_RELAY_OPENCODE_MODEL:-}" ] && model=(-m "$PR_RELAY_OPENCODE_MODEL")

  # UNIQUE per invocation. A fixed name races: both callers dedupe their reviewer
  # lists now, but that is one guard away from two of these running concurrently
  # under --parallel, and then one would truncate and rewrite the file while the
  # other's agent is still reading it — a silently incomplete review, which is worse than
  # a failed one because it still looks like a verdict. mktemp inside the
  # already-private attach dir keeps the EXIT-trap cleanup working unchanged.
  diff_file="$(mktemp "$attach_dir/oc-diff.XXXXXX")" || return 1
  # A failed or short write (full disk, I/O error) would hand the agent a truncated
  # diff; it would still produce a confident-looking review of half a change, and
  # the relay would count that as a clean reviewer. Fail instead.
  printf '%s' "$diff" > "$diff_file" || { echo "cannot write the diff attachment" >&2; return 1; }

  oc_prompt="$(printf '%sYou are reviewing %s.\n\nThe complete diff is ATTACHED to this message as a file. That attachment, plus any\ncontext given above, is everything you have: there is no shell and no checkout, so\ncommands will be refused, nothing is on stdin, and nothing is appended below.\n\nLook for correctness bugs, security issues, broken edge cases, and clear design or\nmaintainability problems. Be concise. Group findings by severity: Blocker /\nShould-fix / Nit. If it looks good, say so in one line.' "$context_block" "$subject")"

  (
    cd "$attach_dir" 2>/dev/null || { echo "cannot enter the attachment dir $attach_dir" >&2; exit 1; }
    OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_CONFIG_CONTENT="$OPENCODE_RO_CONFIG" \
    timeout "$agent_timeout" "$OPENCODE_BIN" --pure run \
      -f "$diff_file" --agent pr-review-relay-ro ${model[@]+"${model[@]}"} -- "$oc_prompt" 2>"$errf" )
}

# --- Reviewer selection ------------------------------------------------------
# Callers must resolve the binary ONLY when this reviewer is actually wanted:
# opencode_resolve_bin exits 2 on an unusable override, and an optional reviewer
# must not break a run that didn't ask for it. Kept here, with everything else
# OpenCode-specific, so the two callers cannot drift on it either.
#
# Reads $REVIEWERS and $AUTHOR from the caller.
# Trim surrounding whitespace only. Stripping ALL spaces would turn "open code"
# into "opencode" and silently select a reviewer nobody named — and if the two
# call sites disagree about this, a name can skip binary resolution here and then
# still be dispatched as opencode later.
relay_trim() { local _s="$1"; _s="${_s#"${_s%%[![:space:]]*}"}"; printf '%s' "${_s%"${_s##*[![:space:]]}"}"; }

opencode_is_selected() {
  local _r; local -a _list=()
  IFS=',' read -ra _list <<< "$REVIEWERS"
  # ${arr[@]+"${arr[@]}"} looks unquoted but is not: the outer +-form only guards
  # against an empty array under `set -u` (Bash 3.2 errors on "${arr[@]}" when the
  # array is empty), while the inner quotes preserve elements verbatim. Verified
  # with a value containing spaces — it stays one item. Do not "simplify" this to
  # "${_list[@]}": that reintroduces the unbound-variable abort on an empty list.
  for _r in ${_list[@]+"${_list[@]}"}; do
    _r="$(relay_trim "$_r")"
    [ "$_r" = opencode ] && [ "$_r" != "$AUTHOR" ] && return 0
  done
  return 1
}
