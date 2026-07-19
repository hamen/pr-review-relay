#!/usr/bin/env bash
# Fail-closed verdict tests for pr-review-relay.
#
# Stubs `gh` and the agent CLIs on PATH, runs the relay against a fake PR, and
# asserts the exit code for each scenario:
#   0  every reviewer ran and posted
#   3  a reviewer failed / no reviewers ran / HEAD moved (SHA drift)
#   4  review-round cap reached
#
# No network, no real agents. Run: bash test/test-fail-closed.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RELAY="$HERE/../pr-review-relay"
WORK="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "no temp dir" >&2; exit 1; }
BIN="$WORK/bin"; mkdir -p "$BIN"
trap 'rm -rf "$WORK"' EXIT

# --- stub: gh ----------------------------------------------------------------
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    if printf '%s\n' "$@" | grep -q headRefOid; then
      c=$(cat "$GH_SHA_COUNTER" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$GH_SHA_COUNTER"
      # Simulate a failed SHA read (empty output) at start (call 1) or end (call 2).
      case "${GH_SHA_FAIL:-}" in
        start) [ "$c" -le 1 ] && exit 0 ;;
        end)   [ "$c" -ge 2 ] && exit 0 ;;
        both)  exit 0 ;;
      esac
      if [ -n "${GH_SHA_DRIFT:-}" ]; then
        [ "$c" -le 1 ] && echo "aaaaaaa1111111111111111111111111111111111" || echo "bbbbbbb2222222222222222222222222222222222"
      else
        echo "aaaaaaa1111111111111111111111111111111111"
      fi
    elif printf '%s\n' "$@" | grep -q url; then echo "http://example.test/pr/1"
    elif printf '%s\n' "$@" | grep -q number; then echo 1
    fi ;;
  "repo view") echo "owner/repo" ;;
  "pr diff")   echo "diff --git a/x b/x"; echo "+change" ;;
  "pr comment") [ -n "${GH_POST_FAIL:-}" ] && exit 1; exit 0 ;;
  *) echo "" ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# --- stub: agents (claude / codex / cursor-agent / agy / opencode) -----------
make_agent() {
  cat > "$BIN/$1" <<AG
#!/usr/bin/env bash
self="\$(basename "\$0")"
case "\$self" in cursor-agent) key=cursor;; agy) key=antigravity;; *) key="\$self";; esac
case ",\${SLEEP_KEYS:-}," in *",\$key,"*) sleep 5;; esac        # outlast a short timeout → rc 124
case ",\${FAIL_EMPTY:-}," in *",\$key,"*) exit 0;; esac      # empty output, rc 0 → "no review"
case ",\${WS_ONLY:-}," in *",\$key,"*) printf '\t\n  \n';  exit 0;; esac  # whitespace-only "review"
case ",\${FAIL_RC:-}," in *",\$key,"*) echo "partial"; exit 1;; esac  # output but rc!=0
echo "LGTM from \$key."
exit 0
AG
  chmod +x "$BIN/$1"
}
for a in claude codex cursor-agent agy opencode; do make_agent "$a"; done

# --- test harness ------------------------------------------------------------
PASS=0; FAIL=0
run() { # run <expected_exit> <desc> -- <extra env assignments...>
  local expect="$1" desc="$2"; shift 2
  rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"
  rm -f "$WORK/sha_counter"
  env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" "$@" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --parallel >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$expect" ]; then echo "  ok   [$rc] $desc"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc, want $expect] $desc"; FAIL=$((FAIL+1)); fi
}

echo "pr-review-relay fail-closed tests:"
run 0 "both reviewers post → clean pass"
run 3 "one reviewer returns empty → not clean"          FAIL_EMPTY=codex
run 3 "one reviewer exits non-zero (truncated) → not clean" FAIL_RC=codex
run 3 "SHA drift during round → stale, fail"            GH_SHA_DRIFT=1
run 3 "SHA unreadable at start → cannot prove stability" GH_SHA_FAIL=start
run 3 "SHA unreadable at end → cannot prove stability"   GH_SHA_FAIL=end
run 3 "comment posting fails → not clean"               GH_POST_FAIL=1
run 3 "whitespace-only review → not a valid review"     WS_ONLY=codex
run 3 "reviewer times out → not clean"                  SLEEP_KEYS=codex PR_RELAY_AGENT_TIMEOUT=1

# bespoke runs: <expected> <desc> -- <args...>  (custom --reviewers / --dry-run)
runx() {
  local expect="$1" desc="$2"; shift 2
  rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
  env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$expect" ]; then echo "  ok   [$rc] $desc"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc, want $expect] $desc"; FAIL=$((FAIL+1)); fi
}

runx 3 "explicitly requested unknown reviewer → fail"   --reviewers claude,bogus --parallel
runx 3 "malicious reviewer name is contained, still fails" --reviewers 'claude,../../PWNED' --parallel
runx 0 "duplicate reviewer is deduped → clean pass"     --reviewers claude,claude --parallel
runx 0 "dry-run + valid explicit config → clean preflight" --reviewers claude,codex --dry-run
runx 3 "dry-run + invalid explicit config → fail preflight" --reviewers claude,bogus --dry-run

# author-only reviewer list → nobody runs → exit 3 (real run and dry-run)
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --author claude --reviewers claude --parallel >/dev/null 2>&1
rc=$?; if [ "$rc" = 3 ]; then echo "  ok   [3] author-only list → no reviewers ran"; PASS=$((PASS+1)); else echo "  FAIL [got $rc, want 3] author-only"; FAIL=$((FAIL+1)); fi
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --author claude --reviewers claude --dry-run >/dev/null 2>&1
rc=$?; if [ "$rc" = 3 ]; then echo "  ok   [3] dry-run + zero runnable reviewers → fail"; PASS=$((PASS+1)); else echo "  FAIL [got $rc, want 3] dry-run zero runnable"; FAIL=$((FAIL+1)); fi
# the traversal attempt must NOT create a file outside the temp status dir
if [ -e "$WORK/PWNED" ] || [ -e "$HOME/PWNED" ] || [ -e ./PWNED ]; then
  echo "  FAIL path traversal escaped STATUS_DIR"; FAIL=$((FAIL+1))
else
  echo "  ok   [-] traversal contained (no stray PWNED file)"; PASS=$((PASS+1))
fi

runx 0 "sequential run (no --parallel) → clean pass"    --reviewers claude,codex

# default set with only a subset of CLIs installed → skip the missing ones, exit 0.
# PATH excludes the real agent dir; BIN2 has gh+claude+codex (+node for the wrapper).
BIN2="$WORK/bin2"; mkdir -p "$BIN2"
for t in gh claude codex; do ln -sf "$BIN/$t" "$BIN2/$t"; done
ln -sf "$(command -v node)" "$BIN2/node" 2>/dev/null
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --parallel >/dev/null 2>&1
rc=$?; if [ "$rc" = 0 ]; then echo "  ok   [0] default set, subset installed → skip missing, pass"; PASS=$((PASS+1)); else echo "  FAIL [got $rc, want 0] default subset"; FAIL=$((FAIL+1)); fi

# wrap helper: a review that merely MENTIONS <details> must still be wrapped with our summary.
printf '## Heading\nThis review discusses a <details> element in the code.\n' > "$WORK/rev.md"
wout=$(node "$HERE/../wrap-collapsed-pr-comment.mjs" --summary "MARK-42" --footer "<sub>f</sub>" --file "$WORK/rev.md")
if printf '%s' "$wout" | grep -q "<summary>MARK-42</summary>"; then echo "  ok   [-] wrap keeps summary when body mentions <details>"; PASS=$((PASS+1)); else echo "  FAIL wrap dropped summary"; FAIL=$((FAIL+1)); fi

# invalid --max-rounds is a usage error (must not silently bypass the cap)
runx 2 "invalid --max-rounds → usage error"             --reviewers claude,codex --max-rounds nope

# a preflight-only failure (--reviewers bogus) must NOT consume a cap round
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers bogus --parallel >/dev/null 2>&1
if [ ! -f "$WORK/cache/pr-review-relay/owner_repo#1.round" ]; then echo "  ok   [-] preflight-only failure does not burn a round"; PASS=$((PASS+1)); else echo "  FAIL bogus consumed a round"; FAIL=$((FAIL+1)); fi

# contrast: a round that actually dispatched reviewers but failed DOES consume a slot
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" FAIL_EMPTY=codex \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --parallel >/dev/null 2>&1
rf="$WORK/cache/pr-review-relay/owner_repo#1.round"
if [ -f "$rf" ] && [ "$(cat "$rf")" = 1 ]; then echo "  ok   [-] failed round (reviewers ran) consumes a slot"; PASS=$((PASS+1)); else echo "  FAIL failed round did not consume a slot"; FAIL=$((FAIL+1)); fi

# wrapper (node) failure → reviewer recorded as failed → exit 3 (not posted as ok)
BIN4="$WORK/bin4"; mkdir -p "$BIN4"
for t in gh claude codex; do ln -sf "$BIN/$t" "$BIN4/$t"; done
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN4/node"; chmod +x "$BIN4/node"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN4:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --parallel >/dev/null 2>&1
rc=$?; if [ "$rc" = 3 ]; then echo "  ok   [3] comment wrapper failure → not clean"; PASS=$((PASS+1)); else echo "  FAIL [got $rc, want 3] wrapper failure"; FAIL=$((FAIL+1)); fi

# cap: pre-seed the round file at the cap, then a normal run must exit 4
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache/pr-review-relay"
printf '3' > "$WORK/cache/pr-review-relay/owner_repo#1.round"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --parallel >/dev/null 2>&1
rc=$?
if [ "$rc" = 4 ]; then echo "  ok   [4] round cap reached → exit 4"; PASS=$((PASS+1)); else echo "  FAIL [got $rc, want 4] round cap"; FAIL=$((FAIL+1)); fi

# --- opencode invocation contract --------------------------------------------
# These assert the ARGV the relay builds, not just that a review was posted — the
# generic stub above accepts anything, so it would pass against a broken flag too.
# Each of these fails against the pre-fix script (which sent
# --dangerously-skip-permissions — an undocumented alias for --auto, i.e. approve
# everything — and hardcoded the bare `opencode` name).
OC_ARGV="$WORK/oc_argv"
make_strict_opencode() { # $1 = dir to install the stub into
  mkdir -p "$1"
  cat > "$1/opencode" <<'OC'
#!/usr/bin/env bash
# Record argv so the test can assert on it, then enforce the contract.
printf '%s\n' "$*" > "${OC_ARGV_FILE:?}"
# Read-only is enforced by the inline permission config, not by --agent alone:
# a built-in agent can be redirected by user config, so the relay defines its own.
printf '%s\n' "${OPENCODE_CONFIG_CONTENT:-}" > "${OC_ARGV_FILE}.cfg"
# Record the working directory: opencode must NOT be launched inside the repo, or
# it reads the project opencode.json and starts any `mcp` server declared there
# before permissions apply — arbitrary command execution from the reviewed branch.
pwd > "${OC_ARGV_FILE}.cwd"
printf '%s\n' "${OPENCODE_DISABLE_PROJECT_CONFIG:-}" > "${OC_ARGV_FILE}.projcfg"
case "${OPENCODE_CONFIG_CONTENT:-}" in
  *'"*":"deny"'*) ;;
  *) echo "OPENCODE_CONFIG_CONTENT missing the default-deny baseline" >&2; exit 64;;
esac
# Global flags (e.g. --pure) may precede the subcommand, so scan rather than
# assuming argv[1] is it.
case " $* " in *" run "*) ;; *) echo "no 'run' subcommand in argv: $*" >&2; exit 64;; esac
case " $* " in
  *" --dangerously-skip-permissions "*)
    echo "rejected: --dangerously-skip-permissions is an undocumented alias for --auto" >&2; exit 64;;
  *" --auto "*)
    echo "rejected: --auto grants write+shell to a reviewer that reads untrusted PRs" >&2; exit 64;;
esac
# Must select the relay's OWN agent, not a built-in: a built-in's mode is
# user-configurable, and redirecting `plan` to a subagent makes OpenCode fall back
# to `build` with that agent's permissions — verified, shell came back.
case " $* " in *" --agent pr-review-relay-ro "*) ;; *) echo "not using the relay's own agent" >&2; exit 64;; esac
# the prompt must actually reach the agent as the last argument
case "${!#}" in "") echo "empty prompt" >&2; exit 64;; esac
echo "LGTM from opencode."
exit 0
OC
  chmod +x "$1/opencode"
}
make_strict_opencode "$BIN"

oc_run() { # oc_run <expected_exit> <desc> [VAR=val ...] [-- <relay args...>]
  local expect="$1" desc="$2"; shift 2
  local -a envs=() relay_args=()
  while [ $# -gt 0 ]; do
    case "$1" in --) shift; relay_args=("$@"); break;; *) envs+=("$1"); shift;; esac
  done
  rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$OC_ARGV"
  env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
    OC_ARGV_FILE="$OC_ARGV" ${envs[@]+"${envs[@]}"} \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode \
      ${relay_args[@]+"${relay_args[@]}"} >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$expect" ]; then echo "  ok   [$rc] $desc"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc, want $expect] $desc"; FAIL=$((FAIL+1)); fi
}
oc_assert() { # oc_assert <desc> <grep-mode: has|hasnt> <pattern>
  local desc="$1" mode="$2" pat="$3"
  local got; got="$(cat "$OC_ARGV" 2>/dev/null || true)"
  case "$mode" in
    has)   if printf '%s' "$got" | grep -q -- "$pat"; then echo "  ok   [-] $desc"; PASS=$((PASS+1));
           else echo "  FAIL $desc (argv: $got)"; FAIL=$((FAIL+1)); fi;;
    hasnt) if printf '%s' "$got" | grep -q -- "$pat"; then echo "  FAIL $desc (argv: $got)"; FAIL=$((FAIL+1));
           else echo "  ok   [-] $desc"; PASS=$((PASS+1)); fi;;
  esac
}

oc_run 0 "opencode runs read-only under its own agent, link mode"
oc_assert "link mode selects the relay agent" has "--agent pr-review-relay-ro"
oc_assert "no --dangerously-skip-permissions in argv" hasnt "--dangerously-skip-permissions"
oc_assert "no --auto in argv" hasnt "--auto"
oc_assert "PR_RELAY_OPENCODE_MODEL unset → no -m" hasnt " -m "
# the permission config is what actually enforces read-only (see the stub's check)
oc_cfg() { # oc_cfg <desc> <has|hasnt> <pattern>
  local desc="$1" mode="$2" pat="$3" got
  got="$(cat "$OC_ARGV.cfg" 2>/dev/null || true)"
  case "$mode" in
    has)   if printf '%s' "$got" | grep -q -- "$pat"; then echo "  ok   [-] $desc"; PASS=$((PASS+1));
           else echo "  FAIL $desc (cfg: $got)"; FAIL=$((FAIL+1)); fi;;
    hasnt) if printf '%s' "$got" | grep -q -- "$pat"; then echo "  FAIL $desc (cfg: $got)"; FAIL=$((FAIL+1));
           else echo "  ok   [-] $desc"; PASS=$((PASS+1)); fi;;
  esac
}
# NOTE ON WHAT THESE CAN AND CANNOT PROVE: they assert the policy the relay SENDS,
# not the policy OpenCode ENFORCES — a hermetic test cannot run the real agent. Both
# holes fixed here were found by review and confirmed by hand against a live
# opencode, not by this file. Treat these as regression guards on the config string.
# Default-deny: naming tools to deny leaves anything unnamed (custom tools, MCP
# servers) allowed, so the policy must start from "*": "deny".
oc_cfg "default-deny baseline" has '"\*":"deny"'
# A user config of "share":"auto" would publish the session — including the attached
# diff — to a public link. Pinned off so someone else's setting cannot leak a
# private PR.
oc_cfg "session sharing pinned off" has '"share":"disabled"'
oc_cfg "allows read"  has '"read":"allow"'
oc_cfg "allows grep"  has '"grep":"allow"'
# Shell must never be allowed. An allowlist was tried and defeated by redirection
# (`gh pr view N > file` matches the allowed prefix and writes).
oc_cfg "never allows bash" hasnt '"bash":"allow"'
oc_cfg "no bash prefix allowlist" hasnt 'gh pr'
# OpenCode applies agent-specific permissions AFTER global ones, so a user's
# permissions on the SELECTED agent would reinstate shell unless it carries the
# policy too — which is why the relay defines its own rather than using a built-in.
oc_cfg "defines its own primary agent" has '"pr-review-relay-ro":{"mode":"primary"'
oc_cfg "that agent is default-deny too" has '"pr-review-relay-ro".*"\*":"deny"'
# External plugins load and can execute code at startup regardless of permissions.
oc_assert "skips external plugins with --pure" has "--pure"
# The diff is attached, so the inline link-mode fallback must NOT also be in the
# prompt — same content twice, pointing the model at two different places.
oc_assert "no duplicate inline diff fallback" hasnt "Fallback: the PR diff"
# The single most severe hole found in review: a project opencode.json in the
# reviewed repo can declare an `mcp` server that runs at startup, before any
# permission applies. The only defence is not being in that directory.
if [ -s "$OC_ARGV.cwd" ] && [ "$(cat "$OC_ARGV.cwd")" != "$PWD" ]; then
  echo "  ok   [-] opencode is not launched inside the repo (no project config read)"; PASS=$((PASS+1))
else
  echo "  FAIL opencode ran in the repo cwd — project opencode.json/mcp would be honoured"; FAIL=$((FAIL+1))
fi

# Shell is denied, so the reviewer can never fetch the PR: the diff must be ATTACHED
# in both modes. `-f` takes an array, so `--` must precede the prompt or the prompt
# is swallowed as another filename (opencode then dies with "File not found").
oc_assert "attaches the diff with -f" has " -f "
# Unique per invocation, not a fixed name: review-local does not dedupe its
# reviewer list, so two concurrent opencode runs would otherwise truncate and
# rewrite the same file while the other agent is reading it.
oc_assert "attachment path is unique per invocation" has "oc-diff\."
oc_assert "separates the prompt with --" has " -- "
oc_assert "tells the agent it has no shell" has "there is no shell and no checkout"
# The prompt is BUILT for this reviewer rather than corrected afterwards, so it
# must not contain the other reviewers' claims at all.
oc_assert "never claims the diff is on stdin" hasnt "provided on stdin"
oc_assert "never tells it to run gh" hasnt "gh pr view"

oc_run 0 "opencode runs read-only, diff mode" -- --diff
oc_assert "diff-mode argv still read-only" has "--agent pr-review-relay-ro"
oc_assert "diff mode also attaches the diff" has " -f "
# Prove we are actually in diff mode. Checking for the diff body would NOT prove it:
# link mode inlines the same diff as a fallback under LINK_DIFF_FALLBACK_MAX_BYTES.
# The prompt preamble is the real discriminator between the two modes.
# Mode no longer changes this reviewer's prompt: it always gets the attachment
# and an accurate description, so both modes must look the same here.
oc_assert "diff mode uses the same composed prompt" has "ATTACHED to this message"

oc_run 0 "PR_RELAY_OPENCODE_MODEL set → model pinned" PR_RELAY_OPENCODE_MODEL=opencode/some-model
oc_assert "sets exactly -m <value>" has "-m opencode/some-model"

# PATH miss + stock install at \$HOME/.opencode/bin → reviewer must still RUN,
# not be skipped by the `command -v` check that precedes dispatch.
FAKEHOME="$WORK/fakehome"; make_strict_opencode "$FAKEHOME/.opencode/bin"
BIN5="$WORK/bin5"; mkdir -p "$BIN5"
for t in gh claude; do ln -sf "$BIN/$t" "$BIN5/$t"; done
ln -sf "$(command -v node)" "$BIN5/node" 2>/dev/null
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$OC_ARGV"
env PATH="$BIN5:/usr/bin:/bin" HOME="$FAKEHOME" XDG_CACHE_HOME="$WORK/cache" \
  GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_ARGV" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1
rc=$?
if [ "$rc" = 0 ] && [ -s "$OC_ARGV" ]; then
  echo "  ok   [0] opencode off PATH but at \$HOME/.opencode/bin → resolved and run"; PASS=$((PASS+1))
else
  echo "  FAIL [got $rc] off-PATH stock install was skipped (argv file empty=$([ -s "$OC_ARGV" ] || echo yes))"; FAIL=$((FAIL+1))
fi

# HOME unset (cron / systemd / minimal containers) must NOT abort the relay. Under
# `set -u` a bare $HOME in the startup resolution kills every reviewer, not just
# opencode, because it runs before any dispatch.
# Setting XDG_CACHE_HOME here would MASK the bug: ROUND_DIR falls back to $HOME/.cache
# only when XDG_CACHE_HOME is absent, so both must be unset to exercise the real
# minimal environment. (An earlier version of this test set XDG_CACHE_HOME and passed
# while a second bare $HOME was still live.)
# node must be reachable from the restricted PATH or the comment wrapper fails and
# the relay returns 3 — which passes locally (node in /usr/bin) but is red on CI,
# where setup-node installs outside /usr/bin and /bin. Symlink it in, as BIN5 does.
ln -sf "$(command -v node)" "$BIN/node" 2>/dev/null
rm -f "$WORK/sha_counter" "$OC_ARGV"
# TMPDIR under $WORK so the run's round state (which falls back to
# $TMPDIR/pr-review-relay-$(id -u) when HOME and XDG_CACHE_HOME are both unset)
# stays inside the test sandbox. Without this the suite writes to the real
# /tmp/pr-review-relay-$UID and repeated runs eventually hit the round cap.
# It must EXIST: mktemp -d honours TMPDIR and fails if it is missing.
mkdir -p "$WORK/tmphome"
env -u HOME -u XDG_CACHE_HOME PATH="$BIN:/usr/bin:/bin" TMPDIR="$WORK/tmphome" \
  GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_ARGV" PR_RELAY_MAX_ROUNDS=99 \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1
rc=$?
if [ "$rc" = 0 ]; then echo "  ok   [0] HOME + XDG_CACHE_HOME both unset → relay still runs"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 0] minimal env aborted the relay"; FAIL=$((FAIL+1)); fi

# A RELATIVE PR_RELAY_OPENCODE_BIN must still work: the reviewer is launched after
# a `cd "$ATTACH_DIR"`, so it has to be resolved to an absolute path up front or it
# executes from the wrong directory.
BIN7="$WORK/bin7"; make_strict_opencode "$BIN7"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$OC_ARGV"
( cd "$WORK" && env PATH="$BIN5:/usr/bin:/bin" HOME="$FAKEHOME" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_ARGV" PR_RELAY_OPENCODE_BIN="./bin7/opencode" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 0 ] && [ -s "$OC_ARGV" ]; then echo "  ok   [0] relative PR_RELAY_OPENCODE_BIN resolved to absolute"; PASS=$((PASS+1))
else echo "  FAIL [got $rc] relative PR_RELAY_OPENCODE_BIN broke after cd"; FAIL=$((FAIL+1)); fi

# A broken PR_RELAY_OPENCODE_BIN must fail fast when opencode IS selected...
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  PR_RELAY_OPENCODE_BIN=/nonexistent/opencode \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] unusable PR_RELAY_OPENCODE_BIN fails fast when selected"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] bad override did not fail fast"; FAIL=$((FAIL+1)); fi

# ...and must NOT affect a run that never asked for that reviewer.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  PR_RELAY_OPENCODE_BIN=/nonexistent/opencode \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex >/dev/null 2>&1
rc=$?
if [ "$rc" = 0 ]; then echo "  ok   [0] bad override is irrelevant when opencode is not a reviewer"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 0] optional reviewer broke an unrelated run"; FAIL=$((FAIL+1)); fi

# A DIRECTORY passes a bare `[ -x ]`, so it must be rejected explicitly rather
# than passing validation and failing confusingly at launch.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  PR_RELAY_OPENCODE_BIN="$WORK" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] a directory override is rejected, not treated as executable"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] directory override passed validation"; FAIL=$((FAIL+1)); fi

# A BARE override that is not on PATH must fail, NOT silently resolve to
# ./opencode in the working directory — which can be a repo whose PR added a file
# by that name.
mkdir -p "$WORK/bare"; printf '#!/usr/bin/env bash\necho PWNED\n' > "$WORK/bare/opencode"; chmod +x "$WORK/bare/opencode"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/bare" && env PATH="$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" PR_RELAY_OPENCODE_BIN=opencode \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] bare override not on PATH is rejected, not read from cwd"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] bare override fell back to ./opencode"; FAIL=$((FAIL+1)); fi

# A PATH containing "." makes `command -v opencode` resolve a file from the repo
# being reviewed. Executing it precedes every OpenCode-level defence, so implicit
# resolution must refuse it.
# A REAL git worktree: the guard only applies inside one, so a bare directory
# would no longer exercise the threat it exists for.
mkdir -p "$WORK/dotpath"
( cd "$WORK/dotpath" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho PWNED\n' > "$WORK/dotpath/opencode"; chmod +x "$WORK/dotpath/opencode"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env PATH=".:$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] a repo-local opencode on PATH is refused"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] ran an opencode from the reviewed checkout"; FAIL=$((FAIL+1)); fi

# Same threat, reached through a SYMLINK to the worktree: git reports a physical
# toplevel while $PWD stays logical, so a prefix comparison of the two misses.
ln -sfn "$WORK/dotpath" "$WORK/dotlink"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotlink" && env PATH=".:$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] repo-local opencode refused through a symlinked worktree"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] symlinked worktree bypassed the containment guard"; FAIL=$((FAIL+1)); fi

# A BARE override is a PATH lookup, not a trusted path, so it must get the same
# containment check — otherwise setting PR_RELAY_OPENCODE_BIN=opencode with "." on
# PATH walks straight past the guard.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env PATH=".:$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" PR_RELAY_OPENCODE_BIN=opencode \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] bare override is PATH-resolved and still contained"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] bare override bypassed the containment guard"; FAIL=$((FAIL+1)); fi

# ...while an explicit PATH-ful override outside the repo remains usable.
BINOUT="$WORK/binout"; make_strict_opencode "$BINOUT"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$OC_ARGV"
( cd "$WORK/dotpath" && env PATH="$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_ARGV" PR_RELAY_OPENCODE_BIN="$BINOUT/opencode" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 0 ] && [ -s "$OC_ARGV" ]; then echo "  ok   [0] explicit path override outside the repo still runs"; PASS=$((PASS+1))
else echo "  FAIL [got $rc] explicit path override was wrongly refused"; FAIL=$((FAIL+1)); fi

# A PATH entry in a TRUSTED directory that symlinks INTO the checkout: the name
# looks safe, the target is not. Containment must follow the chain.
mkdir -p "$WORK/trustedbin"
printf '#!/usr/bin/env bash\necho PWNED\n' > "$WORK/dotpath/malicious"; chmod +x "$WORK/dotpath/malicious"
ln -sf "$WORK/dotpath/malicious" "$WORK/trustedbin/opencode"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env PATH="$WORK/trustedbin:$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] a symlink into the repo is followed and refused"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] symlink chain bypassed containment"; FAIL=$((FAIL+1)); fi

# ...and a legitimate symlinked install outside the repo is NOT refused.
mkdir -p "$WORK/legit/real" "$WORK/legit/bin"
make_strict_opencode "$WORK/legit/real"
ln -sf "$WORK/legit/real/opencode" "$WORK/legit/bin/opencode"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$OC_ARGV"
( cd "$WORK/dotpath" && env PATH="$WORK/legit/bin:$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_ARGV" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 0 ] && [ -s "$OC_ARGV" ]; then echo "  ok   [0] a symlinked install outside the repo still runs"; PASS=$((PASS+1))
else echo "  FAIL [got $rc] legitimate symlinked install was refused"; FAIL=$((FAIL+1)); fi

# TMPDIR inside the checkout would put the attachment dir — and so opencode's
# working directory — back inside the repository, losing the isolation silently.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
mkdir -p "$WORK/dotpath/intmp"
( cd "$WORK/dotpath" && env PATH="$BIN:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    TMPDIR="$WORK/dotpath/intmp" GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_ARGV" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] TMPDIR inside the repo is refused"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] reviewer would have run inside the repository"; FAIL=$((FAIL+1)); fi

# PATH containing a directory inside the checkout compromises EVERY command the
# relay runs — gh first of all — so it refuses to start rather than hardening one
# command at a time.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env PATH="$WORK/dotpath:$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] a PATH entry inside the repo refuses the whole run"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] ran with a repo-controlled PATH"; FAIL=$((FAIL+1)); fi

# ...even when the repo also ships a hostile `git`, which is the bootstrap problem:
# the guard cannot use a PATH-resolved command to decide whether PATH is safe.
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/dotpath/git"; chmod +x "$WORK/dotpath/git"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env PATH="$WORK/dotpath:$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] refused even with a repo-controlled 'git' on PATH"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] a hostile git disabled the PATH guard"; FAIL=$((FAIL+1)); fi
rm -f "$WORK/dotpath/git"

# ...and a "." entry, which is the same thing spelled differently.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env PATH=".:$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] a '.' PATH entry inside the repo is refused too"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] '.' on PATH slipped through"; FAIL=$((FAIL+1)); fi

# PR_RELAY_OPENCODE_BIN wins over both PATH and the stock location.
BIN6="$WORK/bin6"; make_strict_opencode "$BIN6"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$OC_ARGV"
env PATH="$BIN5:/usr/bin:/bin" HOME="$FAKEHOME" XDG_CACHE_HOME="$WORK/cache" \
  GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_ARGV" PR_RELAY_OPENCODE_BIN="$BIN6/opencode" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1
rc=$?
if [ "$rc" = 0 ] && [ -s "$OC_ARGV" ]; then echo "  ok   [0] PR_RELAY_OPENCODE_BIN override honoured"; PASS=$((PASS+1))
else echo "  FAIL [got $rc] PR_RELAY_OPENCODE_BIN override ignored"; FAIL=$((FAIL+1)); fi

# --- review-local: same opencode contract ------------------------------------
# review-local is a separate script that duplicates the opencode invocation, so it
# can drift from pr-review-relay. It was changed in the same PR with no coverage,
# which is exactly how the two fall out of sync.
RL="$HERE/../review-local"
if [ -f "$RL" ]; then
  RLREPO="$WORK/rlrepo"; mkdir -p "$RLREPO"
  (
    cd "$RLREPO" || exit 1
    git init -q . 2>/dev/null
    git config user.email t@t; git config user.name t
    echo base > f.txt; git add f.txt; git commit -qm base
    git branch -M mainline
    git checkout -qb feature
    echo changed > f.txt; git add f.txt; git commit -qm change
  ) >/dev/null 2>&1
  rm -f "$OC_ARGV" "$OC_ARGV.cfg"
  ( cd "$RLREPO" && env PATH="$BIN:$PATH" OC_ARGV_FILE="$OC_ARGV" \
      bash "$RL" --base mainline --reviewers opencode >/dev/null 2>&1 )
  rc=$?
  if [ "$rc" = 0 ] && [ -s "$OC_ARGV" ]; then
    echo "  ok   [0] review-local dispatches opencode"; PASS=$((PASS+1))
  else
    echo "  FAIL [got $rc] review-local did not dispatch opencode"; FAIL=$((FAIL+1))
  fi
  rl_assert() { # rl_assert <desc> <has|hasnt> <pattern> <file>
    local desc="$1" mode="$2" pat="$3" file="$4" got
    got="$(cat "$file" 2>/dev/null || true)"
    case "$mode" in
      has)   if printf '%s' "$got" | grep -q -- "$pat"; then echo "  ok   [-] $desc"; PASS=$((PASS+1));
             else echo "  FAIL $desc"; FAIL=$((FAIL+1)); fi;;
      hasnt) if printf '%s' "$got" | grep -q -- "$pat"; then echo "  FAIL $desc"; FAIL=$((FAIL+1));
             else echo "  ok   [-] $desc"; PASS=$((PASS+1)); fi;;
    esac
  }
  rl_assert "review-local: relay's own agent"   has   "--agent pr-review-relay-ro" "$OC_ARGV"
  rl_assert "review-local: --pure"              has   "--pure"           "$OC_ARGV"
  rl_assert "review-local: attaches the diff"   has   " -f "             "$OC_ARGV"
  rl_assert "review-local: no legacy flag"      hasnt "--dangerously-skip-permissions" "$OC_ARGV"
  rl_assert "review-local: overrides the stdin wording" has "ATTACHED" "$OC_ARGV"
  rl_assert "review-local: default-deny policy" has   '"\*":"deny"'     "$OC_ARGV.cfg"
  rl_assert "review-local: never allows bash"   hasnt '"bash":"allow"'  "$OC_ARGV.cfg"
  rl_assert "review-local: defines its own agent" has '"pr-review-relay-ro"' "$OC_ARGV.cfg"
  # From here on the runs must NOT dispatch opencode, so clear the recorded files:
  # asserting on them afterwards would be reading the successful run above.
  rm -f "$OC_ARGV" "$OC_ARGV.cfg" "$OC_ARGV.cwd" "$OC_ARGV.projcfg"
  # An explicitly requested but missing reviewer must FAIL, matching the relay —
  # otherwise `review-local --reviewers opencode` on a machine without it prints a
  # skip and exits 0, which reads as "reviewed".
  # HOME must be the fake one: on a machine that really has ~/.opencode/bin/opencode
  # the stock-path branch would resolve it and this test would run the real agent.
  ( cd "$RLREPO" && env -u PR_RELAY_OPENCODE_BIN HOME="$WORK/nohome" PATH="$BIN5:/usr/bin:/bin" \
      bash "$RL" --base mainline --reviewers opencode >/dev/null 2>&1 )
  rc=$?
  if [ "$rc" = 3 ]; then echo "  ok   [3] review-local fails on an explicitly requested missing reviewer"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc, want 3] review-local silently skipped a missing reviewer"; FAIL=$((FAIL+1)); fi
  # The missing-reviewer run must not have invoked anything at all.
  if [ ! -s "$OC_ARGV" ]; then echo "  ok   [-] review-local: nothing dispatched when the CLI is absent"; PASS=$((PASS+1))
  else echo "  FAIL review-local dispatched a reviewer it reported as missing"; FAIL=$((FAIL+1)); fi
  # Zero dispatched reviewers must not read as a clean review.
  ( cd "$RLREPO" && env HOME="$WORK/nohome" PATH="/usr/bin:/bin" bash "$RL" --base mainline >/dev/null 2>&1 )
  rc=$?
  if [ "$rc" = 3 ]; then echo "  ok   [3] review-local fails when no reviewer ran"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc, want 3] review-local reported success with zero reviewers"; FAIL=$((FAIL+1)); fi
  # Duplicates are deduped, and empty items tolerated, like the relay.
  rm -f "$OC_ARGV"
  ( cd "$RLREPO" && env PATH="$BIN:$PATH" OC_ARGV_FILE="$OC_ARGV" \
      bash "$RL" --base mainline --reviewers 'opencode,,opencode' >/dev/null 2>&1 )
  rc=$?
  if [ "$rc" = 0 ]; then echo "  ok   [0] review-local dedupes and tolerates empty items"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc, want 0] duplicate/empty reviewer list mishandled"; FAIL=$((FAIL+1)); fi
  # The same isolation the relay is asserted on: project config off, and launched
  # outside the repo. Checking only one call site is how the two drift.
  rl_assert "review-local: disables project config" has "1" "$OC_ARGV.projcfg"
  if [ -s "$OC_ARGV.cwd" ] && [ "$(cat "$OC_ARGV.cwd")" != "$RLREPO" ]; then
    echo "  ok   [-] review-local: opencode is not launched inside the repo"; PASS=$((PASS+1))
  else
    echo "  FAIL review-local: opencode ran in the repo cwd"; FAIL=$((FAIL+1))
  fi
else
  echo "  ok   [-] review-local not present (skip)"; PASS=$((PASS+1))
fi

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
