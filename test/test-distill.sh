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
  [ -n "${DISTILL_NO_PRS:-}" ] && exit 0   # simulate an empty repo
  printf '1\n2\n'; exit 0
fi
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
  echo "Some PR title"; exit 0
fi
if [ "$1" = "api" ]; then
  case "$*" in
    *reviews*) echo "[review/alice] Please add a test for this change.";;
    *pulls/*/comments*) echo "[inline/bob src/x.rb] Use snake_case here.";;
    *issues/*/comments*) echo "[comment/carol] Add a test for this change too.";;
  esac
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/gh"

# --- stub: claude (the default agent) ----------------------------------------
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
# ignore -p and the prompt; emit a canned proposal
echo "## Proposed rules from PR review feedback"
echo ""
echo "### Testing"
echo "- **Ship a test with every change.** Reviewers keep asking. (from #1, #2)"
STUB
chmod +x "$BIN/claude"

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
rc=$(run)
if [ "$rc" = 0 ] && grep -q 'Proposed rules from PR review feedback' "$WORK/out"; then
  ok "propose path returns the agent's proposal"
else
  bad "propose path (rc=$rc)"; cat "$WORK/out" "$WORK/err" >&2
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

echo
echo "distill tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
