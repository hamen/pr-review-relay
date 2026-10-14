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
# pi: both pi seats run this ONE binary, so the key comes from --model (zai/* → pi_glm,
# xai/* → pi_grok), and OUT_<key> is OUT_pi_glm, never OUT_pi. pi speaks a json stream, so the text
# (OUT_<key> expanded with %b, as the stubs above do) is JSON-encoded by node and written by node:
# printf '%b' on the encoded line would expand its \n and \" escapes and break it.
cat > "$BIN/pi" <<'PI'
#!/usr/bin/env bash
model=""; prev=""
for a in "$@"; do [ "$prev" = --model ] && model="$a"; prev="$a"; done
case "$model" in zai/*) key=pi_glm;; xai/*) key=pi_grok;; *) key=pi;; esac
if [ -n "${STDIN_LOG:-}" ]; then { printf '=== %s stdin ===\n' "$key"; cat; printf '\n'; } >> "$STDIN_LOG"; else cat > /dev/null; fi
var="OUT_$key"
if [ -n "${!var:-}" ]; then text="$(printf '%b' "${!var}")"; else text="$(printf 'Looks good.\nVERDICT: clean')"; fi
node -e 'process.stdout.write(JSON.stringify({ type: "message_end", message: { role: "assistant", stopReason: "stop", content: [{ type: "text", text: process.argv[1] }] } }) + "\n")' "$text"
PI
chmod +x "$BIN/pi"
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
# `round` is the relay's round counter for the PR: it advances whenever the head SHA changes, a return to an
# earlier SHA included, and does not advance on a re-run of the same SHA
rr() { env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/rcache" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$1" PR_RELAY_CONFIG="$WORK/cfg" \
         bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --verdict-file "$VF" >/dev/null 2>&1; val round; }
printf 'REVIEWERS=claude,codex\n' > "$WORK/cfg"; rm -rf "$WORK/rcache"; mkdir -p "$WORK/rcache"
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
r1=$(rr $SHA_A); r2=$(rr $SHA_B); r3=$(rr $SHA_B); r4=$(rr $SHA_A)
[ "$r1" = 1 ] && [ "$r2" = 2 ] && [ "$r3" = 2 ] && [ "$r4" = 3 ]; chk $? "round: 1 on the first SHA, 2 on a new SHA, still 2 on a re-run of it, 3 on a return to the first SHA — any head change is a new round (got $r1,$r2,$r3,$r4)"
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
# head_sha binds the record to what the seats were shown: the head at the START of the round. This is
# the only case in which start and end differ, so it is the only one that can tell them apart.
[ "$(val head_sha)" = aaaaaaa1111111111111111111111111111111111 ]; chk $? "head moved: head_sha is the start-of-round SHA, not the end one (got $(val head_sha))"
vrun -- --reviewers claude,codex --max-rounds 0
[ "$RC" = 4 ] && [ "$(val exit)" = 4 ] && [ "$(val all_clean)" = false ]; chk $? "round cap (exit 4) → file written, all_clean=false"
vrun -- --reviewers claude,codex --no-post
[ "$RC" = 0 ] && [ "$(val all_clean)" = false ]; chk $? "--no-post: nothing is on the PR → all_clean=false"
vrun -- --reviewers claude,codex --dry-run
[ "$RC" = 0 ] && [ "$(val all_clean)" = false ] && [ "$(val exit)" = 0 ]; chk $? "--dry-run → all_clean=false, exit=0 recorded (a deliberate exit 0)"
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
unit() { # <setup commands run in the world before verdict_write> [field, default all_clean] ; prints that field
  (
    set -u
    . "$LIB"
    D="$(mktemp -d)"; STATUS_DIR="$D/s"; VERDICT_DIR="$D/v"; mkdir -p "$STATUS_DIR" "$VERDICT_DIR"
    VERDICT_FILE="$D/out.verdict"; VERDICT_PARENT="$D"; AUTHOR=antigravity; CONFIG_REVIEWERS="claude,codex,antigravity"
    REQ_LIST=" claude codex"; BENCHED_LIST=""; REPO=o/r; PR=1; NEXT_ROUND=1; DRY=0; NO_POST=0
    HEAD_SHA="$SHA40"; NEW_SHA="$SHA40"; RELAY_EXIT_OK=1
    for s in claude codex; do k="$(status_key "$s")"; echo ok > "$STATUS_DIR/$k"; echo clean > "$VERDICT_DIR/$k"; done
    rc=0
    eval "$1"
    verdict_write "$rc" || echo "write-failed"
    sed -n "s/^${2:-all_clean}=//p" "$VERDICT_FILE"
    rm -rf "$D"
  )
}
[ "$(unit 'true')" = true ]; chk $? "unit: the baseline world is all_clean=true"
[ "$(unit 'rc=3')" = false ]; chk $? "unit: exit 3 alone → false"
[ "$(unit 'RELAY_EXIT_OK=0')" = false ] && [ "$(unit 'RELAY_EXIT_OK=0' exit)" = killed ]; chk $? "unit: status 0 without a deliberate exit 0 (a signal) alone → false, exit=killed"
[ "$(unit 'rc=143')" = false ] && [ "$(unit 'rc=143' exit)" = killed ]; chk $? "unit: a status of 128 or more (a signal) → false, exit=killed"
[ "$(unit 'rc=3' exit)" = 3 ] && [ "$(unit 'true' exit)" = 0 ]; chk $? "unit: a deliberate status is recorded as itself (3, and 0 with the marker)"
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
rm -f "$PL" "$AL" "$SL"
PANEL=claude,codex,pi_glm vrun STDIN_LOG="$SL" -- --reviewers claude,codex,pi_glm
[ "$RC" = 0 ] && [ "$(val seat.pi_glm)" = clean ] && sed -n '/^=== pi_glm stdin ===$/,$p' "$SL" | grep -q 'VERDICT: clean'
chk $? "pi_glm prompt (stdin) carries the verdict rules, and its clean verdict is captured"
PANEL=claude,codex,pi_glm vrun OUT_pi_glm='x\nVERDICT: findings blockers=1 should_fix=0' -- --reviewers claude,codex,pi_glm
[ "$(val seat.pi_glm)" = findings ] && [ "$(val all_clean)" = false ]; chk $? "a pi_glm finding is seen through the json stream (OUT_pi_glm, keyed by --model)"
PANEL=claude,codex,pi_glm vrun OUT_pi_glm='He wrote "C:\\tmp" and left.\nVERDICT: findings blockers=1 should_fix=0' -- --reviewers claude,codex,pi_glm
[ "$(val seat.pi_glm)" = findings ]; chk $? "a pi review with a quote, a backslash and a newline still parses (one JSON line)"
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
# capture_prompts <relay script> <out file>: a four-seat round with no flag; the exit code, the relay's
# stdout and stderr, and everything each seat was handed (claude/codex on stdin, grok in its prompt
# file, opencode in argv), with temp paths and the run log's random suffix normalised. It runs from a
# directory that is not a git checkout, because the relay names the checkout and its HEAD in its
# output, and with every per-seat environment override cleared, so the developer's shell cannot
# change a model or an effort under it.
# Sequential, so the seats' order is fixed and nothing needs sorting (sorting would hide a reordering).
# test/golden/prompts-without-verdict-flag.txt was produced by running THIS function against the
# relay as it stood at origin/main 7f1f17d, before the flag existed. When a prompt is changed on
# purpose, regenerate it with UPDATE_GOLDEN=1 bash test/test-verdict.sh and review the diff.
capture_prompts() {
  local relay="$1" out="$2" d="$WORK/cap"
  rm -rf "$d" "$WORK/cache"; mkdir -p "$d" "$WORK/cache" "$WORK/nonrepo"
  printf 'REVIEWERS=claude,codex,grok,opencode\n' > "$WORK/cfg"
  ( cd "$WORK/nonrepo" && env -u AGY_REVIEW_MODEL -u AGY_MODEL_ARGS -u CLAUDE_REVIEW_EFFORT -u CLAUDE_REVIEW_FALLBACK_MODEL \
      -u CLAUDE_REVIEW_MODEL -u CLAUDE_MODEL_ARGS -u CODEX_REVIEW_EFFORT -u CODEX_REVIEW_MODEL -u CODEX_MODEL_ARGS \
      -u CURSOR_REVIEW_MODEL -u GROK_REVIEW_EFFORT -u GROK_REVIEW_MODEL -u OPENCODE_BIN -u PR_RELAY_AGENT_TIMEOUT \
      -u PR_RELAY_ARGV_MAX_BYTES -u PR_RELAY_LOG_MAX_BYTES -u PR_RELAY_MAX_ROUNDS -u PR_RELAY_MAX_SAME_SHA \
      -u PR_RELAY_OPENCODE_ALLOW_IN_REPO -u PR_RELAY_OPENCODE_BIN -u PR_RELAY_OPENCODE_MODEL -u PR_RELAY_REVIEWERS \
      -u PR_RELAY_VERDICT_RULES \
      PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA40" PR_RELAY_CONFIG="$WORK/cfg" \
      STDIN_LOG="$d/stdin" PROMPT_FILE_LOG="$d/pf" ARGV_LOG="$d/argv" \
    bash "$relay" --pr 1 --author antigravity --reviewers claude,codex,grok,opencode --sequential >"$d/out" 2>"$d/err" )
  echo "relay-exit=$?" > "$out"
  for f in out err stdin pf argv; do
    { printf '##### %s\n' "$f"; sed -E "s#$WORK#<WORK>#g; s#/(tmp|var/folders)[^ ]*/(tmp\.|tmp)[A-Za-z0-9._]*#<TMP>#g; s#/tmp/[A-Za-z0-9._/-]*#<TMP>#g; s#(grok-prompt|iso-grok|\.run)\.[A-Za-z0-9]+#\1.<RAND>#g" "$d/$f" 2>/dev/null; } >> "$out"
  done
}
GOLD="$HERE/golden/prompts-without-verdict-flag.txt"
capture_prompts "${GOLDEN_RELAY:-$RELAY}" "$WORK/golden.now"
if [ -n "${UPDATE_GOLDEN:-}" ]; then mkdir -p "$HERE/golden"; cp "$WORK/golden.now" "$GOLD"; echo "  (golden regenerated: $GOLD)"; fi
[ -s "$GOLD" ] && cmp -s "$GOLD" "$WORK/golden.now"; chk $? "WITHOUT the flag: the exit code, stdout, stderr and every prompt every seat receives are byte-identical to the golden capture"
grep -q '^##### out$' "$GOLD" && grep -q '^##### err$' "$GOLD" && grep -q 'Relay done' "$GOLD"; chk $? "the golden capture really holds the relay's stdout and stderr sections"
if [ -s "$GOLD" ] && ! cmp -s "$GOLD" "$WORK/golden.now"; then diff "$GOLD" "$WORK/golden.now" | head -20; fi

# --- reviewers spelled differently / delivered differently (closing-round review, opencode) ----------
# agy as a REVIEWER, not the author: pass 1 records the seat as antigravity, so the configured side must too.
PANEL=claude,agy AUTHOR_ARG=codex vrun -- --reviewers claude,agy
[ "$RC" = 0 ] && [ "$(val requested)" = "antigravity claude" ] && [ "$(val ran)" = "antigravity claude" ] && [ "$(val seat.antigravity)" = clean ] && [ "$(val all_clean)" = true ]; chk $? "agy as a reviewer (not the author), named in the config and in --reviewers → antigravity seat is captured, all_clean=true"
PANEL=claude,antigravity AUTHOR_ARG=codex vrun -- --reviewers claude,agy
[ "$(val all_clean)" = true ]; chk $? "config says antigravity, --reviewers says agy → same seat, all_clean=true"
# cursor reads the prompt on stdin, antigravity in argv: neither goes through the grok or opencode prompt builders.
rm -f "$SL" "$AL"
PANEL=cursor,antigravity AUTHOR_ARG=claude vrun STDIN_LOG="$SL" ARGV_LOG="$AL" -- --reviewers cursor,antigravity
[ "$(val all_clean)" = true ]; chk $? "cursor and antigravity seats: verdicts captured, all_clean=true"
grep -q 'VERDICT: clean' "$SL"; chk $? "cursor prompt (stdin) carries the verdict rules"
grep -q 'VERDICT: clean' "$AL"; chk $? "antigravity prompt (argv) carries the verdict rules"

# --- no external command runs before the PATH guard (round-4 review, codex) ------------------------
# The guard refuses a PATH entry inside the checkout so that nothing the branch under review ships can
# run as a command. --verdict-file is parsed before that guard; it once called `dirname` and `rm` there.
# Plant both in a PATH entry inside a checkout: the run must refuse (exit 2) and neither may ever run.
PG="$WORK/pathguard"; mkdir -p "$PG"
( cd "$PG" && git init -q . ) >/dev/null 2>&1
for c in dirname rm; do printf '#!/usr/bin/env bash\n: > "%s/planted-%s-ran"\nexit 0\n' "$WORK" "$c" > "$PG/$c"; chmod +x "$PG/$c"; done
rm -f "$WORK/planted-dirname-ran" "$WORK/planted-rm-ran"
printf 'all_clean=true\n' > "$VF"
( cd "$PG" && env PATH="$PG:$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" PR_RELAY_CONFIG="$WORK/cfg" \
    bash "$RELAY" --pr 1 --author antigravity --verdict-file "$VF" >/dev/null 2>"$WORK/pg.err" ); RC=$?
[ -e "$PG/.git" ] && [ "$RC" = 2 ] && grep -q 'inside the repository' "$WORK/pg.err"; chk $? "a PATH entry inside the checkout with --verdict-file → the guard refuses the run (exit 2)"
[ ! -e "$WORK/planted-dirname-ran" ] && [ ! -e "$WORK/planted-rm-ran" ]; chk $? "a planted dirname and rm in that PATH entry never ran"
rm -f "$VF"

# --- a relay killed mid-round leaves no all_clean=true behind (round-4 review, opencode) -------------
# SIGKILL skips every handler: the file must simply not be there (the old one went when the flag was
# read). SIGTERM runs the exit handler: whatever it writes must say all_clean=false. Both are sent while
# the stub sits inside `gh pr diff`, after the handler is installed. Own process group, bounded wait.
if ( set -m ) 2>/dev/null; then
  for sig in KILL TERM; do
    printf 'all_clean=true\n' > "$VF"; rm -f "$WORK/hangmark" "$WORK/sha_counter"
    rm -rf "$WORK/cache" "$WORK/ktmp"; mkdir -p "$WORK/cache" "$WORK/ktmp"
    printf 'REVIEWERS=claude,codex\n' > "$WORK/cfg"
    ( set -m
      env PATH="$BIN:$PATH" TMPDIR="$WORK/ktmp" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA40" \
          PR_RELAY_CONFIG="$WORK/cfg" GH_DIFF_HANG=1 GH_HANG_MARK="$WORK/hangmark" \
        bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --verdict-file "$VF" >/dev/null 2>&1 &
      _kid=$!
      _pgid=$(ps -o pgid= -p "$_kid" 2>/dev/null | tr -d ' ')
      _w=0; while [ "$_w" -lt 200 ] && [ ! -e "$WORK/hangmark" ]; do sleep 0.1; _w=$((_w+1)); done
      if [ "$sig" = TERM ]; then
        # TERM the relay alone and WAIT for it, so its handler finishes before anything else is killed;
        # the group KILL below only reaps the stub left hanging in `gh pr diff`.
        kill -TERM "$_kid" 2>/dev/null
        wait "$_kid" 2>/dev/null; echo "$?" > "$WORK/kstatus"
      fi
      kill -9 -"$_pgid" 2>/dev/null || kill -9 "$_kid" 2>/dev/null
      wait "$_kid" 2>/dev/null || true
    )
    [ -e "$WORK/hangmark" ]; chk $? "SIG$sig: the relay was inside \`gh pr diff\` when it was killed"
    if [ "$sig" = KILL ]; then
      [ ! -e "$VF" ]; chk $? "SIGKILL mid-round → no file at the path (the previous round's file is gone)"
    else
      [ -e "$VF" ] && [ "$(val all_clean)" = false ] && [ "$(val exit)" = killed ] && [ "$(count all_clean)" = 1 ]; chk $? "SIGTERM mid-round → the handler writes all_clean=false, exit=killed (got: ${VF##*/} $( [ -e "$VF" ] && echo "all_clean=$(val all_clean) exit=$(val exit)" || echo missing))"
      [ "$(cat "$WORK/kstatus" 2>/dev/null)" = 143 ]; chk $? "SIGTERM mid-round → the process still dies of the signal (status 143, got $(cat "$WORK/kstatus" 2>/dev/null))"
    fi
  done
else
  echo "  skip (no job control in this shell: cannot kill a process group)"
fi

# --- the cleanup trap is armed as soon as STATUS_DIR exists (round-6 review, grok) -------------------
# A kill in the gap between creating STATUS_DIR and setting the trap cannot be timed reliably, so the
# test uses the one failure inside that gap that CAN be forced: the next `mktemp -d` (VERDICT_DIR). That
# path has no cleanup of its own, so if the trap were set any later, STATUS_DIR would stay in TMPDIR.
REAL_MKTEMP="$(command -v mktemp)"
MB="$WORK/mktemp-bin"; mkdir -p "$MB"
cat > "$MB/mktemp" <<MK
#!/usr/bin/env bash
case " \$* " in *" -d "*)
  n=\$(( \$(cat "$WORK/mk.count" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$WORK/mk.count"
  [ "\$n" = 2 ] && exit 1;;
esac
exec "$REAL_MKTEMP" "\$@"
MK
chmod +x "$MB/mktemp"
rm -rf "$WORK/ttmp" "$WORK/cache"; mkdir -p "$WORK/ttmp" "$WORK/cache"; rm -f "$WORK/mk.count" "$WORK/sha_counter" "$VF"
printf 'REVIEWERS=claude,codex\n' > "$WORK/cfg"
env PATH="$MB:$BIN:$PATH" TMPDIR="$WORK/ttmp" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" GH_FIXED_SHA="$SHA40" \
    PR_RELAY_CONFIG="$WORK/cfg" bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --verdict-file "$VF" >/dev/null 2>"$WORK/mk.err"; RC=$?
[ "$RC" = 1 ] && grep -q 'cannot create temp dir for verdicts' "$WORK/mk.err" && [ "$(cat "$WORK/mk.count" 2>/dev/null)" = 2 ]; chk $? "the mktemp -d right after STATUS_DIR (VERDICT_DIR) fails → exit 1 (rc=$RC)"
[ -z "$(ls -A "$WORK/ttmp" 2>/dev/null)" ]; chk $? "the trap, set right after STATUS_DIR, removed it: nothing left in TMPDIR ($(ls -A "$WORK/ttmp" 2>/dev/null | tr '\n' ' '))"
[ "$(val all_clean)" = false ] && [ "$(val exit)" = 1 ]; chk $? "that exit still leaves a record: exit=1, all_clean=false"

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
