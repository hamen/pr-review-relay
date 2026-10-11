#!/usr/bin/env bash
# Tests for pr-review-relay --verdict-file: the machine-readable record of a round.
#
# Stubs `gh` and the agent CLIs, runs the relay against a fake PR, and reads the KEY=value file it
# leaves. What this pins: `all_clean=true` is reachable only by a full, clean, posted round on an
# unmoved head, and every way of being less than that writes `false`; the verdict line parse is
# strict; and without the flag nothing about a round changes.
#
# No network, no real agents. Run: bash test/test-verdict.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RELAY="$HERE/../pr-review-relay"
WORK="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
export PR_RELAY_CONFIG="$WORK/no-such-panel-config"
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "no temp dir" >&2; exit 1; }
BIN="$WORK/bin"; mkdir -p "$BIN"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
# shellcheck source=lib-hermetic.sh
. "$HERE/lib-hermetic.sh"
relay_require_git_2_31
relay_isolate_git "$WORK"

# --- stub: gh (the same one test-fail-closed.sh uses) -------------------------
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view"|"pr diff")
    [ -n "${GH_READ_LOG:-}" ] && echo "read repo=${GH_REPO:-none} $*" >> "$GH_READ_LOG"
    ;;
esac
case "$1 $2" in
  "pr view")
    if printf '%s\n' "$@" | grep -q headRefOid; then
      if [ -n "${GH_SHA_HANG:-}" ]; then : > "${GH_HANG_MARK:?}"; sleep 600; fi
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
    elif printf '%s\n' "$@" | grep -q url; then echo "${GH_PR_URL-http://example.test/owner/repo/pull/1}"
    elif printf '%s\n' "$@" | grep -q number; then echo 1
    fi ;;
  "repo view") echo "${GH_REPO_VIEW:-owner/repo}" ;;
  # GH_DIFF_HANG makes the diff fetch block forever, so a test can kill the relay
  # *during* the network call and assert what evidence already exists on disk.
  # GH_BIG_DIFF_LINES emits a diff of a chosen length, ending in a marker. The
  # opencode seat used to lose everything past ~1035 lines of an -f attachment, and
  # the two-line diff below is far too small to reproduce that: a test that only
  # feeds it proves the plumbing, not the bug.
  "pr diff")   if [ -n "${GH_DIFF_HANG:-}" ]; then : > "${GH_HANG_MARK:?}"; sleep 600; fi; [ -n "${GH_EMPTY_DIFF:-}" ] && exit 0
               # GH_DIFF_BYTES: a diff of about that many bytes (80-byte lines), ending in a marker.
               if [ -n "${GH_DIFF_BYTES:-}" ]; then
                 echo "diff --git a/big b/big"
                 awk -v n="$GH_DIFF_BYTES" 'BEGIN { l = "+" sprintf("%79s", ""); gsub(/ /, "d", l); t = 0; while (t < n) { print l; t += 81 } }'
                 echo "+DIFF-TAIL-MARKER"
                 exit 0
               fi
               if [ -n "${GH_BIG_DIFF_LINES:-}" ]; then
                 echo "diff --git a/big b/big"
                 i=1; while [ "$i" -le "$GH_BIG_DIFF_LINES" ]; do echo "+line $i"; i=$((i+1)); done
                 echo "+TAIL-MARKER-REACHED"
                 exit 0
               fi
               echo "diff --git a/x b/x"; echo "+change" ;;
  "pr comment")
    # GH_BODY_DIR keeps every posted body, so a test can assert what was (not) published.
    if [ -n "${GH_BODY_DIR:-}" ]; then
      _prev=""; for _a in "$@"; do [ "$_prev" = "--body-file" ] && cat -- "$_a" >> "$GH_BODY_DIR/bodies"; _prev="$_a"; done
    fi
    [ -n "${GH_POST_FAIL:-}" ] && exit 1; [ -n "${GH_POST_LOG:-}" ] && echo "posted host=${GH_HOST:-default} $*" >> "$GH_POST_LOG"; exit 0 ;;
  "api "*|"api")
    [ -n "${GH_API_LOG:-}" ] && echo "api host=${GH_HOST:-default} $*" >> "$GH_API_LOG"
    echo "" ;;
  *) echo "" ;;
esac
exit 0
GH
chmod +x "$BIN/gh"

# --- stub: agents. OUT_<key> sets what a seat prints; the default is a clean review. --------------
make_agent() {
  cat > "$BIN/$1" <<AG
#!/usr/bin/env bash
self="\$(basename "\$0")"
case "\$self" in cursor-agent) key=cursor;; agy) key=antigravity;; *) key="\$self";; esac
case ",\${SLEEP_KEYS:-}," in *",\$key,"*) sleep 5;; esac
case ",\${QUOTA_ERR:-}," in *",\$key,"*) echo "Error: Individual quota reached. Resets in 2h30m0s." >&2; exit 1;; esac
[ -n "\${CHMOD_DIR:-}" ] && chmod 555 "\$CHMOD_DIR"
[ -n "\${ARGV_LOG:-}" ] && printf '%s %s\n' "\$self" "\$*" >> "\$ARGV_LOG"
if [ -n "\${STDIN_LOG:-}" ]; then { printf '=== %s stdin ===\n' "\$self"; cat; printf '\n'; } >> "\$STDIN_LOG"; fi
if [ -n "\${PROMPT_FILE_LOG:-}" ]; then
  _args=("\$@")
  for ((_i=0; _i<\${#_args[@]}; _i++)); do
    if [ "\${_args[\$_i]}" = "--prompt-file" ]; then
      _pf="\${_args[\$((_i+1))]}"
      [ -n "\$_pf" ] && [ -f "\$_pf" ] && { printf 'PROMPT_FILE %s\n' "\$self"; cat -- "\$_pf"; } >> "\$PROMPT_FILE_LOG"
      break
    fi
  done
fi
var="OUT_\$key"
if [ -n "\${!var:-}" ]; then printf '%b\n' "\${!var}"; else printf 'Looks good.\nVERDICT: clean\n'; fi
exit 0
AG
  chmod +x "$BIN/$1"
}
for a in claude codex cursor-agent agy opencode qwen grok; do make_agent "$a"; done
SHA40=0123456789abcdef0123456789abcdef01234567

PASS=0; FAIL=0
ok()  { echo "  ok   $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
chk() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

VF="$WORK/v/round.verdict"; mkdir -p "$WORK/v"
# run <desc-less> : relay with the verdict file; env assignments before --, relay args after.
RC=0
vrun() {
  rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter" "$VF"
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  # The panel comes from a CONFIG FILE (REVIEWERS=...), the one place "configured" is read from.
  printf 'REVIEWERS=%s\n' "${PANEL:-claude,codex}" > "$WORK/cfg"
  env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA40" \
      PR_RELAY_CONFIG="$WORK/cfg" "${envs[@]+"${envs[@]}"}" \
    bash "$RELAY" --pr 1 --author "${AUTHOR_ARG:-antigravity}" --verdict-file "$VF" "$@" >"$WORK/out" 2>"$WORK/err"
  RC=$?
}
val() { sed -n "s/^$1=//p" "$VF" 2>/dev/null | head -1; }
count() { grep -c "^$1=" "$VF" 2>/dev/null || true; }

echo "pr-review-relay --verdict-file tests:"

# --- the positive case ------------------------------------------------------------------------
vrun -- --reviewers claude,codex
[ "$RC" = 0 ] && [ "$(val all_clean)" = true ]; chk $? "full clean round → exit 0, all_clean=true"
[ "$(val seat.claude)" = clean ] && [ "$(val seat.codex)" = clean ]; chk $? "both seats clean"
[ "$(val requested)" = "claude codex" ] && [ "$(val configured)" = "claude codex" ] && [ "$(val ran)" = "claude codex" ] && [ -z "$(val benched)" ]; chk $? "requested == configured == ran, none benched"
[ "$(val repo)" = owner/repo ] && [ "$(val pr)" = 1 ] && [ "$(val head_sha)" = "$SHA40" ] && [ "$(val exit)" = 0 ] && [ "$(val author)" = antigravity ]; chk $? "repo, pr, head_sha, exit, author recorded"
[ -n "$(val run_id)" ] && [ -n "$(val ts)" ] && [ -n "$(val round)" ]; chk $? "run_id, ts, round recorded"
[ "$(stat -c %a "$VF" 2>/dev/null || stat -f %Lp "$VF")" = 600 ]; chk $? "file is mode 0600"
[ "$(count all_clean)" = 1 ] && [ "$(count exit)" = 1 ]; chk $? "exactly one all_clean and one exit line (the EXIT trap ran once, not in each seat)"
[ -z "$(ls -A "$WORK/v" | grep -v '^round.verdict$')" ]; chk $? "no temp file left beside the verdict file (atomic rename)"

# the wrapper style: an explicit list equal to the configuration is a FULL panel, in any order
vrun -- --reviewers codex,claude
[ "$(val all_clean)" = true ]; chk $? "explicit --reviewers equal to the configured set (other order) → full"
PANEL=claude,codex,antigravity vrun -- --reviewers claude,codex
[ "$(val all_clean)" = true ] && [ "$(val configured)" = "claude codex" ]; chk $? "the author is removed from the configured seats"
PANEL=claude,codex vrun --
[ "$(val all_clean)" = true ]; chk $? "no --reviewers: the configured panel runs and is full"
# the wrapper's shape (ship-feature relay passes the WHOLE quorum, author included): requested and configured
# both lose the author, so the round is full (round-2 review, opencode)
PANEL=claude,codex,grok,opencode AUTHOR_ARG=claude vrun -- --reviewers claude,codex,grok,opencode
[ "$RC" = 0 ] && [ "$(val requested)" = "codex grok opencode" ] && [ "$(val configured)" = "codex grok opencode" ] && [ "$(val all_clean)" = true ]; chk $? "author inside --reviewers (the ship-feature wrapper's shape): author dropped from both sides, all_clean=true"
# `round` is the relay's per-SHA round counter: it advances when the head SHA changes, not on a re-run of one SHA
rr() { env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/rcache" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$1" PR_RELAY_CONFIG="$WORK/cfg" \
         bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --verdict-file "$VF" >/dev/null 2>&1; val round; }
printf 'REVIEWERS=claude,codex\n' > "$WORK/cfg"; rm -rf "$WORK/rcache"; mkdir -p "$WORK/rcache"
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
r1=$(rr $SHA_A); r2=$(rr $SHA_B); r3=$(rr $SHA_B); r4=$(rr $SHA_A)
[ "$r1" = 1 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ] ; chk $? "round: 1 on the first SHA, 2 on a new SHA, still 2 on a re-run of it (got $r1,$r2,$r3)"
# the alias: --author agy is the antigravity seat, whichever way the config spells it
PANEL=claude,codex,antigravity AUTHOR_ARG=agy vrun -- --reviewers claude,codex
[ "$(val all_clean)" = true ] && [ "$(val author)" = antigravity ] && [ "$(val configured)" = "claude codex" ]; chk $? "--author agy with the config naming antigravity → the author is removed, round is full"
PANEL=claude,codex,agy AUTHOR_ARG=antigravity vrun -- --reviewers claude,codex
[ "$(val all_clean)" = true ] && [ "$(val configured)" = "claude codex" ]; chk $? "--author antigravity with the config naming agy → the author is removed, round is full"
# an environment override must not shrink what "configured" means (round-1 review, codex)
PANEL=claude,codex,grok vrun PR_RELAY_REVIEWERS=claude -- --reviewers claude
[ "$RC" = 0 ] && [ "$(val configured)" = "claude codex grok" ] && [ "$(val requested)" = claude ] && [ "$(val all_clean)" = false ]; chk $? "PR_RELAY_REVIEWERS=claude over a 3-seat config → configured stays 3 seats, all_clean=false"
PANEL=claude,codex,grok vrun PR_RELAY_REVIEWERS=claude --
[ "$(val configured)" = "claude codex grok" ] && [ "$(val all_clean)" = false ]; chk $? "the same override without --reviewers (the env list runs) → still not full"

# --- what a full round is NOT -----------------------------------------------------------------
PANEL=claude,codex,grok vrun -- --reviewers claude,codex
[ "$RC" = 0 ] && [ "$(val all_clean)" = false ]; chk $? "a --reviewers list shorter than the configuration → all_clean=false"
PANEL=claude vrun -- --reviewers claude,codex
[ "$(val all_clean)" = false ]; chk $? "a --reviewers list longer than the configuration → all_clean=false"
vrun OUT_codex='Found a bug.\nVERDICT: findings blockers=1 should_fix=0' -- --reviewers claude,codex
[ "$RC" = 0 ] && [ "$(val seat.codex)" = findings ] && [ "$(val all_clean)" = false ]; chk $? "one seat reports findings → all_clean=false (relay exit stays 0)"
vrun QUOTA_ERR=codex -- --reviewers claude,codex
[ "$RC" = 0 ] && [ "$(val benched)" = codex ] && [ "$(val all_clean)" = false ]; chk $? "a benched seat → all_clean=false, benched named"
vrun SLEEP_KEYS=codex PR_RELAY_AGENT_TIMEOUT=1 -- --reviewers claude,codex
[ "$RC" = 3 ] && [ "$(val exit)" = 3 ] && [ "$(val all_clean)" = false ]; chk $? "a timeout (exit 3) → all_clean=false, exit=3 recorded"
vrun GH_SHA_DRIFT=1 GH_FIXED_SHA= -- --reviewers claude,codex
[ "$RC" = 3 ] && [ "$(val all_clean)" = false ]; chk $? "head moved during the round → exit 3, all_clean=false"
vrun -- --reviewers claude,codex --max-rounds 0
[ "$RC" = 4 ] && [ "$(val exit)" = 4 ] && [ "$(val all_clean)" = false ]; chk $? "round cap (exit 4) → file written, all_clean=false"
vrun -- --reviewers claude,codex --no-post
[ "$RC" = 0 ] && [ "$(val all_clean)" = false ]; chk $? "--no-post: nothing is on the PR → all_clean=false"
vrun -- --reviewers claude,codex --dry-run
[ "$RC" = 0 ] && [ "$(val all_clean)" = false ]; chk $? "--dry-run → all_clean=false"
# a configured seat whose CLI is missing is a tolerated skip in a default run, and the round is still not full
rm -f "$BIN/cursor-agent"
if ! PATH="$BIN:$PATH" command -v cursor-agent >/dev/null 2>&1; then
  PANEL=claude,codex,cursor vrun --
  [ "$RC" = 0 ] && [ "$(val requested)" = "claude codex cursor" ] && [ "$(val ran)" = "claude codex" ] && [ "$(val all_clean)" = false ]; chk $? "a configured seat that is not installed (tolerated skip) → ran != requested → all_clean=false"
else
  echo "  skip (a real cursor-agent is installed on this machine)"
fi
make_agent cursor-agent

# --- the verdict line parse is strict ---------------------------------------------------------
parse_case() { # <desc> <expected seat verdict> <OUT_codex text>
  vrun OUT_codex="$3" -- --reviewers claude,codex
  [ "$(val seat.codex)" = "$2" ] && { [ "$2" = clean ] || [ "$(val all_clean)" = false ]; }; chk $? "$1 → $2"
}
parse_case "exact clean line, last" clean 'No issues.\nVERDICT: clean'
parse_case "clean followed by blank lines" clean 'No issues.\nVERDICT: clean\n\n'
parse_case "well-formed findings line" findings 'x\nVERDICT: findings blockers=0 should_fix=2'
parse_case "no verdict line at all" unknown 'LGTM'
parse_case "wrong case" unknown 'ok\nVERDICT: Clean'
parse_case "trailing text after clean" unknown 'ok\nVERDICT: clean.'
parse_case "trailing space after clean" unknown 'ok\nVERDICT: clean '
parse_case "two verdict lines" unknown 'VERDICT: findings blockers=1 should_fix=0\nfixed it\nVERDICT: clean'
parse_case "verdict line is not the last line" unknown 'VERDICT: clean\nOne more thing: a Blocker.'
parse_case "findings with a missing count" unknown 'x\nVERDICT: findings blockers=1'
parse_case "CRLF line ending" unknown 'ok\nVERDICT: clean\r'
parse_case "a quoted verdict in prose plus the real one" unknown 'The format is\nVERDICT: clean\nbut this PR has issues.\nVERDICT: findings blockers=0 should_fix=1'


# --- verdict_write on its own: every condition is checked by itself --------------------------
# A run through the relay cannot isolate a condition that another one also implies (a seat that
# did not run also has no verdict, so it is `unknown` as well). Here the script's own writer is
# lifted between its markers and fed a built world in which EXACTLY ONE thing is wrong.
LIB="$WORK/verdict-lib.sh"
sed -n '/^# verdict-lib:start/,/^# verdict-lib:end/p' "$RELAY" > "$LIB"
sed -n '/^status_key()/p' "$RELAY" >> "$LIB"
[ -s "$LIB" ] && grep -q '^verdict_write()' "$LIB" && grep -q '^status_key()' "$LIB"; chk $? "the verdict code can be lifted from the script by its markers"
unit() { # <rc> <setup commands run in the world before verdict_write> ; prints all_clean
  (
    set -u
    . "$LIB"
    D="$(mktemp -d)"; STATUS_DIR="$D/s"; VERDICT_DIR="$D/v"; mkdir -p "$STATUS_DIR" "$VERDICT_DIR"
    VERDICT_FILE="$D/out.verdict"; AUTHOR=antigravity; CONFIG_REVIEWERS="claude,codex,antigravity"
    REQ_LIST=" claude codex"; BENCHED_LIST=""; REPO=o/r; PR=1; NEXT_ROUND=1; DRY=0; NO_POST=0
    HEAD_SHA="$SHA40"; NEW_SHA="$SHA40"
    for s in claude codex; do k="$(status_key "$s")"; echo ok > "$STATUS_DIR/$k"; echo clean > "$VERDICT_DIR/$k"; done
    rc=0
    eval "$1"
    verdict_write "$rc" || echo "write-failed"
    sed -n 's/^all_clean=//p' "$VERDICT_FILE"
    rm -rf "$D"
  )
}
[ "$(unit 'true')" = true ]; chk $? "unit: the baseline world is all_clean=true"
[ "$(unit 'rc=3')" = false ]; chk $? "unit: exit 3 alone → false"
[ "$(unit 'rc=4')" = false ]; chk $? "unit: exit 4 alone → false"
[ "$(unit 'DRY=1')" = false ]; chk $? "unit: dry run alone → false"
[ "$(unit 'NO_POST=1')" = false ]; chk $? "unit: --no-post alone → false"
[ "$(unit 'rm "$STATUS_DIR/$(status_key codex)"')" = false ]; chk $? "unit: a requested seat that never ran (verdict file present) → false"
[ "$(unit 'echo bench > "$STATUS_DIR/$(status_key codex)"')" = false ]; chk $? "unit: a seat benched during the round (verdict file present) → false"
[ "$(unit 'BENCHED_LIST=" codex"')" = false ]; chk $? "unit: a seat benched before dispatch → false"
[ "$(unit 'NEW_SHA=ffffffffffffffffffffffffffffffffffffffff')" = false ]; chk $? "unit: head moved alone → false"
[ "$(unit 'NEW_SHA=')" = false ]; chk $? "unit: end SHA unreadable → false"
[ "$(unit 'HEAD_SHA=abc123; NEW_SHA=abc123')" = false ]; chk $? "unit: a head SHA that is not 40 hex → false"
[ "$(unit 'HEAD_SHA=; NEW_SHA=')" = false ]; chk $? "unit: no head SHA → false"
[ "$(unit 'CONFIG_REVIEWERS="claude,codex,grok,antigravity"')" = false ]; chk $? "unit: configured has a seat the run did not request → false"
[ "$(unit 'REQ_LIST=" claude codex grok"')" = false ]; chk $? "unit: requested has a seat that is not configured → false"
[ "$(unit 'CONFIG_REVIEWERS="claude,codex"; AUTHOR=')" = true ]; chk $? "unit: no author and the same two seats → true"
[ "$(unit 'echo findings > "$VERDICT_DIR/$(status_key codex)"')" = false ]; chk $? "unit: one seat findings alone → false"
[ "$(unit 'rm "$VERDICT_DIR/$(status_key codex)"')" = false ]; chk $? "unit: one seat with no verdict recorded → false"
[ "$(unit 'echo CLEAN > "$VERDICT_DIR/$(status_key codex)"')" = false ]; chk $? "unit: a verdict value outside clean/findings/unknown → false"
[ "$(unit 'REQ_LIST=""')" = false ]; chk $? "unit: nothing requested → false"
[ "$(unit 'AUTHOR=agy; CONFIG_REVIEWERS="claude,codex,antigravity"')" = true ]; chk $? "unit: an author still spelled agy is removed from a config that spells antigravity"
[ "$(unit 'REQ_LIST=" claude codex"; CONFIG_REVIEWERS="agy,claude,codex"; AUTHOR=antigravity')" = true ]; chk $? "unit: agy is the same seat as antigravity (the author) on the configured side"

# --- no stale file, no bad path ---------------------------------------------------------------
printf 'all_clean=true\n' > "$VF"
env PATH="$BIN:$PATH" bash "$RELAY" --pr 1 --verdict-file "$VF" --bogus-arg >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ] && [ ! -e "$VF" ]; chk $? "a run that fails on a later argument removes the previous round's file"
env PATH="$BIN:$PATH" bash "$RELAY" --pr 1 --verdict-file "$WORK/nodir/x.verdict" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ]; chk $? "a verdict path in a missing directory → exit 2"
env PATH="$BIN:$PATH" bash "$RELAY" --pr 1 --verdict-file "$WORK/v" >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ]; chk $? "a verdict path that is a directory → exit 2"
env PATH="$BIN:$PATH" bash "$RELAY" --pr 1 --verdict-file >/dev/null 2>&1; RC=$?
[ "$RC" = 2 ]; chk $? "--verdict-file with no value → exit 2"

# --- a clean round that cannot be recorded must not exit 0 -------------------------------------
mkdir -p "$WORK/ro"
vrun CHMOD_DIR="$WORK/v" -- --reviewers claude,codex
chmod 755 "$WORK/v"
[ "$RC" = 1 ] && [ ! -e "$VF" ]; chk $? "verdict file cannot be written on an otherwise clean run → exit 1, no file"

# --- the prompts carry the rules only when the flag is given ------------------------------------
PL="$WORK/prompt.log"; AL="$WORK/argv.log"; SL="$WORK/stdin.log"
rm -f "$PL" "$AL" "$SL"
PANEL=claude,codex,grok,opencode vrun PROMPT_FILE_LOG="$PL" ARGV_LOG="$AL" STDIN_LOG="$SL" -- --reviewers claude,codex,grok,opencode
[ "$RC" = 0 ] && [ "$(val all_clean)" = true ] && [ "$(val seat.grok)" = clean ] && [ "$(val seat.opencode)" = clean ] && [ "$(val ran)" = "claude codex grok opencode" ]; chk $? "four-seat round (claude, codex, grok, opencode): every seat's verdict is captured, all_clean=true"
PANEL=claude,codex,grok,opencode vrun OUT_grok='x\nVERDICT: findings blockers=0 should_fix=1' -- --reviewers claude,codex,grok,opencode
[ "$(val seat.grok)" = findings ] && [ "$(val all_clean)" = false ]; chk $? "four-seat round: a grok finding is seen through the --prompt-file seat"
PANEL=claude,codex,grok,opencode vrun OUT_opencode='x\nVERDICT: findings blockers=1 should_fix=0' -- --reviewers claude,codex,grok,opencode
[ "$(val seat.opencode)" = findings ] && [ "$(val all_clean)" = false ]; chk $? "four-seat round: an opencode finding is seen through the opencode seat"
rm -f "$PL" "$AL" "$SL"
PANEL=claude,codex,grok,opencode vrun PROMPT_FILE_LOG="$PL" ARGV_LOG="$AL" STDIN_LOG="$SL" -- --reviewers claude,codex,grok,opencode
grep -q 'VERDICT: clean' "$SL"; chk $? "claude/codex prompt (stdin) carries the verdict rules"
grep -q 'VERDICT: clean' "$PL"; chk $? "grok prompt file carries the verdict rules"
grep -q 'VERDICT: clean' "$AL"; chk $? "opencode prompt carries the verdict rules"
grep -q 'material problem of correctness, safety, deployability or verification' "$SL"; chk $? "the rules say what a Should-fix is, and that the rest are Nits"
rm -f "$PL" "$AL" "$SL" "$VF"
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA40" PR_RELAY_CONFIG="$WORK/cfg" \
  PROMPT_FILE_LOG="$PL" ARGV_LOG="$AL" STDIN_LOG="$SL" PR_RELAY_VERDICT_RULES="SMUGGLED" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex,grok,opencode >"$WORK/out" 2>"$WORK/err"; RC=$?
[ "$RC" = 0 ] && ! grep -q 'VERDICT' "$SL" "$PL" "$AL" && ! grep -q SMUGGLED "$SL" "$PL" "$AL"; chk $? "WITHOUT the flag: exit 0, no VERDICT text in any prompt, and an exported PR_RELAY_VERDICT_RULES is ignored"
[ ! -e "$VF" ]; chk $? "WITHOUT the flag: no verdict file is written"
# the same exit codes with and without the flag, on a failing round
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA40" PR_RELAY_CONFIG="$WORK/cfg" SLEEP_KEYS=codex PR_RELAY_AGENT_TIMEOUT=1 \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex >/dev/null 2>&1; RC0=$?
vrun SLEEP_KEYS=codex PR_RELAY_AGENT_TIMEOUT=1 -- --reviewers claude,codex
[ "$RC0" = "$RC" ] && [ "$RC" = 3 ]; chk $? "a failing round exits 3 with and without the flag"

# --- GOLDEN: without the flag every prompt a seat receives is byte-identical to the one before this change --
# capture_prompts <relay script> <out file>: a four-seat round with no flag; everything each seat was
# handed (claude/codex on stdin, grok in its prompt file, opencode in argv), temp paths normalised.
# Sequential, so the seats' order is fixed and nothing needs sorting (sorting would hide a reordering).
# test/golden/prompts-without-verdict-flag.txt was produced by running THIS function against the
# relay as it stood at origin/main 7f1f17d, before the flag existed. When a prompt is changed on
# purpose, regenerate it with UPDATE_GOLDEN=1 bash test/test-verdict.sh and review the diff.
capture_prompts() {
  local relay="$1" out="$2" d="$WORK/cap"
  rm -rf "$d" "$WORK/cache"; mkdir -p "$d" "$WORK/cache"
  printf 'REVIEWERS=claude,codex,grok,opencode\n' > "$WORK/cfg"
  env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA40" PR_RELAY_CONFIG="$WORK/cfg" \
      STDIN_LOG="$d/stdin" PROMPT_FILE_LOG="$d/pf" ARGV_LOG="$d/argv" \
    bash "$relay" --pr 1 --author antigravity --reviewers claude,codex,grok,opencode --sequential >"$d/out" 2>"$d/err"
  echo "relay-exit=$?" > "$out"
  for f in stdin pf argv; do
    { printf '##### %s\n' "$f"; sed -E "s#$WORK#<WORK>#g; s#/(tmp|var/folders)[^ ]*/(tmp\.|tmp)[A-Za-z0-9._]*#<TMP>#g; s#/tmp/[A-Za-z0-9._/-]*#<TMP>#g; s#(grok-prompt|iso-grok)\.[A-Za-z0-9]+#\1.<RAND>#g" "$d/$f" 2>/dev/null; } >> "$out"
  done
}
GOLD="$HERE/golden/prompts-without-verdict-flag.txt"
capture_prompts "${GOLDEN_RELAY:-$RELAY}" "$WORK/golden.now"
if [ -n "${UPDATE_GOLDEN:-}" ]; then mkdir -p "$HERE/golden"; cp "$WORK/golden.now" "$GOLD"; echo "  (golden regenerated: $GOLD)"; fi
[ -s "$GOLD" ] && cmp -s "$GOLD" "$WORK/golden.now"; chk $? "WITHOUT the flag: the exit code and every prompt every seat receives are byte-identical to the golden capture"
if [ -s "$GOLD" ] && ! cmp -s "$GOLD" "$WORK/golden.now"; then diff "$GOLD" "$WORK/golden.now" | head -20; fi

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
