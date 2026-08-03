#!/usr/bin/env bash
# Shared git isolation for this repo's test suites. Sourced, never copied.
#
# The suites here build throwaway git repos and, in one case, run a real git hook. They must operate
# on THOSE and nothing else, and their result must not depend on how the machine running them
# happens to have git configured. Two ways that went wrong, both observed on this repository:
#
#   1. INHERITED GIT ENVIRONMENT. git exports GIT_DIR (and friends) to its hooks, and those variables
#      OUTRANK the working directory: with GIT_DIR set, a fixture's `cd "$repo" && git init && git
#      commit` commits to the HOST repo and leaves the fixture empty. Run from the pre-push gate,
#      test-fail-closed.sh wrote junk commits onto the branch being pushed, renamed the branch, moved
#      HEAD, and rewrote user.name in the real repository — then failed ~16 assertions because its
#      fixtures had no content, which read convincingly as a defect in the code under test.
#      Reproduce the old behaviour with:
#          GIT_DIR=$(git rev-parse --absolute-git-dir) bash test/test-fail-closed.sh
#
#   2. INHERITED GIT CONFIG. With `commit.gpgsign = true` and an agent-backed signer (1Password's
#      op-ssh-sign here), every fixture commit is really signed. When the agent is locked the signer
#      returns nothing and the commits hang or fail, and the suite reports failures that have nothing
#      to do with the code.
#
# WHY A SOURCED LIBRARY AND NOT A COPIED BLOCK. Both suites need this, and a copy keeps passing after
# the original is deleted — which is the same "green for the wrong reason" failure the isolation
# itself exists to prevent. One implementation, one place to fix.
#
# WHY GIT_CONFIG_* AND NEVER `git config`. These settings are process-scoped and write nothing to
# disk. A `git config` line inside a fixture whose `git init` failed quietly writes into whatever
# repo the suite was launched from: that approach was tried here on 2026-08-02 and set user.name=t
# and turned commit signing off in this very repository.
#
# WHY NOT GIT_CONFIG_GLOBAL=/dev/null, the obvious one-liner: it discards the whole global config
# including safe.directory and init.defaultBranch, so on a CI runner that needs them it turns a
# signing bug into a stranger failure.
#
# WHY NOT init.templateDir="": tried in ship-feature and both redundant and harmful. Redundant
# because core.hooksPath below already beats anything a template drops in .git/hooks (measured);
# harmful because an empty template means `git init` creates no .git/info at all, so
# `>> .git/info/exclude` fails and any fixture that git-ignores a path breaks. It turned two passing
# tests red there, which is how it was found.
#
# core.attributesFile is deliberately NOT set, unlike ship-feature's version: nothing in these suites
# depends on attribute filters, and every key added is a key that has to be asserted or it rots.

# relay_isolate_git <work-dir> [--allow-hooks]
#
# --allow-hooks omits the core.hooksPath key. Needed by test-gate.sh, whose entire purpose is to run
# a real pre-push hook: env config OUTRANKS a repo's own `git config core.hooksPath`, so setting it
# here disabled the hook under test and every refusal case passed vacuously. (The gate suite caught
# this immediately, which is the point of having it.) Suites that pass this flag are pointing
# hooksPath at their own fixture anyway, so ambient hooks still cannot reach them.
#
# <work-dir> must already EXIST. core.hooksPath points at a child of it that does not exist, so hooks
# are simply never found. An earlier draft used "${WORK:-/nonexistent}/no-such-hooks" — but WORK is
# created AFTER this call in both suites, so that expansion always took the fallback, and
# /nonexistent is a path anyone could create.
relay_isolate_git() {
  local work="${1:?relay_isolate_git needs the work dir}" allow_hooks=0
  [ "${2:-}" = "--allow-hooks" ] && allow_hooks=1
  [ -d "$work" ] || { echo "relay_isolate_git: '$work' does not exist" >&2; exit 2; }

  # The list comes from git, not from memory: git's own answer cannot go stale, and the hand-written
  # version this replaces named 8 of the 15 entries git actually reports — missing GIT_CONFIG,
  # GIT_CONFIG_PARAMETERS, GIT_IMPLICIT_WORK_TREE, GIT_GRAFT_FILE, GIT_NO_REPLACE_OBJECTS,
  # GIT_REPLACE_REF_BASE and GIT_SHALLOW_FILE.
  #
  # Captured into a variable first, rather than read from a process substitution: a `git rev-parse`
  # that fails inside `< <(...)` does not fail the surrounding `while`, so the loop would quietly
  # become a no-op while the exports below proceeded — a half-applied isolation reporting green,
  # which is the exact shape this exists to remove.
  local _vars _v
  _vars="$(git rev-parse --local-env-vars)" || {
    echo "relay_isolate_git: cannot list git's local env vars — refusing to run unisolated" >&2; exit 2; }
  [ -n "$_vars" ] || {
    echo "relay_isolate_git: git listed no local env vars — refusing to run unisolated" >&2; exit 2; }
  while IFS= read -r _v; do [ -n "$_v" ] && unset "$_v"; done <<< "$_vars"

  # Identity: NOT on git's local-env list, so the clearing above does not touch it — but fixture
  # commits would otherwise depend on the developer's own user.name/user.email, or fail outright
  # where neither is set.
  # git's local-env list names GIT_CONFIG_COUNT but NOT the GIT_CONFIG_KEY_n / GIT_CONFIG_VALUE_n
  # pairs, so a hostile environment could leave stale pairs above our COUNT untouched. Harmless while
  # our COUNT is the higher number, but "harmless today" is how the rest of this file's bugs started.
  local _i
  for _i in $(seq 0 31); do unset "GIT_CONFIG_KEY_$_i" "GIT_CONFIG_VALUE_$_i"; done

  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
  export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

  # ORDER MATTERS. GIT_CONFIG_COUNT is itself on git's local-env list, so the clearing has to happen
  # BEFORE these are set or it erases them. And GIT_CONFIG_PARAMETERS — which git sets for child
  # processes whenever anything up the tree ran `git -c …`, i.e. exactly how an ambient override
  # reaches a suite launched from a hook — OVERRIDES GIT_CONFIG_COUNT. Measured: with both present,
  # an ambient commit.gpgsign=true wins and the isolation silently does nothing.
  export GIT_CONFIG_KEY_0=commit.gpgsign    GIT_CONFIG_VALUE_0=false
  export GIT_CONFIG_KEY_1=tag.gpgsign       GIT_CONFIG_VALUE_1=false
  export GIT_CONFIG_KEY_2=core.excludesFile GIT_CONFIG_VALUE_2=/dev/null
  export GIT_CONFIG_KEY_3=core.fsmonitor    GIT_CONFIG_VALUE_3=false
  export GIT_CONFIG_KEY_4=color.ui          GIT_CONFIG_VALUE_4=false
  if [ "$allow_hooks" = 1 ]; then
    export GIT_CONFIG_COUNT=5
  else
    export GIT_CONFIG_COUNT=6
    export GIT_CONFIG_KEY_5=core.hooksPath  GIT_CONFIG_VALUE_5="$work/no-such-hooks"
  fi
}

# relay_require_git_2_31
#
# GIT_CONFIG_COUNT arrived in git 2.31. On anything older the clearing above still runs but none of
# the controlled values take effect, so the isolation is HALF applied while the suite reports green —
# the fail-open this whole file exists to remove. Refuse instead.
#
# The probe requires the VALUE back, not merely that the lookup succeeded: checking only the exit
# status means an ambient config that happens to define the probe key satisfies it on an old git.
# That was a real finding in ship-feature's review.
relay_require_git_2_31() {
  # The probe must run with git's ambient environment ALREADY cleared. Two ways it was wrong:
  #   * an inherited GIT_CONFIG_PARAMETERS overrides GIT_CONFIG_COUNT, so the probe read the ambient
  #     value and the suite refused to run on git 2.51 claiming it needed 2.31 — measured with
  #     `GIT_CONFIG_PARAMETERS="'relay.probe=x'" bash test/test-gate.sh`, and it would fire exactly
  #     when run from a hook, which is the case this whole file is about;
  #   * on a git OLDER than 2.31, GIT_CONFIG_COUNT is ignored entirely, so an ambient
  #     `relay.probe = <expected>` in someone's ~/.gitconfig would satisfy it and the suite would run
  #     half-isolated. The expected value is therefore generated per run, so no config can hold it.
  local probe expected _vars _v
  expected="relay-isolation-$$-${RANDOM}"
  _vars="$(git rev-parse --local-env-vars 2>/dev/null)" || _vars=""
  probe="$(
    while IFS= read -r _v; do [ -n "$_v" ] && unset "$_v"; done <<< "$_vars"
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=relay.probe GIT_CONFIG_VALUE_0="$expected" \
      git config --get relay.probe 2>/dev/null
  )"
  [ "$probe" = "$expected" ] || {
    echo "these tests need git 2.31+ (GIT_CONFIG_COUNT) to isolate their fixtures; found $(git --version)" >&2
    exit 2; }
}
