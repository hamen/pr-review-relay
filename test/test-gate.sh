#!/usr/bin/env bash
# Tests for the push gate itself — .githooks/pre-push and its contract with bin/ci.
#
# This repo has no CI, so that hook is the only thing between a change and `main`. Before this file
# existed the hook was verified by hand once, against a throwaway remote, and that verification
# could not catch a later regression. Everything here was a manual check first; this is those checks
# written down.
#
# Everything runs against a bare remote in a temp directory. NOTHING here touches a real repository
# or a real remote: running a gate experiment against a live repo is how a sibling repo got seven
# junk commits and two pushes to GitHub on 2026-08-02.
#
# bin/ci is STUBBED. The point is the hook's decisions — which pushes it allows and refuses — not
# the suites, which have their own files and take minutes. A stub also lets a red gate, a gate that
# rewrites tracked files and a gate that moves HEAD be simulated, none of which the real one does.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../.githooks/pre-push"
[ -r "$HOOK" ] || { echo "cannot read $HOOK" >&2; exit 1; }

WORK="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 1; }
# The developer's own ~/.config/pr-review-relay/config must not reach these fixtures. It sets the
# real panel and real models, so a machine with one configured would fail assertions that pin a
# model or a reviewer list — and the pre-push gate would go red for a reason that has nothing to do
# with the change being pushed. Point every suite at a path that does not exist; the cases that
# WANT a config set PR_RELAY_CONFIG themselves, per invocation.
export PR_RELAY_CONFIG="$WORK/no-such-panel-config"

[ -n "$WORK" ] && [ -d "$WORK" ] || { echo "no temp dir" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# Git isolation: shared with test-fail-closed.sh so the two cannot drift. It matters here more than
# anywhere — this file builds git repos AND runs a real git hook, which is precisely the shape that
# writes into the host repository when git's repo-local environment leaks in.
# shellcheck source=lib-hermetic.sh
. "$HERE/lib-hermetic.sh"
relay_require_git_2_31
# --allow-hooks: this suite RUNS a hook, and env config outranks a repo's own core.hooksPath, so the
# default neutralisation would disable the thing under test and make every refusal case pass for
# nothing. Each fixture points hooksPath at its own copy, so ambient hooks still cannot reach us.
relay_isolate_git "$WORK" --allow-hooks

PASS=0; FAIL=0
ok()   { echo "  ok   [-] $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# Rebuild a pristine repo+remote for each case, so one case cannot leave state for the next.
# <ci-body> is the stub bin/ci; default is a gate that passes and touches nothing.
setup() { # setup [ci-body]
  rm -rf "$WORK/remote.git" "$WORK/w"
  git init -q --bare "$WORK/remote.git"
  git clone -q "$WORK/remote.git" "$WORK/w" 2>/dev/null
  mkdir -p "$WORK/w/bin" "$WORK/w/.githooks"
  cp "$HOOK" "$WORK/w/.githooks/pre-push"; chmod +x "$WORK/w/.githooks/pre-push"
  printf '%s\n' "#!/usr/bin/env bash" "${1:-true}" > "$WORK/w/bin/ci"; chmod +x "$WORK/w/bin/ci"
  ( cd "$WORK/w" && git config core.hooksPath .githooks \
    && echo base > file.txt && git add -A && git commit -qm base )
}
push() { ( cd "$WORK/w" && git push "$@" 2>&1 ); }

# The isolation above is load-bearing here too, and until now nothing in this file checked it: the
# lines could be deleted and every case would still pass on a clean machine — the failure mode this
# whole change is about. A plant, and the guard that the shared library actually ran.
( cd "$WORK" || exit 1
  export GIT_DIR="$WORK/nope/.git" GIT_CONFIG_PARAMETERS="'commit.gpgsign=true'"
  relay_isolate_git "$WORK" --allow-hooks
  [ -z "${GIT_DIR:-}" ] || { echo GIT_DIR_SET; exit 3; }
  [ -z "${GIT_CONFIG_PARAMETERS:-}" ] || { echo PARAMS_SET; exit 4; }
  [ "$(git config --get commit.gpgsign 2>/dev/null)" = "false" ] || { echo SIGNING_ON; exit 5; }
  echo OK ) > "$WORK/iso.out" 2>/dev/null
[ "$(tail -1 "$WORK/iso.out" 2>/dev/null)" = "OK" ] \
  && ok "the shared git isolation is in force here too" \
  || bad "git isolation not applied ($(tail -1 "$WORK/iso.out" 2>/dev/null))"

echo "push gate tests:"

# 1. The happy path. If this fails nothing else below means anything.
setup
out=$(push origin HEAD:main); rc=$?
[ "$rc" = 0 ] && ok "a clean push of HEAD is allowed" || bad "clean push refused (rc=$rc): $(tail -1 <<< "$out")"

# 2. The hole the previous hook had: the gate tests the working tree, so it can only vouch for HEAD.
#    `git push origin HEAD~1:refs/heads/x` used to pass while shipping a commit nobody tested.
setup
( cd "$WORK/w" && git commit -q --allow-empty -m second )
out=$(push origin HEAD~1:refs/heads/other); rc=$?
{ [ "$rc" != 0 ] && grep -q "not your checked-out HEAD" <<< "$out"; } \
  && ok "a non-HEAD commit is refused, with the reason" \
  || bad "non-HEAD push not refused (rc=$rc): $(tail -1 <<< "$out")"

# 2b. `git push --all` is the case the hook's own comment names and the one most likely to be typed
#     by accident: several refs at once, only one of which is HEAD. The refusal must cover the WHOLE
#     push, not just the offending ref — git offers no way to accept part of it, and a hook that let
#     the good ref through would still be shipping the untested one.
setup
push origin HEAD:main >/dev/null 2>&1
( cd "$WORK/w" && git branch stale HEAD && git commit -q --allow-empty -m ahead )
out=$(push --all origin); rc=$?
{ [ "$rc" != 0 ] && grep -q "not your checked-out HEAD" <<< "$out"; } \
  && ok "a --all push containing a non-HEAD ref is refused entirely" \
  || bad "--all with a mixed ref set not refused (rc=$rc): $(tail -1 <<< "$out")"

# 3. A delete-only push carries no code, so the gate has nothing to vouch for. Blocking it on an
#    unrelated dirty tree would be a gate blocking work it has no opinion on, which is how gates get
#    routed around.
setup
push origin HEAD:refs/heads/doomed >/dev/null 2>&1
( cd "$WORK/w" && echo dirt >> file.txt )      # dirty on purpose: must not matter here
out=$(push origin :refs/heads/doomed); rc=$?
[ "$rc" = 0 ] && ok "a delete-only push is allowed even with a dirty tree" \
              || bad "delete-only push refused (rc=$rc): $(tail -1 <<< "$out")"

# 4. An annotated tag pushes the TAG OBJECT's id, not the commit's. A naive comparison against HEAD
#    rejects `git push origin v1.2.3` even when the tag points straight at the tested commit, which
#    would block every release. The hook peels with ^{commit}.
setup
push origin HEAD:main >/dev/null 2>&1
( cd "$WORK/w" && git tag -a v0.0.1 -m t )
out=$(push origin refs/tags/v0.0.1); rc=$?
[ "$rc" = 0 ] && ok "an annotated tag pointing at HEAD is allowed" \
              || bad "annotated tag refused (rc=$rc): $(tail -1 <<< "$out")"

# 5/6. The gate tests the working tree, so a dirty tree means it vouched for something other than
#      what is being pushed. Untracked files count: a stray fixture changes what bin/ci does.
setup
( cd "$WORK/w" && echo dirt >> file.txt )
out=$(push origin HEAD:main); rc=$?
{ [ "$rc" != 0 ] && grep -q "uncommitted changes" <<< "$out"; } \
  && ok "a dirty working tree is refused" || bad "dirty tree not refused (rc=$rc)"

setup
( cd "$WORK/w" && : > stray.tmp )
out=$(push origin HEAD:main); rc=$?
{ [ "$rc" != 0 ] && grep -q "untracked files present" <<< "$out"; } \
  && ok "an untracked file is refused" || bad "untracked file not refused (rc=$rc)"

# 7. A red gate must block the push. This is the whole point of the hook.
setup 'exit 1'
out=$(push origin HEAD:main); rc=$?
[ "$rc" != 0 ] && ok "a failing bin/ci blocks the push" || bad "red gate did not block the push"

# 8. A gate that rewrites tracked files passed against a tree that is not what gets pushed — the
#    check at the top of the hook, arriving through the back door. Lockfiles do this.
setup 'echo rewritten > file.txt'
out=$(push origin HEAD:main); rc=$?
{ [ "$rc" != 0 ] && grep -q "MODIFIED tracked files" <<< "$out"; } \
  && ok "a gate that rewrites tracked files blocks the push" || bad "tree rewrite not caught (rc=$rc)"

# 9. Same for a gate that creates untracked files: a later step may have consumed one, so the run
#    proves nothing about a clean checkout.
setup ': > generated.tmp'
out=$(push origin HEAD:main); rc=$?
{ [ "$rc" != 0 ] && grep -q "CREATED untracked files" <<< "$out"; } \
  && ok "a gate that creates untracked files blocks the push" || bad "generated file not caught (rc=$rc)"

# 10. And a gate that moves HEAD: every other check would pass while the original untested commit is
#     what actually goes to the server.
setup 'git commit -q --allow-empty -m "gate moved head"'
out=$(push origin HEAD:main); rc=$?
{ [ "$rc" != 0 ] && grep -q "MOVED HEAD" <<< "$out"; } \
  && ok "a gate that moves HEAD blocks the push" || bad "moved HEAD not caught (rc=$rc)"

# 11. A non-executable bin/ci must be reported as such, not silently skipped — a hook that cannot
#     run the gate and pushes anyway is worse than no hook.
setup
# The mode change has to be COMMITTED: git tracks the executable bit, so a bare `chmod -x` leaves a
# dirty tree and the hook refuses for that reason first — which passed the test for the wrong
# reason until the assertion checked the message rather than just the exit code.
chmod -x "$WORK/w/bin/ci"
( cd "$WORK/w" && git add -A && git commit -qm "drop the executable bit" )
out=$(push origin HEAD:main); rc=$?
{ [ "$rc" != 0 ] && grep -q "not executable" <<< "$out"; } \
  && ok "a non-executable bin/ci refuses the push" || bad "non-executable bin/ci not caught (rc=$rc)"

# 12. The hook scrubs git's repo-local environment before running the gate, so a tool the gate calls
#     gets answers about ITSELF and not about the repo being pushed. This is the second, independent
#     fix for the failure that made the old hook corrupt the repo it ran in.
setup 'test -z "${GIT_DIR:-}${GIT_INDEX_FILE:-}" || { echo "LEAKED:${GIT_DIR:-}" >&2; exit 1; }'
out=$(push origin HEAD:main); rc=$?
[ "$rc" = 0 ] && ok "git's repo-local environment is scrubbed before bin/ci runs" \
              || bad "git env leaked into bin/ci (rc=$rc): $(grep LEAKED <<< "$out" | head -1)"

echo "-------------------------------------------"
echo "gate tests: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
