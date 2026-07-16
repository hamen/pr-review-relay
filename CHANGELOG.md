# Changelog

All notable changes to **pr-review-relay** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
