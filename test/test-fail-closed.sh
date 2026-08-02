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
#
set -uo pipefail

# HERMETICITY. This suite builds throwaway git repos under $WORK and must operate on THOSE and
# nothing else. Two separate ways it used to escape, both of which corrupted the repository the
# suite was launched from:
#
# 1. INHERITED GIT ENVIRONMENT. git exports GIT_DIR (and friends) to its hooks, and those variables
#    outrank the working directory: with GIT_DIR set, `cd "$RLREPO" && git init && git commit`
#    commits to the HOST repo and the fixture repo stays empty. Run from a pre-push hook this suite
#    therefore wrote junk commits (base/change/i/c) and stray files onto the branch being pushed,
#    and then failed ~16 assertions because the fixture repos had no content — which reads
#    convincingly as a defect in the code under test. Reproduce the old behaviour with
#    `GIT_DIR=$(git rev-parse --absolute-git-dir) bash test/test-fail-closed.sh`.
#    Consequence worth stating: while this was broken, the pre-push gate could never pass, so it
#    was gating nothing.
#
# 2. INHERITED GIT CONFIG. The fixtures inherit ~/.gitconfig, and on a machine with
#    `commit.gpgsign = true` plus an agent-backed signer (e.g. 1Password's op-ssh-sign) every
#    fixture `git commit` either blocks on a signing prompt that never comes — the suite hangs
#    forever, no output, on a fixture that has nothing to do with signing — or fails outright.
#
# Both are fixed with PROCESS-SCOPED settings that write nothing to disk. In particular the config
# is imposed with GIT_CONFIG_*, never with `git config`: a `git config` line inside a fixture whose
# `git init` failed quietly writes into the host repo's config instead (it set user.name=t and
# turned commit signing off in this very repository while that version was being tried).
# The same reasoning applies to any fixture added later, which is why this is set once, here.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=tag.gpgsign    GIT_CONFIG_VALUE_1=false

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
      # Local-context tests pin the PR head to the test repo's real HEAD so the
      # LOCAL_CONTEXT gate (HEAD == PR head, clean tree) passes.
      if [ -n "${GH_LOCAL_HEAD:-}" ]; then echo "$GH_LOCAL_HEAD"; exit 0; fi
      c=$(cat "$GH_SHA_COUNTER" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$GH_SHA_COUNTER"
      # Simulate a failed SHA read (empty output) at start (call 1) or end (call 2).
      case "${GH_SHA_FAIL:-}" in
        start) [ "$c" -le 1 ] && exit 0 ;;
        end)   [ "$c" -ge 2 ] && exit 0 ;;
        both)  exit 0 ;;
      esac
      # A per-RUN pin. GH_SHA_DRIFT changes the SHA *within* one round (to test staleness); the
      # per-SHA round counter needs the opposite — a SHA that is stable inside a run but differs
      # BETWEEN runs. Without this knob those tests would silently all use the same SHA and assert
      # nothing.
      if [ -n "${GH_FIXED_SHA:-}" ]; then echo "$GH_FIXED_SHA"; exit 0; fi
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

# --- stub: agents (claude / codex / cursor-agent / agy / opencode / qwen / grok) ----
make_agent() {
  cat > "$BIN/$1" <<AG
#!/usr/bin/env bash
self="\$(basename "\$0")"
case "\$self" in cursor-agent) key=cursor;; agy) key=antigravity;; *) key="\$self";; esac
case ",\${SLEEP_KEYS:-}," in *",\$key,"*) sleep 5;; esac        # outlast a short timeout → rc 124
case ",\${FAIL_EMPTY:-}," in *",\$key,"*) exit 0;; esac      # empty output, rc 0 → "no review"
case ",\${WS_ONLY:-}," in *",\$key,"*) printf '\t\n  \n';  exit 0;; esac  # whitespace-only "review"
case ",\${FAIL_RC:-}," in *",\$key,"*) echo "partial"; exit 1;; esac  # output but rc!=0
# Record our argv when asked, so a test can assert the command line the relay builds.
# The bug this guards against is a flag silently going missing or being renamed, which
# no output-shape assertion would ever notice.
[ -n "\${ARGV_LOG:-}" ] && printf '%s %s\n' "\$self" "\$*" >> "\$ARGV_LOG"
# Grok receives the plan/diff only via --prompt-file (stdin is ignored). When asked,
# dump the prompt-file contents so tests can assert the full diff reached the agent.
if [ -n "\${PROMPT_FILE_LOG:-}" ]; then
  _args=("\$@")
  for ((_i=0; _i<\${#_args[@]}; _i++)); do
    if [ "\${_args[\$_i]}" = "--prompt-file" ]; then
      _pf="\${_args[\$((_i+1))]}"
      if [ -n "\$_pf" ] && [ -f "\$_pf" ]; then
        { printf 'PROMPT_FILE path=%s\n' "\$_pf"; cat -- "\$_pf"; } >> "\$PROMPT_FILE_LOG"
      fi
      break
    fi
  done
  printf '\nCWD=%s\n' "\$PWD" >> "\$PROMPT_FILE_LOG"
fi
echo "LGTM from \$key."
exit 0
AG
  chmod +x "$BIN/$1"
}
for a in claude codex cursor-agent agy opencode qwen grok; do make_agent "$a"; done

# --- test harness ------------------------------------------------------------
PASS=0; FAIL=0
# Assertions use `grep -q ... <<< "$var"`, never `printf ... | grep -q`. Under
# `set -o pipefail`, grep -q exits as soon as it matches, printf takes SIGPIPE, and
# the pipeline reports 141 — so a SUCCESSFUL match reads as a failed assertion. It
# passes locally whenever the payload fits the pipe buffer before grep leaves,
# which is why this only ever went red on CI.
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
# --- agy gets our timeout budget, not its own 5-minute default ---------------
# agy enforces --print-timeout (default 5m) on top of ours: left unset it wins whenever
# PR_RELAY_AGENT_TIMEOUT is raised above 300, which is how three of four antigravity rounds
# died on 2026-07-27 with "timeout waiting for response" despite a 900s budget. The failure
# mode is a missing flag, which no output assertion would catch — so assert the argv.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$WORK/argv.log"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  ARGV_LOG="$WORK/argv.log" PR_RELAY_AGENT_TIMEOUT=900 \
  bash "$RELAY" --pr 1 --author claude --reviewers antigravity --parallel >/dev/null 2>&1
agy_argv="$(grep '^agy ' "$WORK/argv.log" 2>/dev/null || true)"
if grep -q -- '--print-timeout 900s' <<< "$agy_argv"; then
  echo "  ok   [-] agy is given the relay's timeout as --print-timeout"; PASS=$((PASS+1))
else
  echo "  FAIL agy argv lacks '--print-timeout 900s': ${agy_argv:-<no agy invocation recorded>}"; FAIL=$((FAIL+1))
fi

# the traversal attempt must NOT create a file outside the temp status dir
if [ -e "$WORK/PWNED" ] || [ -e "$HOME/PWNED" ] || [ -e ./PWNED ]; then
  echo "  FAIL path traversal escaped STATUS_DIR"; FAIL=$((FAIL+1))
else
  echo "  ok   [-] traversal contained (no stray PWNED file)"; PASS=$((PASS+1))
fi

runx 0 "sequential run (no --parallel) → clean pass"    --reviewers claude,codex

# --- qwen: opt-in reviewer dispatch (generic stub) ---------------------------
# qwen is opt-in like opencode: absent from the default set, dispatched only when
# named. These exercise the new dispatch path through the generic stub; the exact
# argv (incl. the security-relevant --safe-mode) is asserted separately below.
runx 0 "qwen named explicitly → runs and passes"        --reviewers claude,qwen --parallel
runx 0 "qwen deduped like any reviewer → clean pass"    --reviewers qwen,qwen --parallel
# qwen empty / non-zero exit must fail the round, same as the built-in reviewers.
qwen_env_run() { # <expected> <desc> <VAR=val>
  local expect="$1" desc="$2" envassign="$3"
  rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
  env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" "$envassign" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,qwen --parallel >/dev/null 2>&1
  local rc=$?
  if [ "$rc" = "$expect" ]; then echo "  ok   [$rc] $desc"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc, want $expect] $desc"; FAIL=$((FAIL+1)); fi
}
qwen_env_run 3 "qwen returns empty → not clean"         FAIL_EMPTY=qwen
qwen_env_run 3 "qwen exits non-zero (truncated) → not clean" FAIL_RC=qwen
qwen_env_run 3 "qwen whitespace-only review → not valid"     WS_ONLY=qwen

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
if grep -q "<summary>MARK-42</summary>" <<< "$wout"; then echo "  ok   [-] wrap keeps summary when body mentions <details>"; PASS=$((PASS+1)); else echo "  FAIL wrap dropped summary"; FAIL=$((FAIL+1)); fi

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
# State is "<sha> <rounds> <same-sha-invocations>" (it used to be a bare integer). The INTENT of
# this assertion is unchanged: a round that actually dispatched reviewers records itself even when
# the round then fails, so a persistently flaky reviewer still marches toward the cap.
read -r _sha _rounds _same _junk < "$rf" 2>/dev/null || true
if [ -f "$rf" ] && [ -n "${_sha:-}" ] && [ "${_rounds:-}" = 1 ] && [ "${_same:-}" = 1 ] && [ -z "${_junk:-}" ]; then
  echo "  ok   [-] failed round (reviewers ran) consumes a slot"; PASS=$((PASS+1))
else echo "  FAIL failed round did not consume a slot (state: $(cat "$rf" 2>/dev/null || echo '<missing>'))"; FAIL=$((FAIL+1)); fi
unset _sha _rounds _same _junk

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
  # Clear PR_RELAY_OPENCODE_MODEL first: the "unset → no -m" assertion below tests the
  # DEFAULT, so a developer who exports the variable in their own shell (a normal thing to
  # do — it is a documented knob) would otherwise fail the suite on an unmodified checkout.
  # It stays overridable: `env X= X=val` applies left to right, so an explicit value in
  # "${envs[@]}" still wins.
  env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
    PR_RELAY_OPENCODE_MODEL= \
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
    has)   if grep -q -- "$pat" <<< "$got"; then echo "  ok   [-] $desc"; PASS=$((PASS+1));
           else echo "  FAIL $desc (argv: $got)"; FAIL=$((FAIL+1)); fi;;
    hasnt) if grep -q -- "$pat" <<< "$got"; then echo "  FAIL $desc (argv: $got)"; FAIL=$((FAIL+1));
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
    has)   if grep -q -- "$pat" <<< "$got"; then echo "  ok   [-] $desc"; PASS=$((PASS+1));
           else echo "  FAIL $desc (cfg: $got)"; FAIL=$((FAIL+1)); fi;;
    hasnt) if grep -q -- "$pat" <<< "$got"; then echo "  FAIL $desc (cfg: $got)"; FAIL=$((FAIL+1));
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
# Nothing is allowed — not even reads. The diff arrives as prompt content, so the
# reviewer needs no filesystem at all, and allowing reads was the last route by
# which a prompt-injected diff could quote a secret into a posted PR comment.
oc_cfg "allows nothing at all" hasnt '"allow"'
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
# Unique per invocation, not a fixed name: both callers dedupe their
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

# An EMPTY PATH field means the current directory, and word splitting silently
# drops a trailing one — so "PATH=/usr/bin:" looked clean while the shell resolved
# commands from the checkout. Leading and doubled colons are the same field.
for _p in "$BIN2:/usr/bin:/bin:" ":$BIN2:/usr/bin:/bin" "$BIN2::/usr/bin:/bin"; do
  rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
  ( cd "$WORK/dotpath" && env PATH="$_p" XDG_CACHE_HOME="$WORK/cache" \
      GH_SHA_COUNTER="$WORK/sha_counter" \
      bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1 )
  rc=$?
  if [ "$rc" = 2 ]; then echo "  ok   [2] empty PATH field refused ($_p)"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc, want 2] empty PATH field slipped through ($_p)"; FAIL=$((FAIL+1)); fi
done
unset _p

# A PATH entry that does not exist YET must still be judged: the unsandboxed
# reviewers can create it mid-round, after which commands resolve from the repo.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env PATH="$WORK/dotpath/not/created/yet:$BIN2:/usr/bin:/bin" \
    XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] a not-yet-existing PATH entry in the repo is refused"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] unresolved repo-local PATH entry was skipped"; FAIL=$((FAIL+1)); fi

# ...while a nonexistent entry OUTSIDE the repo must not block anything.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env PATH="/opt/definitely/not/here:$BIN2:/usr/bin:/bin" \
    XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 0 ]; then echo "  ok   [0] a nonexistent PATH entry outside the repo is fine"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 0] harmless missing PATH entry was rejected"; FAIL=$((FAIL+1)); fi

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

# A RELATIVE TMPDIR makes mktemp return relative paths, which then resolve against
# the attachment dir once opencode_review cds into it.
mkdir -p "$WORK/reltmp"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$OC_ARGV"
( cd "$WORK" && env PATH="$BIN:$PATH" TMPDIR="reltmp" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_ARGV" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 0 ] && [ -s "$OC_ARGV" ]; then echo "  ok   [0] a relative TMPDIR still produces a usable review"; PASS=$((PASS+1))
else echo "  FAIL [got $rc] relative TMPDIR broke the attachment paths"; FAIL=$((FAIL+1)); fi
oc_assert "attachment path is absolute" has " -f /"

# CDPATH can steer `cd`, so a relative PATH entry could be canonicalized to a
# CDPATH match outside the repo while the shell still resolves commands from the
# repo-local one. The guard must not be foolable that way.
mkdir -p "$WORK/decoy/bin" "$WORK/dotpath/bin"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env CDPATH="$WORK/decoy" PATH="bin:$BIN2:/usr/bin:/bin" \
    XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] CDPATH cannot steer the PATH containment check"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] CDPATH redirected the guard away from the repo"; FAIL=$((FAIL+1)); fi

# An EXPLICIT override inside the repo is refused, not just warned about...
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
cp "$BIN/opencode" "$WORK/dotpath/oc-inrepo"; chmod +x "$WORK/dotpath/oc-inrepo"
( cd "$WORK/dotpath" && env PATH="$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" PR_RELAY_OPENCODE_BIN="$WORK/dotpath/oc-inrepo" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] an explicit in-repo override is refused"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] explicit in-repo override only warned"; FAIL=$((FAIL+1)); fi

# ...unless the user deliberately opts in.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$OC_ARGV"
( cd "$WORK/dotpath" && env PATH="$BIN2:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" \
    GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_ARGV" \
    PR_RELAY_OPENCODE_ALLOW_IN_REPO=1 PR_RELAY_OPENCODE_BIN="$WORK/dotpath/oc-inrepo" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,opencode >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 0 ] && [ -s "$OC_ARGV" ]; then echo "  ok   [0] PR_RELAY_OPENCODE_ALLOW_IN_REPO=1 opts back in"; PASS=$((PASS+1))
else echo "  FAIL [got $rc] the documented opt-in did not work"; FAIL=$((FAIL+1)); fi

# TMPDIR inside the checkout must be refused for EVERY run, not only ones that
# select opencode: errf, the comment body and the reviewer output all use it, so a
# crash would leave PR data sitting in the repository.
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
mkdir -p "$WORK/dotpath/intmp2"
( cd "$WORK/dotpath" && env PATH="$BIN2:/usr/bin:/bin" TMPDIR="$WORK/dotpath/intmp2" \
    XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] TMPDIR in the repo is refused even without opencode"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] temp files would have landed in the repository"; FAIL=$((FAIL+1)); fi

# ".." through a SYMLINK: plain `cd` resolves it logically, so "link/../x" looks
# like it lives beside the link when physically it lives inside the repo.
mkdir -p "$WORK/dotpath/sub"; ln -sfn "$WORK/dotpath/sub" "$WORK/symlnk"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$WORK/dotpath" && env PATH="$WORK/symlnk/../future-bin:$BIN2:/usr/bin:/bin" \
    XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1 )
rc=$?
if [ "$rc" = 2 ]; then echo "  ok   [2] '..' through a symlink is resolved physically"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 2] logical '..' let a repo-local PATH entry through"; FAIL=$((FAIL+1)); fi

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
      has)   if grep -q -- "$pat" <<< "$got"; then echo "  ok   [-] $desc"; PASS=$((PASS+1));
             else echo "  FAIL $desc"; FAIL=$((FAIL+1)); fi;;
      hasnt) if grep -q -- "$pat" <<< "$got"; then echo "  FAIL $desc"; FAIL=$((FAIL+1));
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

# --- qwen invocation contract ------------------------------------------------
# Assert the ARGV the relay builds for qwen, not just that a review was posted —
# the generic stub accepts anything, so it would pass against a dropped flag too.
# The security-relevant part is --safe-mode: without it, a reviewed PR's
# .qwen/settings.json / QWEN.md / hooks / extensions / MCP load from the checkout
# and execute before the review runs. --approval-mode yolo (not plan) is what lets
# the reviewer still run `gh` in link mode. This guards both against regression.
QW_ARGV="$WORK/qw_argv"
make_strict_qwen() { # $1 = dir to install the stub into
  mkdir -p "$1"
  cat > "$1/qwen" <<'QW'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${QW_ARGV_FILE:?}"
case " $* " in *" --safe-mode "*) ;; *) echo "missing --safe-mode: $*" >&2; exit 64;; esac
case " $* " in *" --approval-mode yolo "*) ;; *) echo "missing --approval-mode yolo: $*" >&2; exit 64;; esac
case " $* " in *" -p "*) ;; *) echo "missing -p prompt flag: $*" >&2; exit 64;; esac
echo "LGTM from qwen."
exit 0
QW
  chmod +x "$1/qwen"
}
# A dedicated PATH with a strict qwen plus the helpers the relay needs (gh, node,
# and claude as the co-reviewer). node must be reachable or the comment wrapper
# fails and the relay returns 3 — green locally, red on CI (setup-node installs
# outside /usr/bin). Symlink it in, as the opencode off-PATH test does.
BINQW="$WORK/binqw"; mkdir -p "$BINQW"
for t in gh claude; do ln -sf "$BIN/$t" "$BINQW/$t"; done
ln -sf "$(command -v node)" "$BINQW/node" 2>/dev/null
make_strict_qwen "$BINQW"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$QW_ARGV"
env PATH="$BINQW:/usr/bin:/bin" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  QW_ARGV_FILE="$QW_ARGV" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,qwen >/dev/null 2>&1
rc=$?
if [ "$rc" = 0 ] && [ -s "$QW_ARGV" ]; then echo "  ok   [0] qwen dispatched with the enforced flags"; PASS=$((PASS+1))
else echo "  FAIL [got $rc] qwen argv contract not met (argv empty=$([ -s "$QW_ARGV" ] || echo yes))"; FAIL=$((FAIL+1)); fi
qw_assert() { # <desc> <has|hasnt> <pattern>
  local desc="$1" mode="$2" pat="$3" got; got="$(cat "$QW_ARGV" 2>/dev/null || true)"
  case "$mode" in
    has)   if grep -q -- "$pat" <<< "$got"; then echo "  ok   [-] $desc"; PASS=$((PASS+1)); else echo "  FAIL $desc (argv: $got)"; FAIL=$((FAIL+1)); fi;;
    hasnt) if grep -q -- "$pat" <<< "$got"; then echo "  FAIL $desc (argv: $got)"; FAIL=$((FAIL+1)); else echo "  ok   [-] $desc"; PASS=$((PASS+1)); fi;;
  esac
}
qw_assert "disables checkout customizations with --safe-mode" has "--safe-mode"
qw_assert "keeps gh via --approval-mode yolo (not plan)"      has "--approval-mode yolo"
qw_assert "never runs in the unconfined default approval mode" hasnt "--approval-mode default"

# The same qwen contract for review-local: the two scripts drift exactly when a
# security-relevant flag is asserted on only one of them. Without this, dropping
# --safe-mode in review-local would leave every test green.
if [ -f "$RL" ]; then
  # Reuse the RLREPO git fixture built in the review-local block above; rebuild it
  # if that block was skipped (review-local absent → we wouldn't be here anyway).
  if [ ! -d "${RLREPO:-}/.git" ]; then
    RLREPO="$WORK/rlrepo"; mkdir -p "$RLREPO"
    ( cd "$RLREPO" && git init -q . && git config user.email t@t && git config user.name t \
        && echo base > f.txt && git add f.txt && git commit -qm base && git branch -M mainline \
        && git checkout -qb feature && echo changed > f.txt && git add f.txt && git commit -qm change ) >/dev/null 2>&1
  fi
  rm -f "$QW_ARGV"
  ( cd "$RLREPO" && env PATH="$BINQW:/usr/bin:/bin" QW_ARGV_FILE="$QW_ARGV" \
      bash "$RL" --base mainline --reviewers qwen >/dev/null 2>&1 )
  rc=$?
  if [ "$rc" = 0 ] && [ -s "$QW_ARGV" ]; then echo "  ok   [0] review-local dispatches qwen with the enforced flags"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc] review-local qwen argv contract not met (argv empty=$([ -s "$QW_ARGV" ] || echo yes))"; FAIL=$((FAIL+1)); fi
  qw_assert "review-local: qwen keeps --safe-mode"          has "--safe-mode"
  qw_assert "review-local: qwen keeps --approval-mode yolo" has "--approval-mode yolo"

  # review-local duplicates the antigravity invocation in its own review_with, so it needs its
  # own argv assertion: without one the two call sites drift silently, which is exactly how
  # review-local kept the defective command line while pr-review-relay was being fixed.
  rm -f "$WORK/argv.log"
  ( cd "$RLREPO" && env PATH="$BIN:/usr/bin:/bin" ARGV_LOG="$WORK/argv.log" \
      PR_RELAY_AGENT_TIMEOUT=900 bash "$RL" --base mainline --reviewers antigravity >/dev/null 2>&1 )
  rl_agy_argv="$(grep '^agy ' "$WORK/argv.log" 2>/dev/null || true)"
  if grep -q -- '--print-timeout 900s' <<< "$rl_agy_argv"; then
    echo "  ok   [-] review-local gives agy the same --print-timeout"; PASS=$((PASS+1))
  else
    echo "  FAIL review-local agy argv lacks '--print-timeout 900s': ${rl_agy_argv:-<no agy invocation recorded>}"; FAIL=$((FAIL+1))
  fi
fi

# --- LOCAL context: reviewers read files off disk, not via gh -----------------------
# The diff always comes from `gh pr diff` (authoritative). The speed win is that when the
# checkout provably IS the PR head AND is clean, reviewers are told to read the changed
# files locally instead of running `gh` — every `gh` an agentic reviewer runs is an LLM
# round-trip. Build a repo whose HEAD the stubbed gh reports as the PR head and assert the
# reviewer's prompt tells it to read locally; a dirty or non-matching tree must fall back.
# grep uses `<<<` not `printf | grep -q`: under pipefail a matched grep -q makes printf take
# SIGPIPE and the pipeline reports 141, which reads as a failed assertion (see file header).
LREPO="$WORK/localrepo"; git init -q -b main "$LREPO"
( cd "$LREPO" && git config user.email t@t && git config user.name t \
    && echo base > file.txt && git add file.txt && git commit -qm base \
    && git checkout -qb feature && echo change >> file.txt && git add file.txt && git commit -qm feat )
LHEAD=$(git -C "$LREPO" rev-parse HEAD)
ln -sf "$(command -v node)" "$BIN/node" 2>/dev/null
# reviewer stub that echoes the prompt it received, so we can see what it was told to do
printf '#!/usr/bin/env bash\nprintf "%%s" "$*"\n' > "$BIN/claude"; chmod +x "$BIN/claude"
lc_run() { # sets $out/$rc; args: extra env assignments for the relay
  rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
  out=$( cd "$LREPO" && env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
      "$@" bash "$RELAY" --pr 1 --author codex --reviewers claude 2>&1 ); rc=$?
}
# clean checkout whose HEAD == the PR head → local-context reading, exit 0
lc_run GH_LOCAL_HEAD="$LHEAD"
if [ "$rc" = 0 ] && grep -q 'reviewers read files locally' <<< "$out"; then
  echo "  ok   [0] clean checkout at the PR head → reviewers read files locally"; PASS=$((PASS+1))
else echo "  FAIL [got $rc] local-context not engaged ($(grep -o 'reviewers [a-z ]*' <<< "$out" | head -1))"; FAIL=$((FAIL+1)); fi
# the reviewer's prompt must tell it the code is checked out here (and NOT to run gh itself)
if grep -q 'CHECKED OUT in the current directory' <<< "$out"; then
  echo "  ok   [-] the reviewer is told to read the local checkout"; PASS=$((PASS+1))
else echo "  FAIL reviewer prompt did not point at the local checkout"; FAIL=$((FAIL+1)); fi
# a DIRTY worktree (matches HEAD but has uncommitted changes) must NOT go local — reviewers
# would otherwise read files that aren't in the PR
echo dirty >> "$LREPO/file.txt"
lc_run GH_LOCAL_HEAD="$LHEAD"
if grep -q 'reviewers fetch via gh' <<< "$out"; then
  echo "  ok   [-] a dirty worktree falls back to gh (no local read)"; PASS=$((PASS+1))
else echo "  FAIL dirty worktree still read locally"; FAIL=$((FAIL+1)); fi
( cd "$LREPO" && git checkout -q -- file.txt )   # clean it back up
# a checkout whose HEAD does NOT match the PR head must fall back to gh
lc_run GH_LOCAL_HEAD=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
if grep -q 'reviewers fetch via gh' <<< "$out"; then
  echo "  ok   [-] a non-matching checkout falls back to gh"; PASS=$((PASS+1))
else echo "  FAIL non-matching checkout did not fall back to gh"; FAIL=$((FAIL+1)); fi
# end-of-round re-check: if a reviewer dirties the working tree DURING the round (local
# context was enabled on a clean tree), the reviews are stale → exit 3.
printf '#!/usr/bin/env bash\necho scratch >> file.txt\necho "LGTM"\n' > "$BIN/claude"; chmod +x "$BIN/claude"
lc_run GH_LOCAL_HEAD="$LHEAD"
[ "$rc" = 3 ] && { echo "  ok   [3] a mid-round working-tree change fails the round (stale)"; PASS=$((PASS+1)); } \
             || { echo "  FAIL [got $rc, want 3] mid-round dirty tree not caught"; FAIL=$((FAIL+1)); }
( cd "$LREPO" && git checkout -q -- file.txt )   # clean up the scratch write
printf '#!/usr/bin/env bash\necho "LGTM"\n' > "$BIN/claude"; chmod +x "$BIN/claude"   # restore


# --- grok invocation contract ------------------------------------------------
# Grok is opt-in (like opencode/qwen). It ignores stdin; the full diff must land
# in --prompt-file. Runs from an isolated cwd under ATTACH_DIR with medium effort,
# permission-mode plan, and sandbox read-only.
mkdir -p "$WORK/home" "$WORK/xdg" "$WORK/tmp"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"
PROMPT_FILE_LOG="$WORK/grok-prompt.log"; : > "$PROMPT_FILE_LOG"
ARGV_LOG="$WORK/grok-argv.log"; : > "$ARGV_LOG"
rm -f "$WORK/sha_counter"
out=$( env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" \
  GROK_REVIEW_MODEL= GROK_REVIEW_EFFORT= \
  ARGV_LOG="$ARGV_LOG" PROMPT_FILE_LOG="$PROMPT_FILE_LOG" \
  bash "$RELAY" --pr 1 --author claude --reviewers grok 2>&1 )
rc=$?
if [ "$rc" = 0 ]; then echo "  ok   [0] grok reviewer runs and posts"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 0] grok reviewer: $out"; FAIL=$((FAIL+1)); fi
if grep -q -- '--prompt-file' "$ARGV_LOG" && grep -q -- '-m grok-4.5' "$ARGV_LOG" \
   && grep -q -- '--reasoning-effort medium' "$ARGV_LOG" \
   && grep -q -- '--permission-mode plan' "$ARGV_LOG" \
   && grep -q -- '--sandbox read-only' "$ARGV_LOG" \
   && grep -qF -- "--deny *" "$ARGV_LOG" \
   && grep -q -- '--verbatim' "$ARGV_LOG" \
   && grep -q -- '--cwd' "$ARGV_LOG"; then
  echo "  ok   [-] grok argv pins model/medium/plan/sandbox/deny/verbatim/cwd/prompt-file"; PASS=$((PASS+1))
else echo "  FAIL grok argv missing required flags: $(cat "$ARGV_LOG" 2>/dev/null)"; FAIL=$((FAIL+1)); fi
if grep -qF -- '+change' "$PROMPT_FILE_LOG" && grep -qF -- '--- DIFF ---' "$PROMPT_FILE_LOG"; then
  echo "  ok   [-] grok prompt-file contains the full PR diff"; PASS=$((PASS+1))
else echo "  FAIL grok prompt-file missing diff content (pl=$(wc -c < "$PROMPT_FILE_LOG" 2>/dev/null)B)"; FAIL=$((FAIL+1)); fi
# isolated cwd: process cds into iso-grok under TMPDIR/ATTACH
if grep -q '^CWD=' "$PROMPT_FILE_LOG"; then
  gcwd=$(sed -n 's/^CWD=//p' "$PROMPT_FILE_LOG" | tail -1)
  case "$gcwd" in
    *iso-grok*|"$WORK"/tmp/*) echo "  ok   [-] grok process cwd is the isolated temp dir"; PASS=$((PASS+1));;
    *) echo "  FAIL grok cwd not isolated ($gcwd)"; FAIL=$((FAIL+1));;
  esac
else echo "  FAIL grok CWD not recorded"; FAIL=$((FAIL+1)); fi
# large-diff path: still must embed the complete diff for grok (threshold does not strip it)
: > "$PROMPT_FILE_LOG"; : > "$ARGV_LOG"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
out=$( env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" LINK_DIFF_FALLBACK_MAX_BYTES=1 \
  ARGV_LOG="$ARGV_LOG" PROMPT_FILE_LOG="$PROMPT_FILE_LOG" \
  bash "$RELAY" --pr 1 --author claude --reviewers grok 2>&1 )
rc=$?
if [ "$rc" = 0 ] && grep -q -- '+change' "$PROMPT_FILE_LOG"; then
  echo "  ok   [0] grok still gets full diff when LINK_DIFF_FALLBACK_MAX_BYTES=1"; PASS=$((PASS+1))
else echo "  FAIL grok lost diff under small link threshold (rc=$rc)"; FAIL=$((FAIL+1)); fi
# author skip — reset round-cap cache so a prior failed round doesn't yield exit 4
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
out=$( env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --author grok --reviewers grok 2>&1 )
rc=$?
if [ "$rc" = 3 ]; then echo "  ok   [3] grok-as-author with only self → no reviewers"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 3] grok author self-exclusion out=$out"; FAIL=$((FAIL+1)); fi
# missing binary when explicit — pruned PATH so a real ~/.local/bin/grok cannot mask it
rm -f "$BIN/grok"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
BIN2="$WORK/bin2"; mkdir -p "$BIN2"
cp -a "$BIN/gh" "$BIN2/gh"
# coreutils the relay needs
for b in bash timeout gtimeout mktemp cat tr sed head tail wc rm mkdir chmod node; do
  src=$(command -v "$b" 2>/dev/null) || continue
  ln -sf "$src" "$BIN2/$b" 2>/dev/null || true
done
# wrap helper needs node + mjs next to relay - already via absolute RELAY path
out=$( env PATH="$BIN2:/usr/bin:/bin" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --author claude --reviewers grok 2>&1 )
rc=$?
if [ "$rc" = 3 ]; then echo "  ok   [3] explicit grok missing binary → fail"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 3] missing grok not fail-closed out=$out"; FAIL=$((FAIL+1)); fi
make_agent grok   # restore

# review-local also dispatches grok
: > "$PROMPT_FILE_LOG"; : > "$ARGV_LOG"
RLREPO="$WORK/rlrepo"; rm -rf "$RLREPO"; mkdir -p "$RLREPO" "$WORK/tmp"
( cd "$RLREPO" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > f && git add f && git commit -q -m i \
  && echo b >> f && git add f && git commit -q -m c )
out=$( cd "$RLREPO" && env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  ARGV_LOG="$ARGV_LOG" PROMPT_FILE_LOG="$PROMPT_FILE_LOG" \
  bash "$HERE/../review-local" --author claude --reviewers grok --base HEAD~1 2>&1 )
rc=$?
if [ "$rc" = 0 ] && grep -q -- '--reasoning-effort medium' "$ARGV_LOG" && grep -qF -- '--- DIFF ---' "$PROMPT_FILE_LOG"; then
  echo "  ok   [0] review-local dispatches grok with medium + full diff"; PASS=$((PASS+1))
else echo "  FAIL review-local grok (rc=$rc) argv=$(cat "$ARGV_LOG" 2>/dev/null) pl=$(head -5 "$PROMPT_FILE_LOG" 2>/dev/null) out=$out"; FAIL=$((FAIL+1)); fi

# --- cursor invocation contract ----------------------------------------------------
# cursor-agent's own default model is "Auto", which routes to the frontier models: it bills
# the small "Other Models" quota AND may pick a Claude model, so a Claude-authored PR gets
# reviewed by Claude in a Cursor badge and the panel is one model short of what it claims.
# The default must therefore be pinned on EVERY cursor call site. The default is asserted
# with CURSOR_REVIEW_MODEL cleared, so an exported override in a dev/CI env cannot make
# these pass by accident.
cur_model_assert() { # <label> <argv-file>
  if grep -q -- '--model composer-2.5' "$2" 2>/dev/null; then
    echo "  ok   [-] $1"; PASS=$((PASS+1))
  else
    echo "  FAIL $1 — argv: $(grep '^cursor-agent ' "$2" 2>/dev/null || echo '<no cursor-agent invocation recorded>')"; FAIL=$((FAIL+1))
  fi
}
CUR_ARGV="$WORK/cursor-argv.log"
# link mode (the default) and diff mode are separate branches of the case, so both need cover.
for cur_mode in link diff; do
  : > "$CUR_ARGV"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
  out=$( env PATH="$BIN:$PATH" HOME="$WORK/home" \
    XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
    GH_SHA_COUNTER="$WORK/sha_counter" CURSOR_REVIEW_MODEL= ARGV_LOG="$CUR_ARGV" \
    bash "$RELAY" --pr 1 --author claude --reviewers cursor "--$cur_mode" 2>&1 )
  rc=$?
  if [ "$rc" = 0 ]; then echo "  ok   [0] relay dispatches cursor in $cur_mode mode"; PASS=$((PASS+1))
  else echo "  FAIL [got $rc, want 0] relay cursor $cur_mode mode: $out"; FAIL=$((FAIL+1)); fi
  cur_model_assert "relay pins the cursor model in $cur_mode mode" "$CUR_ARGV"
done
# The override is the documented recovery path if Cursor ever retires the model id, so it is
# part of the contract, not a convenience.
: > "$CUR_ARGV"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
out=$( env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" CURSOR_REVIEW_MODEL=cursor-grok-4.5-high ARGV_LOG="$CUR_ARGV" \
  bash "$RELAY" --pr 1 --author claude --reviewers cursor 2>&1 )
if grep -q -- '--model cursor-grok-4.5-high' "$CUR_ARGV" 2>/dev/null; then
  echo "  ok   [-] CURSOR_REVIEW_MODEL overrides the pinned default"; PASS=$((PASS+1))
else echo "  FAIL CURSOR_REVIEW_MODEL ignored — argv: $(cat "$CUR_ARGV" 2>/dev/null)"; FAIL=$((FAIL+1)); fi
# --- codex / antigravity model overrides -------------------------------------
# Asserted at ALL THREE call sites (relay here, review-local below, distill in
# test-distill.sh): the overrides are duplicated across the three scripts, and this
# repo has already been bitten by one copy drifting from the others.
# Three reviewers flagged the same blocker on the first cut of this feature: on
# Bash 3.2 (what macOS ships) `"${arr[@]}"` on an EMPTY array aborts under
# `set -u`, and empty is the normal case here. Both the empty and the populated
# path are asserted, plus the argv contract for each call site.
CODEX_ARGV="$WORK/codex-argv.log"
AGY_ARGV="$WORK/agy-argv.log"

# The guard itself, run under a shell that emulates the 3.2 failure: `set -u`
# plus the bare expansion is exactly what used to abort.
if bash -c 'set -u; A=(); printf "%s" ${A[@]+"${A[@]}"}; exit 0' >/dev/null 2>&1; then
  echo "  ok   [-] empty override array expands safely under set -u"; PASS=$((PASS+1))
else
  echo "  FAIL empty override array aborts under set -u"; FAIL=$((FAIL+1))
fi

# Unset overrides must add NO argv at all — not an empty string argument.
: > "$CODEX_ARGV"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
out=$( env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" CODEX_REVIEW_MODEL= CODEX_REVIEW_EFFORT= ARGV_LOG="$CODEX_ARGV" \
  bash "$RELAY" --pr 1 --author claude --reviewers codex 2>&1 )
if grep -q -- '-m ' "$CODEX_ARGV" 2>/dev/null || grep -q -- 'model_reasoning_effort' "$CODEX_ARGV" 2>/dev/null; then
  echo "  FAIL unset codex overrides still added argv: $(cat "$CODEX_ARGV")"; FAIL=$((FAIL+1))
else
  echo "  ok   [-] unset codex overrides add no argv"; PASS=$((PASS+1))
fi

: > "$CODEX_ARGV"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
out=$( env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" CODEX_REVIEW_MODEL=gpt-5.6-sol CODEX_REVIEW_EFFORT=high ARGV_LOG="$CODEX_ARGV" \
  bash "$RELAY" --pr 1 --author claude --reviewers codex 2>&1 )
if grep -q -- '-m gpt-5.6-sol' "$CODEX_ARGV" 2>/dev/null && grep -q 'model_reasoning_effort' "$CODEX_ARGV" 2>/dev/null; then
  echo "  ok   [-] CODEX_REVIEW_MODEL/EFFORT reach codex argv"; PASS=$((PASS+1))
else
  echo "  FAIL codex overrides ignored — argv: $(cat "$CODEX_ARGV" 2>/dev/null)"; FAIL=$((FAIL+1))
fi

: > "$AGY_ARGV"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
out=$( env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" AGY_REVIEW_MODEL= ARGV_LOG="$AGY_ARGV" \
  bash "$RELAY" --pr 1 --author claude --reviewers antigravity 2>&1 )
if grep -q -- '--model' "$AGY_ARGV" 2>/dev/null; then
  echo "  FAIL unset AGY_REVIEW_MODEL still added --model: $(cat "$AGY_ARGV")"; FAIL=$((FAIL+1))
else
  echo "  ok   [-] unset AGY_REVIEW_MODEL adds no argv"; PASS=$((PASS+1))
fi

: > "$AGY_ARGV"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
out=$( env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" AGY_REVIEW_MODEL=gemini-3.1-pro-high ARGV_LOG="$AGY_ARGV" \
  bash "$RELAY" --pr 1 --author claude --reviewers antigravity 2>&1 )
if grep -q -- '--model gemini-3.1-pro-high' "$AGY_ARGV" 2>/dev/null; then
  echo "  ok   [-] AGY_REVIEW_MODEL reaches agy argv"; PASS=$((PASS+1))
else
  echo "  FAIL AGY_REVIEW_MODEL ignored — argv: $(cat "$AGY_ARGV" 2>/dev/null)"; FAIL=$((FAIL+1))
fi

# review-local carries its own copy of the codex/agy overrides too. Codex flagged that the
# first cut asserted only the relay while claiming every call site was covered — and this
# repo has been bitten by drift between these copies before.
CODEX_ARGV_RL="$WORK/codex-argv-rl.log"
AGY_ARGV_RL="$WORK/agy-argv-rl.log"
RLREPO2="$WORK/rlrepo2"; rm -rf "$RLREPO2"; mkdir -p "$RLREPO2" "$WORK/tmp"
( cd "$RLREPO2" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > f && git add f && git commit -q -m i \
  && echo b >> f && git add f && git commit -q -m c )

: > "$CODEX_ARGV_RL"
out=$( cd "$RLREPO2" && env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  CODEX_REVIEW_MODEL= CODEX_REVIEW_EFFORT= ARGV_LOG="$CODEX_ARGV_RL" \
  bash "$RL" --author claude --reviewers codex --base HEAD~1 2>&1 )
if grep -qE -- '(^| )-m ( |$)|model_reasoning_effort' "$CODEX_ARGV_RL" 2>/dev/null; then
  echo "  FAIL review-local added codex argv with overrides unset: $(cat "$CODEX_ARGV_RL")"; FAIL=$((FAIL+1))
else
  echo "  ok   [-] review-local adds no codex argv when unset"; PASS=$((PASS+1))
fi

: > "$CODEX_ARGV_RL"
out=$( cd "$RLREPO2" && env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  CODEX_REVIEW_MODEL=gpt-5.6-sol CODEX_REVIEW_EFFORT=high ARGV_LOG="$CODEX_ARGV_RL" \
  bash "$RL" --author claude --reviewers codex --base HEAD~1 2>&1 )
if grep -q -- '-m gpt-5.6-sol' "$CODEX_ARGV_RL" 2>/dev/null && grep -q 'model_reasoning_effort' "$CODEX_ARGV_RL" 2>/dev/null; then
  echo "  ok   [-] review-local honours the codex overrides"; PASS=$((PASS+1))
else
  echo "  FAIL review-local ignored the codex overrides — argv: $(cat "$CODEX_ARGV_RL" 2>/dev/null)"; FAIL=$((FAIL+1))
fi

: > "$AGY_ARGV_RL"
out=$( cd "$RLREPO2" && env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  AGY_REVIEW_MODEL= ARGV_LOG="$AGY_ARGV_RL" \
  bash "$RL" --author claude --reviewers antigravity --base HEAD~1 2>&1 )
if grep -q -- '--model' "$AGY_ARGV_RL" 2>/dev/null; then
  echo "  FAIL review-local added --model with AGY_REVIEW_MODEL unset: $(cat "$AGY_ARGV_RL")"; FAIL=$((FAIL+1))
else
  echo "  ok   [-] review-local adds no agy argv when unset"; PASS=$((PASS+1))
fi

: > "$AGY_ARGV_RL"
out=$( cd "$RLREPO2" && env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  AGY_REVIEW_MODEL=gemini-3.1-pro-high ARGV_LOG="$AGY_ARGV_RL" \
  bash "$RL" --author claude --reviewers antigravity --base HEAD~1 2>&1 )
if grep -q -- '--model gemini-3.1-pro-high' "$AGY_ARGV_RL" 2>/dev/null; then
  echo "  ok   [-] review-local honours AGY_REVIEW_MODEL"; PASS=$((PASS+1))
else
  echo "  FAIL review-local ignored AGY_REVIEW_MODEL — argv: $(cat "$AGY_ARGV_RL" 2>/dev/null)"; FAIL=$((FAIL+1))
fi

# review-local has its own copy of the cursor invocation. Without this assertion the two
# drift silently — the same failure mode the antigravity argv test above was written for.
: > "$CUR_ARGV"
RLREPO="$WORK/rlrepo"; rm -rf "$RLREPO"; mkdir -p "$RLREPO" "$WORK/tmp"
( cd "$RLREPO" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > f && git add f && git commit -q -m i \
  && echo b >> f && git add f && git commit -q -m c )
out=$( cd "$RLREPO" && env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  CURSOR_REVIEW_MODEL= ARGV_LOG="$CUR_ARGV" \
  bash "$RL" --author claude --reviewers cursor --base HEAD~1 2>&1 )
rc=$?
if [ "$rc" = 0 ]; then echo "  ok   [0] review-local dispatches cursor"; PASS=$((PASS+1))
else echo "  FAIL [got $rc, want 0] review-local cursor: $out"; FAIL=$((FAIL+1)); fi
cur_model_assert "review-local pins the cursor model too" "$CUR_ARGV"
# ...and honours the override, like the relay and distill paths. A call site that respects the
# default but ignores the escape hatch would leave the documented recovery path broken on one
# of the three scripts, which no default-only assertion would ever notice.
: > "$CUR_ARGV"
out=$( cd "$RLREPO" && env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  CURSOR_REVIEW_MODEL=cursor-grok-4.5-high ARGV_LOG="$CUR_ARGV" \
  bash "$RL" --author claude --reviewers cursor --base HEAD~1 2>&1 )
if grep -q -- '--model cursor-grok-4.5-high' "$CUR_ARGV" 2>/dev/null; then
  echo "  ok   [-] review-local honours CURSOR_REVIEW_MODEL"; PASS=$((PASS+1))
else echo "  FAIL review-local ignored CURSOR_REVIEW_MODEL — argv: $(cat "$CUR_ARGV" 2>/dev/null)"; FAIL=$((FAIL+1)); fi

# --- SCRIPT_DIR follows the script's own symlink to find the sibling lib ------------
# Regression: invoked through a symlink whose directory has NO lib-opencode.sh next to it
# (exactly how ~/.local/bin/pr-review-relay -> the repo checkout is installed), the relay
# must still locate the lib from the REAL script directory. `pwd -P` resolves a symlinked
# *directory* but not a symlinked *file*, so an earlier version aborted with
# "missing lib-opencode.sh" for every symlinked install — it broke the tool for anyone
# not running it from the repo. `--help` sources the lib (relay_print_header lives there)
# and exits 0 without touching gh, so it's a clean probe.
SLINK_BIN="$WORK/slinkbin"; mkdir -p "$SLINK_BIN"
ln -s "$RELAY" "$SLINK_BIN/pr-review-relay"
if out=$(bash "$SLINK_BIN/pr-review-relay" --help 2>&1) && ! printf '%s' "$out" | grep -qE 'missing.*lib-(opencode|grok)'; then
  echo "  ok   [-] absolute symlink invocation resolves the sibling lib"; PASS=$((PASS+1))
else
  echo "  FAIL absolute symlink invocation could not find lib-opencode.sh"; FAIL=$((FAIL+1))
fi
# A RELATIVE symlink target must resolve against the LINK's directory, not the cwd.
REALD="$WORK/real"; mkdir -p "$REALD"
cp "$RELAY" "$HERE/../lib-opencode.sh" "$HERE/../lib-grok.sh" "$HERE/../wrap-collapsed-pr-comment.mjs" "$REALD/" 2>/dev/null
LINKD="$WORK/linkbin"; mkdir -p "$LINKD"
( cd "$LINKD" && ln -s "../real/pr-review-relay" pr-review-relay )
if out=$( cd "$WORK" && bash "$LINKD/pr-review-relay" --help 2>&1) && ! printf '%s' "$out" | grep -qE 'missing.*lib-(opencode|grok)'; then
  echo "  ok   [-] relative symlink resolves against the link's own dir"; PASS=$((PASS+1))
else
  echo "  FAIL relative symlink did not resolve the lib"; FAIL=$((FAIL+1))
fi
# Invoked as a BARE filename from the link's own dir (`bash pr-review-relay`): $_self has no
# slash, so the relative-target branch must resolve against the cwd, not build a bogus
# "pr-review-relay/../real/..." path. Regression for the no-slash case.
if out=$( cd "$LINKD" && bash pr-review-relay --help 2>&1) && ! printf '%s' "$out" | grep -qE 'missing.*lib-(opencode|grok)|cannot resolve'; then
  echo "  ok   [-] bare-filename relative symlink resolves (no-slash \$_self)"; PASS=$((PASS+1))
else
  echo "  FAIL bare-filename relative symlink broke (no-slash case): $(printf '%s' "$out" | head -1)"; FAIL=$((FAIL+1))
fi
# The same bootstrap lives in review-local; symlink it too so the two can't drift.
cp "$HERE/../review-local" "$REALD/" 2>/dev/null
RLINK="$WORK/rlinkbin"; mkdir -p "$RLINK"; ln -s "$REALD/review-local" "$RLINK/review-local"
if out=$(bash "$RLINK/review-local" --help 2>&1) && ! printf '%s' "$out" | grep -qE 'missing.*lib-(opencode|grok)'; then
  echo "  ok   [-] review-local resolves the sibling lib through a symlink"; PASS=$((PASS+1))
else
  echo "  FAIL review-local symlink did not resolve the lib"; FAIL=$((FAIL+1))
fi
# The other sibling-locating entry points (pr-review-consensus / -collapse-comments) got the
# same bootstrap; through a symlink they must not die at SCRIPT_DIR resolution. They fail
# later on missing args/gh — that's fine; we only assert the resolve step itself worked.
cp "$HERE/../pr-review-consensus" "$HERE/../pr-review-collapse-comments" "$REALD/" 2>/dev/null
for s in pr-review-consensus pr-review-collapse-comments; do
  ln -sf "$REALD/$s" "$RLINK/$s"
  err=$( PATH="$BIN:$PATH" bash "$RLINK/$s" 2>&1 || true )
  if ! grep -q 'cannot resolve' <<< "$err"; then
    echo "  ok   [-] $s resolves its own symlink (no SCRIPT_DIR error)"; PASS=$((PASS+1))
  else echo "  FAIL $s failed to resolve its symlink"; FAIL=$((FAIL+1)); fi
done


# --- claude invocation contract ----------------------------------------------
# Earlier tests replace $BIN/claude with minimal stubs (one writes a file to prove plan
# mode is not what stops it; the next restores a bare `echo LGTM`), and neither records
# argv. Rebuild the full stub or every assertion below silently sees no invocation.
make_agent claude
# Claude was the last seat taking BOTH its model and its permissions from ambient config
# (a bare `claude -p`), so a `/model` switch silently changed what the panel reviewed with
# and nothing in the output said so. Unlike the codex/agy overrides, the model default here
# is HARD — asserting the default IS the point of the change, so these run with
# CLAUDE_REVIEW_MODEL cleared, and an exported value in a dev/CI env cannot fake a pass.
CL_ARGV="$WORK/claude-argv.log"
cl_argv_has() { grep -q -- "$1" "$CL_ARGV" 2>/dev/null; }
cl_assert() { # <label> <flag> <want: has|hasnot>
  if [ "$3" = has ]; then
    if cl_argv_has "$2"; then echo "  ok   [-] $1"; PASS=$((PASS+1))
    else echo "  FAIL $1 — argv: $(grep '^claude ' "$CL_ARGV" 2>/dev/null | head -1 || echo '<no claude invocation recorded>')"; FAIL=$((FAIL+1)); fi
  else
    if cl_argv_has "$2"; then echo "  FAIL $1 — argv: $(grep '^claude ' "$CL_ARGV" 2>/dev/null | head -1)"; FAIL=$((FAIL+1))
    else echo "  ok   [-] $1"; PASS=$((PASS+1)); fi
  fi
}
_cl_relay() { # <mode> [env assignments...]
  local mode="$1"; shift
  : > "$CL_ARGV"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
  env PATH="$BIN:$PATH" HOME="$WORK/home" \
    XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
    GH_SHA_COUNTER="$WORK/sha_counter" ARGV_LOG="$CL_ARGV" "$@" \
    bash "$RELAY" --pr 1 --author codex --reviewers claude "--$mode" >/dev/null 2>&1
}

# link and diff are separate branches of the case statement, so both need cover.
for cl_mode in link diff; do
  _cl_relay "$cl_mode" CLAUDE_REVIEW_MODEL= CLAUDE_REVIEW_EFFORT= CLAUDE_REVIEW_FALLBACK_MODEL=
  cl_assert "relay pins the claude model in $cl_mode mode"        '--model opus'             has
  cl_assert "relay sets the claude fallback in $cl_mode mode"     '--fallback-model sonnet'  has
  cl_assert "relay holds claude in plan mode in $cl_mode mode"    '--permission-mode plan'   has
  cl_assert "relay adds --safe-mode for claude in $cl_mode mode"  '--safe-mode'              has
  # Effort is the one opt-in knob: unset it must add NO argument, not an empty string.
  cl_assert "unset CLAUDE_REVIEW_EFFORT adds no argv in $cl_mode mode" '--effort'           hasnot
done

# An unavailable model does NOT fail loudly: measured on claude 2.1.220 it prints
# "There's an issue with the selected model …" on STDOUT, leaves stderr empty, and exits 1.
# A non-zero exit WITH output is still posted (the round is only marked unclean), so that
# error text would land on the PR under a "Claude review" header and the round would be
# spent. --fallback-model turns a guaranteed-wasted round into a real review, which makes
# it part of the contract rather than a convenience — hence asserted above, overridden here.
_cl_relay link CLAUDE_REVIEW_MODEL=sonnet CLAUDE_REVIEW_EFFORT=high CLAUDE_REVIEW_FALLBACK_MODEL=haiku
cl_assert "CLAUDE_REVIEW_MODEL overrides the pinned default"   '--model sonnet'          has
cl_assert "CLAUDE_REVIEW_EFFORT reaches claude argv"           '--effort high'           has
cl_assert "CLAUDE_REVIEW_FALLBACK_MODEL reaches claude argv"   '--fallback-model haiku'  has

# review-local deliberately does NOT get plan/safe mode: it reviews YOUR OWN branch, so
# --safe-mode would only disable your own CLAUDE.md, hooks and MCP for your own review.
# The asymmetry is the decision; assert it, or a later "make the two consistent" pass
# will quietly undo it.
: > "$CL_ARGV"
( cd "$RLREPO2" && env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  CLAUDE_REVIEW_MODEL= CLAUDE_REVIEW_EFFORT= CLAUDE_REVIEW_FALLBACK_MODEL= ARGV_LOG="$CL_ARGV" \
  bash "$RL" --author codex --reviewers claude --base HEAD~1 >/dev/null 2>&1 )
cl_assert "review-local pins the claude model"              '--model opus'            has
cl_assert "review-local sets the claude fallback"           '--fallback-model sonnet' has
cl_assert "review-local adds no --effort when unset"        '--effort'                hasnot
cl_assert "review-local does NOT add --permission-mode"     '--permission-mode'       hasnot
cl_assert "review-local does NOT add --safe-mode"           '--safe-mode'             hasnot

# --- review prompt contract --------------------------------------------------
# The criteria live in six prompt strings across four files. They drift: this repo has
# already shipped one copy of a reviewer invocation while fixing another. The split that
# matters is whether the seat can OPEN A FILE — opencode and grok run tool-less from an
# isolated cwd with no checkout, so telling them to read AGENTS.md would manufacture
# findings about a file they cannot see.
pr_assert() { # <label> <file> <needle> <want: has|hasnot>
  if grep -qF -- "$3" "$2" 2>/dev/null; then
    [ "$4" = has ] && { echo "  ok   [-] $1"; PASS=$((PASS+1)); return; }
    echo "  FAIL $1 — '$3' present in $2"; FAIL=$((FAIL+1)); return
  fi
  [ "$4" = hasnot ] && { echo "  ok   [-] $1"; PASS=$((PASS+1)); return; }
  echo "  FAIL $1 — '$3' missing from $2"; FAIL=$((FAIL+1))
}
# All six prompts carry the criteria.
pr_criteria() { # <label> <file>
  pr_assert "$1 asks about regressions"        "$2" 'regressions'                    has
  pr_assert "$1 asks about missing tests"      "$2" 'inadequate tests'               has
  pr_assert "$1 asks for file/line references" "$2" 'Give a file and line reference'  has
  pr_assert "$1 pins the missing-test severity" "$2" 'Report missing tests as Should-fix' has
  # The severity buckets are what ship-feature's loop-termination rule keys off, and
  # "do not modify" is the only instruction standing between a reviewer and the tree.
  pr_assert "$1 keeps the severity buckets"    "$2" 'Blocker / Should-fix / Nit'      has
}
for cl_mode in link diff; do
  _cl_relay "$cl_mode"
  pr_criteria "relay/$cl_mode prompt" "$CL_ARGV"
  pr_assert "relay/$cl_mode prompt asks for conventions" "$CL_ARGV" 'AGENTS.md, CLAUDE.md' has
  pr_assert "relay/$cl_mode prompt keeps do-not-modify"  "$CL_ARGV" 'modify anything'      has
done
: > "$CL_ARGV"
( cd "$RLREPO2" && env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  ARGV_LOG="$CL_ARGV" bash "$RL" --author codex --reviewers claude --base HEAD~1 >/dev/null 2>&1 )
pr_criteria "review-local prompt" "$CL_ARGV"
pr_assert "review-local prompt asks for conventions" "$CL_ARGV" 'AGENTS.md, CLAUDE.md' has

# The THIRD relay prompt is the local-context one, reached only when the stubbed gh reports this
# checkout as the PR head. Codex flagged that --link and --diff alone leave it uncovered, which is
# how a prompt variant gets edited in source and never exercised. Reuses the local-context repo
# built above; unlike lc_run, ARGV_LOG is set so the argv-logging stub records the prompt.
: > "$CL_ARGV"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
( cd "$LREPO" && env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" \
  GH_SHA_COUNTER="$WORK/sha_counter" GH_LOCAL_HEAD="$LHEAD" ARGV_LOG="$CL_ARGV" \
  bash "$RELAY" --pr 1 --author codex --reviewers claude >/dev/null 2>&1 )
pr_assert "the local-context prompt is the one under test" "$CL_ARGV" 'CHECKED OUT in the current directory' has
pr_criteria "relay/local-context prompt" "$CL_ARGV"
pr_assert "relay/local-context prompt asks for conventions" "$CL_ARGV" 'AGENTS.md, CLAUDE.md' has

# opencode: prompt arrives as argv (`-- "$oc_prompt"`), but only the strict stub records it —
# the generic agent stub is never reached, because the relay resolves the opencode binary
# itself rather than taking it off PATH. grok: only via --prompt-file, stdin is ignored.
OC_PROMPT_ARGV="$WORK/oc-prompt-argv.log"
BIN_OCP="$WORK/bin-ocp"; make_strict_opencode "$BIN_OCP"
rm -f "$OC_PROMPT_ARGV"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" OC_ARGV_FILE="$OC_PROMPT_ARGV" \
  PR_RELAY_OPENCODE_BIN="$BIN_OCP/opencode" \
  bash "$RELAY" --pr 1 --author codex --reviewers opencode >/dev/null 2>&1
pr_criteria "opencode prompt" "$OC_PROMPT_ARGV"
pr_assert "opencode prompt does NOT ask for conventions" "$OC_PROMPT_ARGV" 'AGENTS.md' hasnot

GK_PROMPT="$WORK/grok-prompt-contract.log"
: > "$GK_PROMPT"; rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" HOME="$WORK/home" \
  XDG_CONFIG_HOME="$WORK/xdg" XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" \
  GH_SHA_COUNTER="$WORK/sha_counter" PROMPT_FILE_LOG="$GK_PROMPT" \
  bash "$RELAY" --pr 1 --author codex --reviewers grok >/dev/null 2>&1
pr_criteria "grok prompt" "$GK_PROMPT"
pr_assert "grok prompt does NOT ask for conventions" "$GK_PROMPT" 'AGENTS.md' hasnot

# =============================================================================
# Per-SHA round accounting, and the run-evidence files.
#
# These share ONE cache across calls on purpose — the whole point is what carries over between
# invocations — so they use their own helpers rather than run()/runx(), which wipe it every time.
# =============================================================================
echo "per-SHA round accounting:"
SCACHE="$WORK/scache"
SRF="$SCACHE/pr-review-relay/owner_repo#1.round"
s_reset() { rm -rf "$SCACHE"; mkdir -p "$SCACHE/pr-review-relay"; rm -f "$WORK/sha_counter"; }
s_run() { # s_run <sha> [extra env...] -- [relay args...]; echoes the exit code
  local sha="$1"; shift
  local -a envs=() args=()
  while [ $# -gt 0 ]; do case "$1" in --) shift; args=("$@"); break;; *) envs+=("$1"); shift;; esac; done
  rm -f "$WORK/sha_counter"
  env PATH="$BIN:$PATH" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" \
    GH_FIXED_SHA="$sha" ${envs[@]+"${envs[@]}"} \
    bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex \
      ${args[@]+"${args[@]}"} >/dev/null 2>&1
  echo $?
}
s_state() { cat "$SRF" 2>/dev/null || echo "<missing>"; }
ok_if() { # ok_if <cond-result 0/1> <desc> <detail>
  if [ "$1" = 0 ]; then echo "  ok   [-] $2"; PASS=$((PASS+1)); else echo "  FAIL $2 ($3)"; FAIL=$((FAIL+1)); fi
}

SHA_A=1111111111111111111111111111111111111111
SHA_B=2222222222222222222222222222222222222222
SHA_C=3333333333333333333333333333333333333333

# Same SHA twice: the round counter must NOT move; only the same-SHA counter does. This is the
# whole point of the change — splitting a panel across invocations must be free.
s_reset; rc1=$(s_run "$SHA_A"); rc2=$(s_run "$SHA_A")
read -r _s _r _m < "$SRF" 2>/dev/null || true
[ "$_r" = 1 ] && [ "$_m" = 2 ] && [ "$_s" = "$SHA_A" ]; ok_if $? "same SHA twice → rounds stay 1, same-SHA goes 2" "state=$(s_state) rc=$rc1/$rc2"

# A new SHA is a new round, and the same-SHA counter restarts.
rc3=$(s_run "$SHA_B")
read -r _s _r _m < "$SRF" 2>/dev/null || true
[ "$_r" = 2 ] && [ "$_m" = 1 ] && [ "$_s" = "$SHA_B" ]; ok_if $? "new SHA → round 2, same-SHA resets to 1" "state=$(s_state) rc=$rc3"

# The same-SHA cap fires with its OWN message, and only after the allowance is spent.
s_reset
rcs=""; for _i in 1 2 3; do rcs="$rcs$(s_run "$SHA_A" PR_RELAY_MAX_SAME_SHA=2)"; done
[ "$rcs" = "004" ]; ok_if $? "same-SHA cap → exit 4 on the 3rd dispatch (cap 2)" "rcs=$rcs state=$(s_state)"
s_reset; s_run "$SHA_A" PR_RELAY_MAX_SAME_SHA=1 >/dev/null
_msg=$(env PATH="$BIN:$PATH" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" \
  GH_FIXED_SHA="$SHA_A" PR_RELAY_MAX_SAME_SHA=1 \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex 2>&1 >/dev/null)
grep -q "Same-SHA dispatch cap" <<< "$_msg"; ok_if $? "same-SHA cap names itself (not the round cap)" "msg=${_msg:0:80}"

# A head that MOVED must not be refused by the same-SHA cap: the predicate has to be conditional on
# the stored SHA still matching. Written as a bare "same >= max" this is where it breaks, and it
# would block a genuine fix push.
_rc=$(s_run "$SHA_B" PR_RELAY_MAX_SAME_SHA=1)
[ "$_rc" = 0 ]; ok_if $? "new SHA is NOT blocked by a spent same-SHA allowance" "rc=$_rc state=$(s_state)"

# Distinct SHAs still hit the round cap, with the round-cap message.
s_reset
rcs=""; for _sha in "$SHA_A" "$SHA_B" "$SHA_C"; do rcs="$rcs$(s_run "$_sha" -- --max-rounds 2)"; done
[ "$rcs" = "004" ]; ok_if $? "3 distinct SHAs with --max-rounds 2 → exit 4 on the 3rd" "rcs=$rcs state=$(s_state)"

# Legacy state (a bare integer, what every pre-upgrade cache holds).
s_reset; printf '2' > "$SRF"
_rc=$(s_run "$SHA_A" -- --max-rounds 3)
read -r _s _r _m < "$SRF" 2>/dev/null || true
[ "$_rc" = 0 ] && [ "$_r" = 2 ] && [ "$_m" = 1 ] && [ "$_s" = "$SHA_A" ]; ok_if $? "legacy below cap → adopts the SHA WITHOUT spending a round" "rc=$_rc state=$(s_state)"
# ...and the retries it was upgraded to keep actually work (the point of not incrementing).
_rc=$(s_run "$SHA_A" -- --max-rounds 3)
[ "$_rc" = 0 ]; ok_if $? "legacy at max-1 still allows same-SHA retries after upgrade" "rc=$_rc state=$(s_state)"
# A legacy file already AT the cap keeps its old meaning: stop.
s_reset; printf '3' > "$SRF"
_rc=$(s_run "$SHA_A" -- --max-rounds 3)
[ "$_rc" = 4 ]; ok_if $? "legacy already at the cap → still exit 4" "rc=$_rc"

# Corrupt state must fail SAFE (treated as zero), never crash the relay.
s_reset; printf 'garbage here\n' > "$SRF"
_rc=$(s_run "$SHA_A")
[ "$_rc" = 0 ]; ok_if $? "corrupt state (2 tokens) → treated as zero, run proceeds" "rc=$_rc state=$(s_state)"
s_reset; printf '%s notanumber 1\n' "$SHA_A" > "$SRF"
_rc=$(s_run "$SHA_A")
[ "$_rc" = 0 ]; ok_if $? "corrupt state (non-numeric counter) → treated as zero" "rc=$_rc state=$(s_state)"

# Env validation, matching --max-rounds exactly: it ACCEPTS 0 (always at cap), rejects non-numeric.
s_reset; _rc=$(s_run "$SHA_A" PR_RELAY_MAX_SAME_SHA=nope)
[ "$_rc" = 2 ]; ok_if $? "non-numeric PR_RELAY_MAX_SAME_SHA → usage error" "rc=$_rc"
s_reset; _rc=$(s_run "$SHA_A" PR_RELAY_LOG_MAX_BYTES=nope)
[ "$_rc" = 2 ]; ok_if $? "non-numeric PR_RELAY_LOG_MAX_BYTES → usage error" "rc=$_rc"
s_reset; _rc=$(s_run "$SHA_A" PR_RELAY_LOG_MAX_BYTES=0)
[ "$_rc" = 2 ]; ok_if $? "zero PR_RELAY_LOG_MAX_BYTES → usage error (a 0-byte cap captures nothing)" "rc=$_rc"

# A preflight-only failure still advances nothing — the two-pass split has to preserve this, which
# the old single loop got for free by writing the state late.
s_reset
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA_A" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers bogus >/dev/null 2>&1
[ ! -f "$SRF" ]; ok_if $? "preflight-only failure still advances no state" "state=$(s_state)"
s_reset
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA_A" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --dry-run >/dev/null 2>&1
[ ! -f "$SRF" ]; ok_if $? "dry run advances no state" "state=$(s_state)"

echo "run evidence:"
# The run log and the per-reviewer sidecars.
s_reset; s_run "$SHA_A" >/dev/null
_log=$(ls "$SCACHE"/pr-review-relay/*.run.???????? 2>/dev/null | head -1)
[ -n "$_log" ] && [ -s "$_log" ]; ok_if $? "a run log is created" "log=${_log:-<none>}"
grep -q "^.* start pr=1 " "$_log" 2>/dev/null; ok_if $? "run log records the start line" "$(head -1 "$_log" 2>/dev/null)"
grep -q "pgid=" "$_log" 2>/dev/null; ok_if $? "run log records pid/pgid for kill forensics" "-"
grep -q "state .* (written before dispatch)" "$_log" 2>/dev/null; ok_if $? "run log records the pre-dispatch state write" "-"
grep -q "dispatch claude" "$_log" 2>/dev/null && grep -q "dispatch codex" "$_log" 2>/dev/null; ok_if $? "run log records one dispatch line per reviewer" "-"
grep -q "verdict exit=0" "$_log" 2>/dev/null; ok_if $? "run log records the final verdict" "$(tail -1 "$_log" 2>/dev/null)"
_side=$(ls "$SCACHE"/pr-review-relay/*.k_claude.review 2>/dev/null | head -1)
grep -q "LGTM from claude" "$_side" 2>/dev/null; ok_if $? "the reviewer's body is in its own sidecar" "side=${_side:-<none>}"

# The kill case this whole feature exists for: the review is on disk BEFORE the post is attempted,
# so a failure (or a kill) between the two still leaves the text.
s_reset; s_run "$SHA_A" GH_POST_FAIL=1 >/dev/null
_side=$(ls "$SCACHE"/pr-review-relay/*.k_claude.review 2>/dev/null | head -1)
grep -q "LGTM from claude" "$_side" 2>/dev/null; ok_if $? "sidecar holds the review even when posting fails" "side=${_side:-<none>}"

# Every terminal path logs a verdict, including the failure ones — a log that only recorded
# successes would be silent exactly when someone needs it.
s_reset
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" GH_SHA_DRIFT=1 \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex >/dev/null 2>&1
_log=$(ls "$SCACHE"/pr-review-relay/*.run.???????? 2>/dev/null | head -1)
grep -q "verdict exit=3 head moved" "$_log" 2>/dev/null; ok_if $? "a post-dispatch exit-3 path logs its verdict" "$(tail -1 "$_log" 2>/dev/null)"

# Under --parallel each reviewer owns its own file, so nothing interleaves. Distinct sidecars, each
# containing exactly its own reviewer's output, is what proves it.
s_reset
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA_A" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex,qwen --parallel >/dev/null 2>&1
_n=$(ls "$SCACHE"/pr-review-relay/*.review 2>/dev/null | wc -l)
_bad=0
for _f in "$SCACHE"/pr-review-relay/*.review; do
  _key=$(basename "$_f" | sed 's/.*\.k_\(.*\)\.review/\1/')
  grep -q "LGTM from $_key" "$_f" || _bad=1
  # no other reviewer's text may appear in this file
  for _o in claude codex qwen; do
    [ "$_o" = "$_key" ] && continue
    grep -q "LGTM from $_o" "$_f" && _bad=1
  done
done
[ "$_n" = 3 ] && [ "$_bad" = 0 ]; ok_if $? "--parallel: 3 sidecars, no cross-contamination" "n=$_n bad=$_bad"

# Truncation is a bound on the WRITE path (a runaway agent must not fill the disk), and it must not
# be mistaken for a reviewer failure — a merely long review would otherwise fail the round.
cat > "$BIN2/verbose-claude" <<'VB'
#!/usr/bin/env bash
head -c 200000 /dev/zero | tr '\0' 'x'
VB
chmod +x "$BIN2/verbose-claude" 2>/dev/null
BINV="$WORK/binv"; mkdir -p "$BINV"
for t in gh codex; do ln -sf "$BIN/$t" "$BINV/$t"; done
ln -sf "$(command -v node)" "$BINV/node" 2>/dev/null
cp "$BIN2/verbose-claude" "$BINV/claude"
s_reset
_rc=$(env PATH="$BINV:/usr/bin:/bin" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" \
  GH_FIXED_SHA="$SHA_A" PR_RELAY_LOG_MAX_BYTES=4096 \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1; echo $?)
_side=$(ls "$SCACHE"/pr-review-relay/*.k_claude.review 2>/dev/null | head -1)
_sz=$(wc -c < "$_side" 2>/dev/null || echo 0)
# A truncated review is an INCOMPLETE one, so the round must NOT be clean: the findings that did
# not fit are indistinguishable from findings that do not exist, and exit 0 claims every reviewer
# "produced and posted a review". The text is still posted, and the round reports 3.
[ "$_rc" = 3 ]; ok_if $? "an oversized (truncated) review makes the round NOT clean" "rc=$_rc"
[ "$_sz" -le 6000 ]; ok_if $? "oversized review is bounded on disk by the write path" "size=$_sz"
grep -q "truncated at 4096 bytes" "$_side" 2>/dev/null; ok_if $? "truncation is marked in the body" "-"
grep -q "INCOMPLETE" "$_side" 2>/dev/null; ok_if $? "the marker says the review is incomplete" "-"

# --reset (and the 6h staleness path it shares) must clear the WHOLE family. A fresh counter next to
# a stale transcript would make the forensics describe the wrong session.
# Asserted by IDENTITY, not by counting: a --reset run creates a fresh log family of its own, so
# "the file count did not grow" passes just as happily when nothing was deleted. Capture the old
# run's actual path and require THAT to be gone.
s_reset; s_run "$SHA_A" >/dev/null
_oldlog=$(ls "$SCACHE"/pr-review-relay/*.run.???????? 2>/dev/null | head -1)
_oldside=$(ls "$SCACHE"/pr-review-relay/*.k_claude.review 2>/dev/null | head -1)
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA_A" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --reset >/dev/null 2>&1
[ -n "$_oldlog" ] && [ ! -e "$_oldlog" ] && [ -n "$_oldside" ] && [ ! -e "$_oldside" ]
ok_if $? "--reset removes the previous run's log AND sidecars (by path)" "log=${_oldlog:-<none>} side=${_oldside:-<none>}"

# The 6h staleness path shares relay_forget_key with --reset, so it must clear the same family.
# Backdate the state file rather than waiting: the relay compares its mtime against 21600s.
s_reset; s_run "$SHA_A" >/dev/null
_oldlog=$(ls "$SCACHE"/pr-review-relay/*.run.???????? 2>/dev/null | head -1)
touch -d "8 hours ago" "$SRF" 2>/dev/null || touch -A -080000 "$SRF" 2>/dev/null
s_run "$SHA_A" >/dev/null
[ -n "$_oldlog" ] && [ ! -e "$_oldlog" ]; ok_if $? "6h staleness clears the old run family too" "log=${_oldlog:-<none>}"
# ...and it really did start a fresh session rather than continuing the old counters.
read -r _s _r _m < "$SRF" 2>/dev/null || true
[ "$_r" = 1 ] && [ "$_m" = 1 ]; ok_if $? "6h staleness restarts the counters" "state=$(s_state)"

# The atomic state write leaves <key>.state.XXXXXXXX temps if killed mid-write; --reset must sweep
# those too, or they accumulate forever.
s_reset; s_run "$SHA_A" >/dev/null
: > "$SCACHE/pr-review-relay/owner_repo#1.state.DEADBEEF"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA_A" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --reset >/dev/null 2>&1
[ ! -e "$SCACHE/pr-review-relay/owner_repo#1.state.DEADBEEF" ]; ok_if $? "--reset sweeps orphaned state temps" "-"

# NOTE ON WHAT IS *NOT* TESTED HERE. The relay refuses to write a sidecar whose path is already a
# symlink. That check cannot be exercised honestly from this suite: the sidecar name is derived from
# RUN_BASE, which mktemp created O_EXCL moments earlier inside a mode-700 directory we own, so the
# path provably did not exist and no attacker could have planted anything at it. Reaching the branch
# would need a test-only override in the script, i.e. production surface that exists solely to be
# tested. An earlier version of this file claimed to cover it and merely asserted that the state
# directory existed — it tested nothing, which cross-review caught. Better an acknowledged gap than
# a green line that means nothing. The real control is the directory's ownership and mode, which is
# enforced on every branch of the ROUND_DIR resolution.

# --- the kill this feature exists for ----------------------------------------
# SIGKILL the relay mid-round and assert the evidence survived. The relay runs in its OWN process
# group and the GROUP is killed: killing only the parent leaves the sleeping agent stub as an orphan
# that can still write, race these assertions, or hang the suite's EXIT trap.
# `set -m` gives the background job its own PGID and works where `setsid` is absent (macOS).
s_reset
if ( set -m ) 2>/dev/null; then
  ( set -m
    env PATH="$BIN:$PATH" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" \
      GH_FIXED_SHA="$SHA_A" SLEEP_KEYS=codex PR_RELAY_AGENT_TIMEOUT=60 \
      bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex >/dev/null 2>&1 &
    _kid=$!
    _pgid=$(ps -o pgid= -p "$_kid" 2>/dev/null | tr -d ' ')
    printf '%s' "$_pgid" > "$WORK/killed_pgid"
    # Wait, bounded, for the evidence we are about to assert on to exist — never a fixed sleep.
    # Wait for the sidecar's CONTENT, not merely its existence. The sidecar is created (header
    # first) before the agent is launched, so "the file is there" is true almost immediately and
    # the kill would race the reviewer that this case is meant to prove survives.
    _w=0
    while [ "$_w" -lt 200 ]; do
      [ -f "$SRF" ] && grep -q "LGTM from claude" "$SCACHE"/pr-review-relay/*.k_claude.review 2>/dev/null && break
      sleep 0.1; _w=$((_w+1))
    done
    [ -n "$_pgid" ] && kill -9 -- -"$_pgid" 2>/dev/null
    # ...and bounded-wait for the group to actually be gone before asserting.
    _w=0
    while [ "$_w" -lt 100 ] && kill -0 "$_kid" 2>/dev/null; do sleep 0.1; _w=$((_w+1)); done
    wait "$_kid" 2>/dev/null
  )
  _pgid=$(cat "$WORK/killed_pgid" 2>/dev/null)
  _log=$(ls "$SCACHE"/pr-review-relay/*.run.???????? 2>/dev/null | head -1)
  _side=$(ls "$SCACHE"/pr-review-relay/*.k_claude.review 2>/dev/null | head -1)
  [ -n "$_log" ] && grep -q " start pr=1 " "$_log" 2>/dev/null; ok_if $? "SIGKILL: the start line survived" "log=${_log:-<none>}"
  grep -q "state .* (written before dispatch)" "$_log" 2>/dev/null; ok_if $? "SIGKILL: the pre-dispatch state write survived" "-"
  [ -f "$SRF" ]; ok_if $? "SIGKILL: the round state file exists (the loop stays bounded)" "state=$(s_state)"
  [ -n "$_side" ] && grep -q "LGTM from claude" "$_side" 2>/dev/null; ok_if $? "SIGKILL: the finished reviewer's output survived" "side=${_side:-<none>}"
  # And no orphan is left behind to write after we asserted. Scoped to the process GROUP we killed:
  # `pgrep -f SLEEP_KEYS` scanned the whole machine and matched any unrelated process whose command
  # line happened to contain that string — including the cross-review agents reading this very diff,
  # which made the suite fail during review. A self-matching assertion is worse than none.
  # Bounded wait, not an instant check: the group can briefly outlive its leader — `timeout` puts
  # the agent in a group of its OWN (the relay's comments say so), so the group-kill does not reach
  # it, and the stderr drain stays alive while anything still holds the write end. Both go away on
  # their own within the stub's sleep. Asserting immediately made this flake.
  _w=0
  while [ "$_w" -lt 120 ] && kill -0 -"$_pgid" 2>/dev/null; do sleep 0.1; _w=$((_w+1)); done
  ! kill -0 -"$_pgid" 2>/dev/null; ok_if $? "SIGKILL: the whole process group is gone, no orphans" "pgid=$_pgid waited=${_w}00ms"
else
  echo "  skip [-] SIGKILL test: no job control (set -m) available in this shell"
fi
unset _s _r _m _rc _log _side _sz _n _bad _key _o _f _before _old _msg _i _sha _w _kid _pgid rcs rc1 rc2 rc3

# --- hermeticity, asserted rather than assumed --------------------------------
# The header unsets the inherited git environment. If someone deletes those lines, everything here
# still passes when run by hand and quietly corrupts the repo when run from a hook — which is the
# exact history of this file. So check the invariant, and check the property it exists for.
echo "hermeticity:"
[ -z "${GIT_DIR:-}${GIT_WORK_TREE:-}${GIT_INDEX_FILE:-}" ]; ok_if $? "the inherited git environment is cleared" "GIT_DIR=${GIT_DIR:-} GIT_WORK_TREE=${GIT_WORK_TREE:-}"
# The property: a fixture's commits land in the FIXTURE, not in whatever repo we were launched from.
HERM="$WORK/hermetic"; rm -rf "$HERM"; mkdir -p "$HERM"
( cd "$HERM" && git init -q . && echo x > x.txt && git add x.txt \
    && git -c user.email=t@t -c user.name=t commit -qm "fixture-local" ) >/dev/null 2>&1
_here=$(git -C "$HERM" log --oneline 2>/dev/null | grep -c "fixture-local")
[ "$_here" = 1 ]; ok_if $? "a fixture's commit lands in the fixture repo" "found=$_here"
unset _here

# --- gaps round 2 asked for ---------------------------------------------------
echo "round-2 coverage:"

# Truncation must be caught by SIZE, with no SIGPIPE involved. This stub writes past the cap and
# exits 0 of its own accord, which is exactly the case the old rc=141 check let through.
BINQ="$WORK/binq"; mkdir -p "$BINQ"
for t in gh codex; do ln -sf "$BIN/$t" "$BINQ/$t"; done
ln -sf "$(command -v node)" "$BINQ/node" 2>/dev/null
cat > "$BINQ/claude" <<'VB'
#!/usr/bin/env bash
# Write more than the cap, then exit 0 WITHOUT being killed: head has already taken what it wants.
trap '' PIPE
head -c 20000 /dev/zero | tr '\0' 'y' 2>/dev/null
exit 0
VB
chmod +x "$BINQ/claude"
s_reset
_rc=$(env PATH="$BINQ:/usr/bin:/bin" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" \
  GH_FIXED_SHA="$SHA_A" PR_RELAY_LOG_MAX_BYTES=4096 \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1; echo $?)
_side=$(ls "$SCACHE"/pr-review-relay/*.k_claude.review 2>/dev/null | head -1)
[ "$_rc" = 3 ]; ok_if $? "overflow detected without SIGPIPE → round not clean" "rc=$_rc"
grep -q "INCOMPLETE" "$_side" 2>/dev/null; ok_if $? "overflow without SIGPIPE is still marked" "-"

# A cap exit must leave a verdict in the log, not just a return code.
s_reset; s_run "$SHA_A" PR_RELAY_MAX_SAME_SHA=1 >/dev/null
s_run "$SHA_A" PR_RELAY_MAX_SAME_SHA=1 >/dev/null
_log=$(ls -t "$SCACHE"/pr-review-relay/*.run.???????? 2>/dev/null | head -1)
grep -q "verdict exit=4 same-SHA cap" "$_log" 2>/dev/null; ok_if $? "an exit-4 cap hit logs its verdict" "$(tail -1 "$_log" 2>/dev/null)"

# PR_RELAY_MAX_SAME_SHA=0: documented asymmetry — the same-SHA cap is only consulted once a SHA has
# been seen before, so 0 still allows the first dispatch and blocks every retry.
s_reset
_r1=$(s_run "$SHA_A" PR_RELAY_MAX_SAME_SHA=0); _r2=$(s_run "$SHA_A" PR_RELAY_MAX_SAME_SHA=0)
[ "$_r1" = 0 ] && [ "$_r2" = 4 ]; ok_if $? "MAX_SAME_SHA=0 allows the first dispatch, blocks retries" "r1=$_r1 r2=$_r2"

# The GIT_CONFIG_* half of the hermeticity fix needs its own guard: deleting those exports would
# otherwise leave the suite green here and hanging on a signing machine.
[ "${GIT_CONFIG_COUNT:-0}" -ge 2 ]; ok_if $? "the git config override is exported" "count=${GIT_CONFIG_COUNT:-unset}"
_sg=$( (cd "$WORK" && git config --get commit.gpgsign) 2>/dev/null )
[ "$_sg" = "false" ]; ok_if $? "commit signing is forced off for every fixture git" "gpgsign=$_sg"

# Runaway stderr must be bounded WITHOUT killing the reviewer. The stderr cap drains past the limit
# rather than closing the pipe: closing it makes the agent's next write take SIGPIPE, which killed a
# perfectly healthy, merely chatty reviewer that was producing a good review on stdout. The stub
# below writes far past the cap on stderr and THEN produces its review, so it only passes if it
# survived. (The previous version of this test was `ok_if 0 "..."` — hard-coded success, proving
# nothing. Cross-review caught it.)
cat > "$BINQ/claude" <<'VB'
#!/usr/bin/env bash
head -c 200000 /dev/zero | tr '\0' 'e' >&2 2>/dev/null
echo "LGTM from claude."
VB
chmod +x "$BINQ/claude"
s_reset
_rc=$(env PATH="$BINQ:/usr/bin:/bin" XDG_CACHE_HOME="$SCACHE" GH_SHA_COUNTER="$WORK/sha_counter" \
  GH_FIXED_SHA="$SHA_A" PR_RELAY_LOG_MAX_BYTES=4096 \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude >/dev/null 2>&1; echo $?)
_side=$(ls "$SCACHE"/pr-review-relay/*.k_claude.review 2>/dev/null | head -1)
[ "$_rc" = 0 ]; ok_if $? "a chatty-stderr reviewer survives the cap and the round is clean" "rc=$_rc"
grep -q "LGTM from claude" "$_side" 2>/dev/null; ok_if $? "...and its review still arrived in full" "side=${_side:-<none>}"

# The revert case is the whole subtlety of "SHA transitions, not distinct SHAs": going back to a SHA
# already reviewed spends a THIRD slot, because only the last SHA is stored.
s_reset
s_run "$SHA_A" >/dev/null; s_run "$SHA_B" >/dev/null; s_run "$SHA_A" >/dev/null
read -r _s _r _m < "$SRF" 2>/dev/null || true
[ "$_r" = 3 ] && [ "$_s" = "$SHA_A" ]; ok_if $? "shaA→shaB→shaA spends three rounds (transitions, not distinct SHAs)" "state=$(s_state)"

# The round cap must log its verdict too, matching the same-SHA cap's coverage.
s_reset
s_run "$SHA_A" -- --max-rounds 1 >/dev/null
_rc=$(s_run "$SHA_B" -- --max-rounds 1)
_log=$(ls -t "$SCACHE"/pr-review-relay/*.run.???????? 2>/dev/null | head -1)
[ "$_rc" = 4 ] && grep -q "verdict exit=4 round cap" "$_log" 2>/dev/null
ok_if $? "an exit-4 ROUND cap hit logs its verdict too" "rc=$_rc $(tail -1 "$_log" 2>/dev/null)"

# MAX_ROUNDS=0 is documented as "always at cap": the first dispatch on a new SHA is refused, and
# nothing is persisted.
s_reset
_rc=$(s_run "$SHA_A" PR_RELAY_MAX_ROUNDS=0)
[ "$_rc" = 4 ] && [ ! -f "$SRF" ]; ok_if $? "MAX_ROUNDS=0 refuses the first dispatch and persists nothing" "rc=$_rc state=$(s_state)"

unset _r1 _r2 _sg _log _side _rc

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
