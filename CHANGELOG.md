# Changelog

All notable changes to **pr-review-relay** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **The `opencode` reviewer never ran.** It was invoked as
  `opencode run --dangerously-skip-permissions`, a flag no shipped OpenCode version has (`opencode run
  --help` on 1.18.3 offers `--auto`). Combined with the binary living at `~/.opencode/bin/opencode` —
  off `PATH`, so `command -v` missed and the reviewer was skipped before the flag mattered — the
  feature was silently dead: a dispatched run would return an empty review, which the fail-closed
  relay reports as `exit 3`.
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

- **OpenCode runs read-only, enforced by an inline permission deny-list.** `opencode run --agent plan`
  plus `OPENCODE_CONFIG_CONTENT` (a runtime override that outranks the user's own `opencode.json`)
  denying `bash`, `edit`, `write`, `patch`, `task`, `webfetch`, `websearch` and `external_directory`,
  mirrored under `agent.plan`. Since shell is denied, the reviewer can't fetch the PR itself, so the
  diff is attached as a file (`-f`) in both modes and at any size.

  Three weaker designs were tried and discarded, each confirmed broken against a live opencode:
  - `--agent plan` with no config — the Plan agent's permissions stay user-configurable; asked to run
    `id`, it ran it and returned real uid/gid.
  - A `gh pr view*` / `gh pr diff*` bash allowlist so link mode could still fetch — defeated by shell
    redirection: `gh pr view N > victim` matches the allowed prefix and overwrote the file despite
    `edit` and `write` both denied.
  - Global deny without the `agent.plan` mirror — OpenCode applies agent-scoped permissions after the
    global ones, so a user's `agent.plan.permission.bash: allow` reinstated shell.

  Deliberately not `--auto`, which auto-approves every `ask` permission. `review-local` gets the same
  config and the same file attachment.

### Added

- `PR_RELAY_OPENCODE_MODEL` — optional model pin for the opencode reviewer. **Unset by default**, so
  opencode uses your own configured model; pinning one here would hard-fail anyone without that
  provider authenticated, and free tiers may log the submitted diff.
- `PR_RELAY_OPENCODE_BIN` — optional override for a non-standard OpenCode install.
- Tests asserting the opencode **argv contract** (rejects the legacy flag and `--auto`, requires
  `--agent plan`, `-m` present only when the env var is set) and both binary-resolution branches.
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
