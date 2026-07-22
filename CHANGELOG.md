# Changelog

All notable changes to **pr-review-relay** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **Reviewers read the changed files from the local checkout instead of fetching them via `gh`.** The
  authoring agent almost always runs the relay from the PR's own worktree — the code is already on disk.
  When the current checkout provably IS the PR head **and** is clean, the relay now tells reviewers to
  read the changed files straight from disk rather than run `gh` themselves. That removes the read-side
  network round-trips — the big win for **agentic** reviewers, which otherwise spend one LLM call per
  `gh` fetch (the main cause of slow-model timeouts). The diff itself still comes from `gh pr diff`, so
  it stays authoritative (matches GitHub, correct for fork PRs, never fooled by a stale/rebased local
  base) — it's a single cheap subprocess, not an agent tool call. It falls back to telling reviewers to
  fetch via `gh` whenever the checkout isn't the PR head, is dirty, or the relay is run from outside the
  repo, so a reviewer never reads files that differ from the PR. The local `HEAD` and clean state are
  re-checked at the end of the round, so a mid-round commit or edit invalidates the reviews the same way
  a remote push does. `gh` still POSTS the reviews (the consensus trail on the PR).

### Fixed

- **Symlinked installs aborted with `missing lib-opencode.sh`.** `SCRIPT_DIR` was taken from
  `${BASH_SOURCE[0]}` + `pwd -P`, which resolves a symlinked *directory* but not a symlinked *script
  file* — so `~/.local/bin/pr-review-relay -> <repo>` looked for its siblings in `~/.local/bin`, where
  they aren't. It now walks the script's own symlink chain first (via an absolute-path `readlink`, never
  through `PATH`, preserving the bootstrap's security goal), handling absolute, relative, and
  bare-filename link targets, bounded against a cycle, and **failing closed** with a clear error if it
  can't resolve (rather than sourcing a lib next to the link). The same bootstrap is applied to all four
  sibling-locating entry points — `pr-review-relay`, `review-local`, `pr-review-consensus`,
  `pr-review-collapse-comments` — so none of them break under a symlinked install.

- **The `opencode` reviewer never ran** — because the binary was never found. OpenCode installs to
  `~/.opencode/bin/opencode`, which is not on `PATH`, so `command -v opencode` missed and the reviewer
  was skipped before it could be dispatched at all. It is now resolved from the stock path.
- **And when it did run, it ran with auto-approval.** The invocation used
  `--dangerously-skip-permissions`. That flag is absent from `opencode run --help`, but it is *not*
  rejected: the 1.18.3 binary accepts it as an undocumented alias for `--auto`
  (`args.auto || args.yolo || args["dangerously-skip-permissions"]`). So the reviewer was configured to
  auto-approve every permission it was asked for — on a machine where `command -v opencode` did
  succeed, it would have reviewed untrusted diffs with edit and shell rights. That is the behaviour the
  read-only work below exists to remove.
- **OpenCode is now resolved from the stock install path.** `PATH` first, then
  `~/.opencode/bin/opencode`, overridable with `PR_RELAY_OPENCODE_BIN`. Resolution happens once at
  startup so it feeds both the availability check and the invocation.
- **`review-local` had the same two faults** (nonexistent flag, bare `opencode` name) and is fixed
  alongside — otherwise the companion command would stay broken while the docs claimed otherwise.
- **`HOME` unset no longer aborts the relay.** The startup binary resolution referenced a bare
  `$HOME`; under `set -u` that dies with `HOME: unbound variable` in cron, systemd units and minimal
  containers — and because resolution runs before any dispatch, it took down *every* reviewer, not
  just opencode. Now `${HOME:-}`, with a regression test.

### Changed

- **OpenCode runs read-only, enforced by a default-deny permission policy.**
  `opencode --pure run` with an agent the relay defines itself, plus `OPENCODE_CONFIG_CONTENT` (a runtime override that outranks
  the user's own `opencode.json`) set to `"*": "deny"` with **no allowlist at all**, repeated on a primary
  agent the relay defines for itself. The reviewer needs no tools: the diff arrives as prompt content
  via `-f`, not through a tool call, so the review is unchanged with everything denied — and reads
  were the last way a prompt-injected diff could have quoted a secret into a posted comment. `--pure` keeps external plugins — which execute
  at startup regardless of permissions — from loading. Since shell is denied, the reviewer can't fetch
  the PR itself, so the diff is attached as a file (`-f`) in both modes and at any size.

  Seven weaker designs were tried and discarded, each confirmed broken against a live opencode:
  - The original `--dangerously-skip-permissions` — an undocumented alias for `--auto`, so it
    approved everything rather than erroring.
  - Selecting the built-in `plan` agent — its permissions stay user-configurable; asked to run
    `id`, it ran it and returned real uid/gid.
  - A `gh pr view*` / `gh pr diff*` bash allowlist so link mode could still fetch — defeated by shell
    redirection: `gh pr view N > victim` matches the allowed prefix and overwrote the file despite
    `edit` and `write` both denied. Prefix matching cannot make a shell command read-only.
  - Global deny without repeating it on the selected agent — OpenCode applies agent-scoped permissions
    after the global ones, so a user's `agent.<name>.permission.bash: allow` reinstated shell.
  - Selecting a BUILT-IN agent at all. An agent's mode is user-configurable:
    `agent.plan.mode: "subagent"` makes OpenCode fall back to `build` and apply *that* agent's
    permissions — verified, shell came back. The relay defines and selects its own primary agent.
  - Denying tools by name — anything not named (custom tools, MCP servers) stays allowed by default.
  - Running elsewhere while still reading project config — see the MCP-at-startup entry below.

  Deliberately not `--auto`, which auto-approves every `ask` permission. `review-local` gets the same
  policy, the same file attachment, and its own argv-contract tests.
- **Project config loading is disabled for the OpenCode reviewer** via
  `OPENCODE_DISABLE_PROJECT_CONFIG=1`. The config loader walks *up* from its working directory to the
  worktree root looking for `opencode.json`, so choosing a different directory alone is not a
  guarantee — a `TMPDIR` inside the repository, for instance, would put the reviewer back under it.
  This env var is the supported switch that stops the search outright; verified to block a planted
  `mcp` entry even with the config sitting in the working directory. Kept *in addition to* running
  outside the repo, because every single-layer defence in this area has turned out to be bypassable.
- **The OpenCode reviewer runs outside the repository.** OpenCode reads the project `opencode.json`
  from its working directory and merges it under the inline override; an `mcp` server declared there
  is launched at startup, *before* tool permissions apply. A pull request that adds an `opencode.json`
  therefore achieves arbitrary command execution simply by being reviewed — verified with a planted
  MCP entry, whose command ran with `"*": "deny"` and `--pure` both in force. Neither the permission
  policy nor `--pure` (which covers plugins only) prevents it, and an `"mcp": {}` override does not
  either, because project config is deep-merged rather than replaced. The reviewer is now launched
  from the attachment directory, so the repo's config is never read. Consequence: this reviewer sees
  the attached diff only and does not browse the checkout.
- **Prompt attachments are cleaned up on interruption.** The attached diff lives in a mode-700 temp dir
  removed by the script's `EXIT` trap, which does fire on `SIGTERM`; a per-function `RETURN` trap does
  not, and would have left the full PR diff in `/tmp`. It is deliberately kept out of the status
  directory, whose contents are tallied as reviewer outcomes.
- **The round-state fallback is per-user.** With neither `XDG_CACHE_HOME` nor `HOME` set, state now goes
  to a mode-700 `${TMPDIR:-/tmp}/pr-review-relay-$(id -u)` instead of a shared, predictable path another
  user could pre-create or symlink.

### Added

- **`qwen` reviewer (Qwen Code CLI).** A sixth supported reviewer, opt-in like `opencode`: name it in
  `--reviewers` (e.g. `--reviewers claude,qwen`). It runs headless via `qwen --safe-mode --approval-mode
  yolo -p` in both `pr-review-relay` and `review-local`, and posts collapsed with a 🟡 marker.
  `--safe-mode` disables any hooks / extensions / skills / MCP / project config that a reviewed PR might
  carry in its checkout, so they can't execute during review; `--approval-mode yolo` (not `plan`) keeps
  `gh` available so link-mode reviewers can still fetch the PR. Auth is the CLI's own — the free Qwen
  OAuth tier or a paid Qwen Cloud / DashScope OpenAI-compatible endpoint configured in `~/.qwen/.env`.
  Not in the default reviewer set, so existing runs are unaffected. Covered by an argv-contract test that
  fails if either enforced flag is dropped.
- `PR_RELAY_OPENCODE_MODEL` — optional model pin for the opencode reviewer. **Unset by default**, so
  opencode uses your own configured model; pinning one here would hard-fail anyone without that
  provider authenticated, and free tiers may log the submitted diff.
- `PR_RELAY_OPENCODE_BIN` — optional override for a non-standard OpenCode install.
- Tests asserting the opencode **argv contract** (rejects the legacy flag and `--auto`, requires
  the relay's own agent, `-m` present only when the env var is set) and both binary-resolution branches.
  These fail against the pre-fix script.

## [1.1.0] — 2026-07-16

### Changed

- **Fail-closed exit codes.** `✔ Relay done.` used to print and the script exited `0` even if every
  reviewer timed out or returned empty — a caller couldn't tell *"all reviewed"* from *"everything
  broke"*. The outcome is now carried by the exit code:
  - `0` — every reviewer that ran produced **and posted** a review, and the PR head didn't move.
  - `3` — a reviewer returned empty / whitespace-only / timed out / exited non-zero / failed to post,
    **or** an explicitly-requested reviewer was missing, **or** no reviewer ran, **or** the head SHA
    couldn't be read before/after, **or** HEAD moved mid-round.
  - `4` — review-round cap reached (was `0`).
- Per-reviewer outcomes are tracked on disk so they survive subshells under `--parallel`, and each
  launched reviewer is pre-seeded `pending` so a hard-killed process counts as a failure, not a silent
  exclusion.
- The round cap is consumed only when at least one reviewer was actually dispatched (`would_run > 0`), so
  a misconfigured machine where nobody runs can't march to the cap without ever getting a review. A round
  that dispatched reviewers but failed still consumes a slot (a flaky reviewer must hit the cap).
- The success banner reports skipped default reviewers and marks the run a **partial cross-review** when
  any were skipped.

### Fixed

- **macOS Bash 3.2 compatibility.** Removed `declare -A` (associative array) and `${name^}` (case
  modification), both Bash 4+, which threw errors on the default `/bin/bash` 3.2 shipped with macOS.
- Reviewer names are sanitized before use as status filenames (`status_key`, `k_` prefix) — no path
  traversal, and never a dotfile that the tally glob would silently skip. Duplicate reviewer names are
  deduplicated (they would otherwise share one status file and race under `--parallel`).
- SHA binding is fail-closed: both the before and after `headRefOid` reads must succeed, and the reviewed
  SHA is recorded in each posted comment's footer.
- The comment wrapper's exit status is checked before posting; `wrap-collapsed-pr-comment.mjs` only skips
  wrapping in `--auto` mode, so a review that merely mentions `<details>` keeps its summary + SHA footer.
- `--dry-run` is a real preflight: it fails on an invalid `--reviewers` config or zero runnable reviewers.
- `--max-rounds` is validated as a non-negative integer; round-file mtime reads work on macOS too
  (`stat -c %Y || stat -f %m`).

### Added

- `test/test-fail-closed.sh` — stubs `gh` and the agent CLIs and asserts every exit-code path (25 cases).
- A GitHub Actions workflow that syntax-checks and runs the suite on push / PR.

## [1.0.0] — 2026-07-15

First tagged release.

- **Five reviewers**: 🟣 Claude, 🟢 Codex, 🔵 Cursor, 🟠 Antigravity, and ⚪ OpenCode (opt-in).
- **Link mode (default)**: each reviewer fetches the whole PR itself (`gh pr view` / `gh pr diff`) and
  reads the changed files in context — not just a diff snapshot. A size-capped inline diff is embedded as
  a fallback so a sandboxed reviewer never returns empty.
- **`review-local`**: run the same cross-review on your current branch before opening a PR — no `gh`, no
  PR number, nothing posted; reviews print straight to your terminal.
- **No more silent skips**: when a reviewer produces nothing you get a human-readable reason (empty /
  timed out / not found / not executable) plus the tail of its stderr.
- **Collapsed comments + consensus**: each review posts as a forum-style `<details>` block, and
  `pr-review-consensus` synthesizes a single work card into the PR description.
- **`--context-file`**: prepend a doc / spec / API reference so every reviewer verifies the PR against it.
- **Bounded loop**: a per-PR round cap keeps read→fix→re-run from spiraling; re-runs are idempotent.

[1.1.0]: https://github.com/hamen/pr-review-relay/releases/tag/v1.1.0
[1.0.0]: https://github.com/hamen/pr-review-relay/releases/tag/v1.0.0
