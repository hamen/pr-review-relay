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
WORK="$(mktemp -d)"
BIN="$WORK/bin"; mkdir -p "$BIN"
trap 'rm -rf "$WORK"' EXIT

# --- stub: gh ----------------------------------------------------------------
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
args="$*"
case "$1 $2" in
  "pr view")
    if printf '%s\n' "$@" | grep -q headRefOid; then
      if [ -n "${GH_SHA_DRIFT:-}" ]; then
        c=$(cat "$GH_SHA_COUNTER" 2>/dev/null || echo 0); c=$((c+1)); echo "$c" > "$GH_SHA_COUNTER"
        [ "$c" -le 1 ] && echo "aaaaaaa1111111111111111111111111111111111" || echo "bbbbbbb2222222222222222222222222222222222"
      else
        echo "aaaaaaa1111111111111111111111111111111111"
      fi
    elif printf '%s\n' "$@" | grep -q url; then echo "http://example.test/pr/1"
    elif printf '%s\n' "$@" | grep -q number; then echo 1
    fi ;;
  "repo view") echo "owner/repo" ;;
  "pr diff")   echo "diff --git a/x b/x"; echo "+change" ;;
  "pr comment") exit 0 ;;
  *) case "$1" in api) echo "" ;; *) echo "" ;; esac ;;
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
case ",\${FAIL_EMPTY:-}," in *",\$key,"*) exit 0;; esac      # empty output, rc 0 → "no review"
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

# explicitly requested reviewer that has no tool mapping → fail (not silent skip)
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache"; rm -f "$WORK/sha_counter"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,bogus --parallel >/dev/null 2>&1
rc=$?
if [ "$rc" = 3 ]; then echo "  ok   [3] explicitly requested unknown reviewer → fail"; PASS=$((PASS+1)); else echo "  FAIL [got $rc, want 3] unknown reviewer"; FAIL=$((FAIL+1)); fi

# cap: pre-seed the round file at the cap, then a normal run must exit 4
rm -rf "$WORK/cache"; mkdir -p "$WORK/cache/pr-review-relay"
printf '3' > "$WORK/cache/pr-review-relay/owner_repo#1.round"
env PATH="$BIN:$PATH" XDG_CACHE_HOME="$WORK/cache" GH_SHA_COUNTER="$WORK/sha_counter" \
  bash "$RELAY" --pr 1 --author antigravity --reviewers claude,codex --parallel >/dev/null 2>&1
rc=$?
if [ "$rc" = 4 ]; then echo "  ok   [4] round cap reached → exit 4"; PASS=$((PASS+1)); else echo "  FAIL [got $rc, want 4] round cap"; FAIL=$((FAIL+1)); fi

echo "-------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
