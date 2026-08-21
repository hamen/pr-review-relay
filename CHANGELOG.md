# Changelog

All notable changes to **pr-review-relay** are documented here. This project follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.6.0] — 2026-08-21

### Fixed

- **The relay took its repository from `gh repo view`, which answers with the PARENT inside a fork —
  and ignores `GH_REPO`, unlike `gh pr view`.** `$REPO` is what the posting path deletes comments
  through and what the review prompt names, so a `--post` round launched from a fork of
  `android/snippets` would have deleted and written comments upstream, on a stranger's pull request,
  while every banner on screen named the fork. It surfaced on a read-only run: the banner said the
  fork and the run log beside it said the parent. The repository is now read off the URL that
  `gh pr view` resolved — one source of truth, whatever gh was aimed at is what gets written to — and
  a URL that cannot be reduced to `owner/name` **refuses** instead of falling back to the command
  this change exists to stop trusting.
- **The write named no repository at all.** `gh pr comment N` resolves the number against the parent
  inside a fork, so the deletes above it went to our repository and the comment went to theirs. It
  passes `--repo` now, and one `export GH_REPO` pins the SHA reads, the diff, and the agents that
  inherit the environment to the same repository the round was resolved against.
- **`--pr <url>` reached the API as a URL.** `$PR` is pasted into `repos/owner/name/issues/$PR/comments`,
  where a URL builds `issues/https://.../comments` and fails silently behind the delete pass's
  `|| true` — so the previous review was never removed and every round left another copy on the pull
  request. The number is taken from the URL, and a URL carrying no number refuses.
- **Enterprise hosts resolved to github.com.** `$REPO` is `owner/name` with no host in it, so
  `gh api repos/$REPO/...` went wherever gh defaults — for a GHE checkout, a same-named repository on
  github.com that we do not own. The host comes off the pull request URL now, with credentials
  stripped (`user:pass@host` is not a hostname) and the port kept. `github.com` is deliberately left
  as gh's default rather than exported, since gh reads `GH_HOST` as an Enterprise host.
- **A repository named `pull`.** `${REPO%%/pull/*}` removes the longest suffix, so
  `owner/pull/pull/34` reduced to `owner` and the pull request was rejected.

### Changed

- **The per-reviewer timeout defaults to 500s, up from 300s.** (Merged before the fixes above and
  unreleased until now, so it ships here.) The panel runs reasoning models at
  high effort now; 300 was tuned when it did not, and an ordinary plan review no longer fits inside
  it — one session lost three consecutive `grok45high` attempts to the clock on a plan whose only
  fault was being thorough. A timeout is not silent (exit `3`, and the round refuses to count), but
  it spends the gate's budget without exercising the gate, and a round that returns no findings
  reads the same on the page as a clean one. `AGENT_TIMEOUT` in `~/.config/pr-review-relay/config`
  remains the single place to override it — for this tool and for `ship-feature plan-review`, which
  reads the same file.

## [1.5.0] — 2026-08-04

### Added

- **An agent that is out of quota is benched instead of failing every round for days.** A
  quota-exhausted reviewer used to fail on every repo until its quota reset — and because a failed
  reviewer makes the round not clean, the verdict was worthless even when every other review had
  arrived. The first run that sees the quota error now records the agent with an expiry parsed from
  its own message ("Resets in 56h55m40s"), and later runs drop it until then. It expires by itself,
  so nothing has to be remembered or undone.

  **This changes a documented contract.** `--reviewers` normally makes a missing reviewer a hard
  failure; a benched one is now the single exception, because `ship-feature` always passes
  `--reviewers` and without the carve-out the bench would be inert. A named reviewer is dropped
  **only** when out of quota, **only** until the time it reported, and **never silently**: it is
  announced every round and the verdict reads `PARTIAL cross-review`. An empty panel is still
  exit `3`, a timeout still fails the round, and a bench that cannot be persisted converts that
  round's discoveries to failures rather than exiting clean with nothing recorded.

  The bench is global and time-based, so **`--reset` does not clear it** — `--reset` forgets one
  PR's round counter. To force a reviewer back early, delete its line from
  `$XDG_CACHE_HOME/pr-review-relay/benched`.

- **Every run leaves evidence, so an interrupted round is no longer a black hole.** Relay runs do get
  killed mid-round; every investigation of *why* has ended outside this script, so this makes the
  next one survivable and diagnosable rather than pretending to prevent it.
  - A timestamped **run log** per invocation under the state directory, plus **one sidecar per
    reviewer**. The path is printed at **startup**, not just in the closing banner — a killed run
    never reaches the banner, and that is precisely the run you want the log for.
  - Each reviewer's stdout now **streams into its sidecar as the CLI produces it**, instead of being
    buffered whole in a command substitution. A kill mid-reviewer used to lose everything that
    reviewer had written; now the partial text is on disk. Best-effort: many CLIs block-buffer when
    stdout is not a TTY (`stdbuf` is used when present, never required).
  - One writer per file — the parent writes only the run log, each reviewer only its own sidecar —
    so nothing interleaves under `--parallel` and no locking is needed. Names are unique per
    invocation, so a retry after a kill cannot overwrite the evidence of the attempt that died.
  - Every terminal path logs its verdict, including the failure paths (HEAD moved, dirty checkout,
    reviewer failed). A log that only recorded successes would go quiet exactly when it matters.
  - `PR_RELAY_LOG_MAX_BYTES` (default 256 KiB) bounds a reviewer's captured output **on the write
    path**, and its captured stderr, so a runaway agent cannot fill the disk. A truncated review is
    marked as such and makes the round **not clean** (exit `3`): the findings that did not fit are
    indistinguishable from findings that do not exist, and `0` claims every reviewer produced and
    posted a review. The text is still posted, as it already is for a reviewer that exits non-zero
    with output.
  - The run log is created **before** the cap checks, so an `exit 4` run — the one where you most
    want to know what the counters said — leaves evidence too.

### Fixed

- **The git isolation could quietly stop isolating on a machine without `seq`.** The stale
  `GIT_CONFIG_KEY_n` cleanup in `test/lib-hermetic.sh` was `for _i in $(seq 0 31)`. These suites do
  not run under `set -e`, so where `seq` is absent the substitution expands to nothing, the loop body
  never runs, the stale pairs survive — **and every test still passes**, because nothing asserted the
  cleanup had happened. A silent no-op in the code whose only job is isolation. It is now
  `for ((_i = 0; _i <= 31; _i++))`, bash arithmetic, which cannot be missing from `PATH`.

  Covered by a new hermeticity check that plants the failure rather than describing it: `seq` is
  **shadowed by a stub that exits 127**, reproducing the exact failure mode (`$(seq 0 31)` expands to
  nothing) while the rest of `PATH` stays intact, plus a stale pair above the COUNT the library
  installs. The control asserts both that the stub is what `seq` resolves to and that it really
  yields nothing, so a machine where the plant did not take cannot pass vacuously. With the old loop
  restored it reports `STALE_PAIR_SURVIVED`.

  Found by a reviewer that had been given the change's **plan** as well as its diff — the first
  cross-review run in that shape.

- **The isolation's own CHANGELOG entry had the wrong counts.** It claimed "Seven checks" and "six of
  the seven fail" for a suite that already had **eight**, of which **seven** fail with the clearing
  removed — the `--allow-hooks` check is the one that does not depend on it. Corrected to what that
  release actually shipped; the check added here makes the suite **nine**, and that belongs to this
  entry rather than being back-dated into the previous one. Re-measured, not re-estimated. Numbers in
  a changelog are load-bearing — they are what a future reader uses to tell whether a check went
  missing.

- **Runs that never wrote state left log families nobody ever collected.** The 6h reset needs a
  `.round` file to look at, and state is written only when a run actually dispatches someone — so a
  dry run, a run that resolves no reviewer, or one killed before the pre-dispatch write left its log
  and sidecars sitting in the state directory (holding review text) until somebody happened to pass
  `--reset` for that exact key. The README said "6h or `--reset`" with no such exception. Those
  leftovers now expire on the same 6h clock, **by family** — the log's mtime decides and its
  sidecars go with it, so a transcript is never separated from its log. The sweep runs only when
  there is no `.round` file, so a live session keeps its first round's log however old it gets; the
  README now spells out the three limits that rule implies.

- **A hang or a kill in `gh pr view` or `gh pr diff` left no evidence at all.** Both ran before the
  run log existed, which is the exact class of incident the evidence trail was added for. The state
  directory and the log are now opened as soon as the PR number and repository are known — before
  the head-SHA read and before the diff. It cannot be earlier than that (the file name derives from
  the repository, which itself comes from `gh`), and the README says so rather than promising more.
  Two early exits that now sit under an open log — an empty diff and a missing context file — record
  their verdict instead of ending the log mid-sentence.

- **The test suite corrupted the repository it was run from, whenever it was run from a git hook.**
  git exports `GIT_DIR` to its hooks, and that variable outranks the working directory: with it
  set, a fixture's `cd "$repo" && git init && git commit` commits to the **host** repo and leaves
  the fixture empty. Run from the `pre-push` gate, the suite therefore wrote junk commits
  (`base`/`change`/`i`/`c`) and stray files onto the branch being pushed, and then failed ~16
  assertions because its fixture repos had no content — failures that read convincingly as a defect
  in `review-local` rather than in the harness. **Consequence: while this was broken the pre-push
  gate could never pass, so from the day CI was disabled (2026-08-01) this repository had no
  working test gate at all.** The inherited git environment is now cleared once, at the top of the
  suite, and two tests assert both the invariant and the property it protects. Reproduce the old
  behaviour with `GIT_DIR=$(git rev-parse --absolute-git-dir) bash test/test-fail-closed.sh`.
- **The suite also inherited the developer's git config**, so on a machine with
  `commit.gpgsign = true` and an agent-backed signer every fixture commit either hung on a signing
  prompt that never comes — no output, forever — or failed outright. Now imposed process-scoped via
  `GIT_CONFIG_*`, which writes nothing: a `git config` line inside a fixture whose `git init` failed
  quietly writes into the **host** repo's config instead, and while that approach was being tried it
  set `user.name=t` and turned commit signing off in this repository.

### Changed

- **Review rounds are counted per reviewed SHA, not per invocation.** Three single-reviewer runs on
  one commit used to burn the whole cap — punishing the exact workaround you are forced into when
  the relay keeps dying mid-round. Now a new head SHA spends a round; anything on an unchanged SHA
  does not. It counts SHA *transitions* (only the last SHA is stored), so `shaA → shaB → shaA` costs
  three — a revert-and-retry loop should cost.
- **New `PR_RELAY_MAX_SAME_SHA` (default 6)** bounds dispatches on one unchanged SHA, so the more
  permissive round counter cannot become an unbounded loop. It also exits `4`, and the ⛔ message
  says which of the two caps fired. 6 covers a 3-reviewer panel run one at a time with a retry each.
- **The round state is written before reviewers are dispatched**, not after the round completes, and
  is replaced atomically via `mktemp` + `mv`. Writing late meant a killed run recorded nothing, so a
  kill→retry loop was unbounded; writing non-atomically in the kill window could leave a truncated
  file that the corrupt-state rule reads as zero, silently resetting both caps. Consequence, stated
  plainly: a dispatch on a **new** SHA now spends that round even if it is killed a moment later.
- **The state directory's ownership/mode/symlink validation now runs on every branch**, not only on
  the `/tmp` fallback. It was defensible while the directory held one integer; it now holds review
  text, and a group-writable `~/.cache` would leak it.
- Existing state files (a bare integer) are read without error. A file **below** the cap adopts the
  current SHA *without* spending a round, so anyone mid-loop when they upgrade keeps their retries;
  one already **at** the cap still exits `4`, exactly as before.
- `README.md`: new "Evidence and forensics" section, and the loop-safety text, exit-code table and
  agent-loop instructions all corrected — they described `4` as the round cap only, and said a
  dispatched round always burns a slot, both of which are now wrong.

### Removed

- **The GitHub Actions workflow file.** The workflow itself was disabled on 2026-08-01; the file
  lingering in the tree still forced the `workflow` OAuth scope on every tag push, because for a new
  ref the whole tree counts as introduced. Releases had to be made from the browser or after a
  `gh auth refresh -s workflow`.

### Added

- **`bin/ci` and a versioned `.githooks/pre-push`** — the gate is now part of the repository instead
  of living in one machine's `.git/hooks`, which is neither versioned nor cloned. Enable it per clone
  with `git config core.hooksPath .githooks`; that is repo-local config, so a fresh clone has no gate
  until someone runs it, and git deliberately does not activate repository-controlled hooks on clone.
- The hook is the portfolio template (`app-tools/templates/githooks/pre-push`), which closes a hole
  the previous local hook had: it ran the suites against the working tree and then allowed whatever
  was being pushed, so `git push origin HEAD~3:main` passed the gate while shipping an untested
  commit. It also refuses a dirty or untracked-file tree, and a gate run that modified tracked files
  or moved `HEAD`. Annotated tags pointing at `HEAD` and delete-only pushes pass.
- The hook scrubs git's repo-local environment (`git rev-parse --local-env-vars`, plus
  `GIT_QUARANTINE_PATH`) before running the gate. That is a second, independent fix for the failure
  that made the previous hook corrupt the repository it ran in — the suite-level fix landed
  separately.
- `README.md` gains a **Developing this repo** section covering the gate, the honest limits of
  `core.hooksPath`, and how external PRs are tested without CI.
- **`test/test-gate.sh`** — twelve cases covering the hook's own contract, run by `bin/ci`: a clean
  push passes; a non-`HEAD` commit, a dirty tree, an untracked file, a red gate, a gate that rewrites
  tracked files or creates untracked ones or moves `HEAD`, and a non-executable `bin/ci` are all
  refused; delete-only pushes and an annotated tag pointing at `HEAD` pass. Everything runs against a
  bare remote in a temp directory — a gate experiment against a live repository is how a sibling repo
  got junk commits pushed to GitHub on 2026-08-02. `bin/ci` is stubbed, so a red or destructive gate
  can be simulated.
- `bin/ci` probes for `node` as well as `jq`. The header called a missing `node` "the honest false
  alarm" and then did not check for it, so it failed mid-suite with an indirect message.


- **The suites' git isolation was weaker than it looked, and its own tests could not tell.** The
  version that landed with the evidence work named 8 of the 15 variables `git rev-parse
  --local-env-vars` reports, and never cleared `GIT_CONFIG_PARAMETERS` — which git sets for child
  processes whenever anything up the tree ran `git -c …`, and which **overrides** `GIT_CONFIG_COUNT`.
  So an ambient override defeated the isolation silently. Measured with the isolation removed
  entirely, the suite still reported `PASS=276 FAIL=0`: the two hermeticity checks asserted the state
  after isolation on a machine where nothing was hostile, so they proved nothing.
  - Isolation now lives in `test/lib-hermetic.sh`, **sourced** by both suites rather than copied —
    a copy keeps passing after the original is deleted, which is the same failure it exists to
    prevent. The repo had drifted to two suites with two different isolation strengths.
  - The variable list comes from git. Ordering is load-bearing: `GIT_CONFIG_COUNT` is itself on that
    list, so the clearing must come first. A `git rev-parse` failure now aborts instead of leaving
    the loop a silent no-op.
  - Also neutralised: `core.hooksPath`, `core.excludesFile` (a global `*.dat` ignore rule makes a
    fixture's file invisible to `git add`), `core.fsmonitor`, `color.ui`.
  - Eight checks, each **planting** the hostility and proving the plant is live before asserting.
    With the clearing removed, seven of the eight fail; before this change, none did.
  - git **2.31+** is required to run the suites and documented in the README; below it they refuse
    rather than half-applying the isolation.

## [1.4.0] — 2026-08-01

### Added

- **The `claude` reviewer is pinned, on the command line.** It was the last seat taking BOTH its
  model and its permissions from ambient config — a bare `claude -p` — so a `/model` switch
  silently changed what the panel reviewed with, and nothing in the output said so.
  - `CLAUDE_REVIEW_MODEL` (**hard default `opus`**), `CLAUDE_REVIEW_EFFORT` (opt-in) and
    `CLAUDE_REVIEW_FALLBACK_MODEL` (default `sonnet`), read by `pr-review-relay`, `review-local`
    **and** `pr-review-distill`. The model default is deliberately not empty, unlike the codex
    pair: an empty one would have shipped override support while leaving the drift in place.
    **Requires claude 2.1.220+** — `--fallback-model`, `--safe-mode` and `--effort` are rejected by
    older CLIs, which the relay sees as a failed reviewer.
  - The fallback is load-bearing. An unavailable model (no entitlement, over quota, retired id)
    prints its error on **stdout** and exits **1**, with stderr empty — and a non-zero exit *with*
    output is still posted, the round only being marked unclean. So without a fallback that CLI
    error text lands on the PR under a `Claude review` header and the round is burnt. Contrast
    `cursor-agent`, whose error goes to stderr with stdout empty and is correctly reported failed.
  - `pr-review-relay` now also passes `--permission-mode plan --safe-mode`, making Claude the third
    enforced-read-only seat. Plan mode refuses writes; `--safe-mode` disables checkout-supplied
    customizations, closing the hole where a PR-controlled `.claude/settings.json` could
    pre-authorise Bash or Write.
  - `review-local` gets the model pin **without** plan/safe mode, on purpose: it reviews your own
    branch, so `--safe-mode` would only disable your own CLAUDE.md, hooks and MCP. Asserted.
  - `pr-review-distill` gets **both** (it already had plan mode). Its corpus is untrusted PR
    comments from every participant, so the ambient hooks/plugins/MCP that `--safe-mode` disables
    are exactly what an injected comment would reach for; the empty scratch cwd only keeps
    *checkout-local* config out. Both flags are asserted, so neither half can be dropped.
- **`grok` reviewer (Grok Build / `grok-4.5`).** Opt-in via `--reviewers …,grok` (same as
  opencode/qwen). Shared policy in **`lib-grok.sh`** so `pr-review-relay` and `review-local`
  cannot drift. Headless Grok ignores stdin, so the **complete** PR/branch diff always goes
  into a `--prompt-file` (the link-mode size threshold that strips inline diffs for other
  agents does **not** apply). Runs from an isolated temp cwd with `--permission-mode plan`, `--sandbox read-only`, `--deny '*'`, `--verbatim`,
  `--reasoning-effort medium`, `--no-memory`, `--no-subagents`, and
  `--disable-web-search`. Checkout-scoped `.grok` config is not loaded; global `~/.grok` may
  still load (documented). Icon ⚡. Prompt-file write failures are fail-closed.

### Fixed

- **The documented claim that plan mode "cannot run commands" was wrong**, in `README.md` and
  `pr-review-distill`. Measured on claude 2.1.220: `git --version` and `gh pr diff` run under
  `--permission-mode plan` while `touch` is refused. This matters because the link-mode prompt
  tells the reviewer to fetch the PR itself — and because the honest residual is a
  network-capable **read** channel, not "no commands". The README caveat now says so.

- **The Cursor reviewer no longer runs on `Auto`.** All three `cursor-agent` call sites
  (`pr-review-relay`, `review-local`, `pr-review-distill`) now pass `--model`, from a
  `CURSOR_REVIEW_MODEL="${CURSOR_REVIEW_MODEL:-composer-2.5}"` default set once per script.
  The default is **Composer 2.5, Cursor's own model** — Cursor-branded pool, and not Claude, GPT,
  Codex or Grok, so every reviewer stays on the model its own vendor built. (An earlier iteration
  defaulted to `cursor-grok-4.5-high`; that put a second Grok-family reader in the panel for anyone
  also running the opt-in `grok` reviewer — the same defect as Auto picking Claude, one row down.)
  Without it `cursor-agent` fell back to
  `~/.cursor/cli-config.json`, whose default is `Auto` — which (a) billed Cursor's small *Other
  Models* quota (Claude/GPT) while the much larger Cursor-branded pool went unused, and (b) could
  route the review to a **Claude** model, so a Claude-authored PR was reviewed by Claude under a
  Cursor badge and the panel silently lost a reviewer's worth of independence. Asserted on all
  three call sites plus the override, so an unpinned path cannot come back unnoticed.
- **`test-fail-closed.sh` no longer fails on a developer's own `PR_RELAY_OPENCODE_MODEL`.** The
  "unset → no `-m`" assertion tests a default, but `oc_run` inherited the ambient environment, so
  anyone who exports that documented knob saw a red suite on an unmodified checkout. It is now
  cleared inside `oc_run` and still overridable per-test.

- **`pr-review-distill` applies the corpus cap while reading, not after.** Every page of every endpoint
  was captured into a shell variable and the cap was measured only once a whole PR had been appended, so
  one flooded PR peaked in memory before the cap could fire — while the README claimed the cap prevented
  exactly that. Records now arrive NUL-separated (`jq --raw-output0`) and are cut at a **record**
  boundary: a comment body is routinely multi-line, so a line-wise cut hands the agent half a comment as
  if it were whole. The expected `SIGPIPE` from closing the stream early is no longer counted as a failed
  GitHub call, and the truncation message distinguishes whole PRs skipped from one PR cut short. A cap too
  small for a single comment now fails with that message instead of reporting "no review feedback", which
  blamed the repository for an operator setting. Measured: 20 MB of comments on one PR, 50 KB cap, 37 KB
  delivered, no partial record. Note: this makes **`jq` a hard requirement** for `pr-review-distill`
  **1.7+** (the previous code used `gh --jq`, i.e. gh's embedded gojq): `--raw-output0` landed in 1.7,
  and is feature-detected at startup rather than version-parsed, so a 1.6 install fails with the reason
  instead of on every fetch. Whole PRs the cap drops are now counted and reported **even when other PRs
  were kept**: both "skipped" counters used to be read only on the empty-corpus path, so with one PR in
  the corpus a dropped one left no trace and the run looked complete. And a PR whose *header alone*
  exceeds the cap is skipped rather than ending the run — with an empty corpus the remaining budget does
  not shrink, so a later PR with a shorter title may still fit, and aborting there blamed "a single PR's
  feedback" for what was a long title.

- **`agy` is now told how long it actually has.** It enforces its own `--print-timeout` (default 5m) on
  top of the relay's, so raising `PR_RELAY_AGENT_TIMEOUT` above 300 changed nothing: the outer `timeout`
  waited while agy gave up at five minutes and returned `timeout waiting for response`. That killed three
  of four antigravity rounds on 2026-07-27 — and because a missing reviewer correctly invalidates a round,
  each failure cost a full round for everyone else and forced a `--reset`. The relay and `review-local`
  now pass `--print-timeout "${AGENT_TIMEOUT}s"` and give the outer `timeout` a few seconds of grace, so
  agy hits its own limit first and its diagnosis survives instead of a bare exit 124. A test asserts the
  flag reaches agy, since a silently missing flag is invisible to any output-shape assertion. This
  alignment is **agy-only**: whether the other reviewers enforce internal waits has not been checked.

### Changed

- **Reviewers are now asked about tests, regressions and repository conventions.** All six review
  prompts (three `pr-review-relay` variants, `review-local`, `lib-opencode.sh`, `lib-grok.sh`) ask
  for regressions and missing-or-inadequate tests, require a file and line reference where one
  applies, and fix the severity of a missing test at Should-fix so the seats do not disagree and
  lengthen the round. The four prompts whose seat can open a file also ask it to read the
  conventions for the touched paths (AGENTS.md, CLAUDE.md, CONTRIBUTING.md, including nested ones)
  and state that a change *to* a conventions file is under review, not authority over it.
  `lib-opencode.sh` and `lib-grok.sh` are excluded from that part: both run tool-less from an
  isolated cwd with no checkout, so it would only manufacture findings about a file they cannot see.

### Security

- **`pr-review-distill` fences the untrusted corpus.** PR comments were spliced into the prompt
  unfenced, between the very markers the prompt uses to separate its own sections (`---`, `## …`). A
  comment could therefore forge a boundary: end the feedback early, open a fake "rules that already
  exist" block, or emit the exact `No new rules to propose.` sentinel — the agent would then report
  nothing, and the run would look clean. The corpus now sits inside a fence whose marker is generated
  per run (a fixed one is readable in this source, therefore forgeable) and checked for absence from
  the corpus before use, and the task tells the model that anything inside is data and that
  instructions found there are to be reported rather than obeyed. This closes the **structural**
  forgery only: prose that argues with the model is still prose it may believe, which is why the
  agents remain pinned to read-only modes.

## [1.3.0] — 2026-07-27

### Added

- **`pr-review-distill` — turn recent PR review feedback into proposed `AGENTS.md` rules.** Inspired by
  Marco Gomiero's [*Code review comments are the rules you forgot to write down*](https://www.marcogomiero.com/posts/2026/code-review-agents-update/):
  the relay makes reviewers repeat the same corrections across PRs, and each repeat is a project
  convention that isn't written down yet. The new sibling mines the review feedback from recent PRs
  (top-level review bodies, inline review comments, and issue-style comments — including the relay's own
  automated cross-reviews), subtracts what the project's `AGENTS.md` / `CLAUDE.md` already says, and asks
  an agent to **propose** the unwritten rules worth adding, each citing the PRs it came from. It is
  **read-only and propose-only** — it never edits the rules file; you review the ready-to-paste proposal
  and keep what you agree with. Because the corpus is **untrusted** input (a review comment could try
  to prompt-inject the agent), each agent runs in an **enforced** read-only mode pinned on the command
  line (not ambient settings a checkout could widen): `--agent` is `claude` (default,
  `--permission-mode plan`), `codex` (`-s read-only`), or `cursor` (`--mode=ask`); antigravity is not
  offered, as its headless CLI would require `--dangerously-skip-permissions`. The prompt is passed via
  **stdin** so a large review history can't hit the ~128 KiB argv limit. A **non-zero agent exit fails
  the run** (a truncated proposal is never emitted as complete); a failed `gh pr list` is distinguished
  from an empty repo; per-PR API failures are surfaced as an `INCOMPLETE CORPUS` warning rather than
  folded into "no feedback"; and a failed `--out` write exits non-zero. It reuses the toolkit's PATH /
  tmpdir guards (`relay_assert_path_outside_repo`) before running any external command, and runs the
  agent from an empty scratch directory so a checked-out `.claude/settings.json` (e.g. a hook) can't
  execute on agent start. The rules baseline is resolved from the git root — `AGENTS.md`, `CLAUDE.md`,
  or a `.cursor/rules` directory — so running from a subdirectory still finds it; with an explicit
  `--repo` it is not auto-detected from the current directory (wrong repo), so pass `--rules-file`.
  The corpus is capped (`PR_DISTILL_MAX_CORPUS_BYTES`, default 300 KB) so a flooded PR history can't
  exhaust memory or the agent's context, with truncation reported; and `--out` is refused if it resolves
  to the rules file (it never edits it). The read-only posture blocks writes and command execution but is
  not full isolation — a read-only agent can still read reachable files and use ambient MCP/network — so
  the docs frame it as the toolkit's existing "not actively hostile input" threat model rather than
  claiming injection-immunity. Options: `--repo`, `--limit`, `--state` (`merged`/`closed`/`open`/`all`),
  `--rules-file`, `--out`, `--print-comments`, `--dry-run`; budget via `PR_DISTILL_AGENT_TIMEOUT`. Ships
  with `test/test-distill.sh` (stubbed `gh` + agents, no network, 22 cases) wired into CI. Meant to run
  monthly (cron or a Claude skill) so the instructions file self-heals from the review loop instead of
  drifting.

## [1.2.0] — 2026-07-22

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

[1.6.0]: https://github.com/hamen/pr-review-relay/releases/tag/v1.6.0
[1.5.0]: https://github.com/hamen/pr-review-relay/releases/tag/v1.5.0
[1.4.0]: https://github.com/hamen/pr-review-relay/releases/tag/v1.4.0
[1.3.0]: https://github.com/hamen/pr-review-relay/releases/tag/v1.3.0
[1.2.0]: https://github.com/hamen/pr-review-relay/releases/tag/v1.2.0
[1.1.0]: https://github.com/hamen/pr-review-relay/releases/tag/v1.1.0
[1.0.0]: https://github.com/hamen/pr-review-relay/releases/tag/v1.0.0
