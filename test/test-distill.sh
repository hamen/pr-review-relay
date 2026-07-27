#!/usr/bin/env bash
# Tests for pr-review-distill. Stubs `gh` and the agent CLI on PATH; no network,
# no real agents. Asserts arg validation, --dry-run (no agent call), the corpus
# gather, and the propose path. Run: bash test/test-distill.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DISTILL="$HERE/../pr-review-distill"
WORK="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "no temp dir" >&2; exit 1; }
BIN="$WORK/bin"; mkdir -p "$BIN"
trap 'rm -rf "$WORK"' EXIT

# --- stub: gh ----------------------------------------------------------------
# Answers only what the script asks; every `gh api` returns one jq'd line so the
# corpus is non-empty. A flag file lets one test simulate "no PRs".
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
  "repo view") echo "acme/widgets"; exit 0;;
esac
if [ "$1" = "pr" ] && [ "$2" = "list" ]; then
  [ -n "${DISTILL_LIST_FAIL:-}" ] && exit 1  # simulate auth/network failure
  [ -n "${DISTILL_NO_PRS:-}" ] && exit 0     # simulate an empty repo
  printf '1\n2\n'; exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo "Some PR title"; exit 0
fi
if [ "$1" = "api" ]; then
  case "$*" in
    *reviews*) [ -n "${DISTILL_API_FAIL:-}" ] && exit 1; echo "[review/alice] Please add a test for this change.";;
    *pulls/*/comments*) echo "[inline/bob src/x.rb] Use snake_case here.";;
    *issues/*/comments*) echo "[comment/carol] Add a test for this change too.";;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/gh"

# --- stub: claude (the default agent) ----------------------------------------
# Records the flags it was called with (so we can assert enforced read-only mode) and
# honours CLAUDE_RC to simulate a non-zero exit with output.
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
[ -n "${CLAUDE_ARGS_FILE:-}" ] && printf '%s\n' "$*" > "$CLAUDE_ARGS_FILE"
echo "## Proposed rules from PR review feedback"
echo ""
echo "### Testing"
echo "- **Ship a test with every change.** Reviewers keep asking. (from #1, #2)"
exit "${CLAUDE_RC:-0}"
STUB
chmod +x "$BIN/claude"

# --- stubs: codex + cursor (record args to assert enforced read-only flags) ---
cat > "$BIN/codex" <<'STUB'
#!/usr/bin/env bash
[ -n "${CODEX_ARGS_FILE:-}" ] && printf '%s\n' "$*" > "$CODEX_ARGS_FILE"
echo "## Proposed rules from PR review feedback"
echo "- **A codex rule.** (from #1)"
STUB
chmod +x "$BIN/codex"

cat > "$BIN/cursor-agent" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURSOR_ARGS_FILE:-}" ] && printf '%s\n' "$*" > "$CURSOR_ARGS_FILE"
echo "## Proposed rules from PR review feedback"
echo "- **A cursor rule.** (from #1)"
STUB
chmod +x "$BIN/cursor-agent"

export PATH="$BIN:$PATH"
cd "$WORK"

pass=0; fail=0
ok()   { pass=$((pass+1)); echo "  ✓ $1"; }
bad()  { fail=$((fail+1)); echo "  ✗ $1" >&2; }

run() { "$DISTILL" "$@" >"$WORK/out" 2>"$WORK/err"; echo $?; }

echo "test: bad argument → exit 2"
[ "$(run --bogus)" = 2 ] && ok "unknown arg exits 2" || bad "unknown arg"

echo "test: invalid --agent → exit 2"
[ "$(run --agent gpt)" = 2 ] && ok "invalid agent exits 2" || bad "invalid agent"

echo "test: --agent antigravity is unsupported → exit 2"
[ "$(run --agent antigravity)" = 2 ] && ok "antigravity rejected (untrusted-input safety)" || bad "antigravity should be rejected"

echo "test: value option with no argument → clean exit 2 (not set -u crash)"
[ "$(run --repo)" = 2 ] && ok "--repo without value exits 2" || bad "--repo missing value"

echo "test: invalid --limit → exit 2"
[ "$(run --limit 0)" = 2 ] && ok "invalid limit exits 2" || bad "invalid limit"

echo "test: --dry-run lists PRs, exits 0, does NOT call the agent"
rc=$(run --dry-run)
if [ "$rc" = 0 ] && grep -q '#1' "$WORK/out" && ! grep -q 'Proposed rules' "$WORK/out"; then
  ok "dry-run lists PRs without proposing"
else
  bad "dry-run (rc=$rc)"; cat "$WORK/out" "$WORK/err" >&2
fi

echo "test: --print-comments emits the gathered corpus"
rc=$(run --print-comments)
if [ "$rc" = 0 ] && grep -q 'PR #1' "$WORK/out" && grep -q 'snake_case' "$WORK/out"; then
  ok "print-comments shows corpus"
else
  bad "print-comments (rc=$rc)"; cat "$WORK/out" "$WORK/err" >&2
fi

echo "test: full run asks the agent and prints the proposal → exit 0"
rc=$(CLAUDE_ARGS_FILE="$WORK/cargs" "$DISTILL" >"$WORK/out" 2>"$WORK/err"; echo $?)
if [ "$rc" = 0 ] && grep -q 'Proposed rules from PR review feedback' "$WORK/out"; then
  ok "propose path returns the agent's proposal"
else
  bad "propose path (rc=$rc)"; cat "$WORK/out" "$WORK/err" >&2
fi

echo "test: claude is invoked in ENFORCED read-only (--permission-mode plan)"
if grep -q -- '--permission-mode plan' "$WORK/cargs" 2>/dev/null; then
  ok "claude pinned to plan mode (injection-safe default)"
else
  bad "claude not run with --permission-mode plan"; cat "$WORK/cargs" 2>/dev/null >&2
fi

echo "test: codex is invoked with the read-only sandbox (-s read-only)"
rc=$(CODEX_ARGS_FILE="$WORK/xargs" "$DISTILL" --agent codex >"$WORK/out" 2>"$WORK/err"; echo $?)
if [ "$rc" = 0 ] && grep -q -- '-s read-only' "$WORK/xargs" 2>/dev/null; then
  ok "codex pinned to read-only sandbox"
else
  bad "codex read-only (rc=$rc)"; cat "$WORK/xargs" 2>/dev/null "$WORK/err" >&2
fi

echo "test: cursor is invoked in ask (read-only) mode (--mode=ask)"
rc=$(CURSOR_ARGS_FILE="$WORK/uargs" "$DISTILL" --agent cursor >"$WORK/out" 2>"$WORK/err"; echo $?)
if [ "$rc" = 0 ] && grep -q -- '--mode=ask' "$WORK/uargs" 2>/dev/null; then
  ok "cursor pinned to ask mode"
else
  bad "cursor ask mode (rc=$rc)"; cat "$WORK/uargs" 2>/dev/null "$WORK/err" >&2
fi

echo "test: agent non-zero exit with output still fails → exit 1 (no truncated proposal)"
rc=$(CLAUDE_RC=42 "$DISTILL" >"$WORK/out" 2>"$WORK/err"; echo $?)
if [ "$rc" = 1 ] && ! grep -q '========== proposed rules' "$WORK/out"; then
  ok "rc!=0 fails closed even with output"
else
  bad "rc!=0 handling (rc=$rc)"; cat "$WORK/out" "$WORK/err" >&2
fi

echo "test: --out writes the proposal to a file"
rc=$(run --out "$WORK/proposal.md")
if [ "$rc" = 0 ] && [ -f "$WORK/proposal.md" ] && grep -q 'Proposed rules' "$WORK/proposal.md"; then
  ok "--out writes the file"
else
  bad "--out (rc=$rc)"
fi

echo "test: no PRs in repo → exit 1"
rc=$(DISTILL_NO_PRS=1 "$DISTILL" >"$WORK/out" 2>"$WORK/err"; echo $?)
[ "$rc" = 1 ] && ok "no PRs exits 1" || { bad "no PRs (rc=$rc)"; cat "$WORK/err" >&2; }

echo "test: an unwritable --out fails loudly → exit 1"
rc=$(run --out "$WORK/nope/deep/proposal.md")
[ "$rc" = 1 ] && grep -q 'could not write' "$WORK/err" && ok "--out write failure exits 1" || { bad "--out failure (rc=$rc)"; cat "$WORK/err" >&2; }

echo "test: gh pr list failure is distinct from empty → exit 1 with a clear message"
rc=$(DISTILL_LIST_FAIL=1 "$DISTILL" >"$WORK/out" 2>"$WORK/err"; echo $?)
if [ "$rc" = 1 ] && grep -q 'could not list PRs' "$WORK/err"; then
  ok "list failure distinguished from no-PRs"
else
  bad "list failure (rc=$rc)"; cat "$WORK/err" >&2
fi

echo "test: --repo (explicit) does NOT borrow the current dir's rules file"
: > "$WORK/AGENTS.md"   # a rules file in cwd that must be ignored for another repo
rc=$(run --repo other/project)
if [ "$rc" = 0 ] && grep -q 'pass --rules-file' "$WORK/out" && ! grep -q 'rules file: AGENTS.md' "$WORK/out"; then
  ok "explicit --repo skips cwd rules auto-detection"
else
  bad "explicit --repo rules handling (rc=$rc)"; cat "$WORK/out" >&2
fi
rm -f "$WORK/AGENTS.md"

echo "test: a failed GitHub API call is reported as INCOMPLETE (not hidden)"
rc=$(DISTILL_API_FAIL=1 "$DISTILL" >"$WORK/out" 2>"$WORK/err"; echo $?)
if [ "$rc" = 0 ] && grep -q 'INCOMPLETE CORPUS' "$WORK/err"; then
  ok "partial fetch surfaces an INCOMPLETE warning"
else
  bad "incomplete-corpus warning (rc=$rc)"; cat "$WORK/err" >&2
fi

echo
echo "distill tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
