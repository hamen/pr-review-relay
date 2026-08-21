# pr-review-relay

![header](assets/header.png)

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/shell-bash-89e051?logo=gnu-bash&logoColor=white)](pr-review-relay)
[![Works with Claude](https://img.shields.io/badge/works%20with-Claude%20Code-blueviolet?logo=anthropic&logoColor=white)](https://docs.anthropic.com/en/docs/claude-code)
[![Works with Codex](https://img.shields.io/badge/works%20with-Codex%20CLI-green?logo=openai&logoColor=white)](https://github.com/openai/codex)
[![Works with Cursor](https://img.shields.io/badge/works%20with-Cursor-0098FF?logo=cursor&logoColor=white)](https://cursor.com)
[![Works with Antigravity](https://img.shields.io/badge/works%20with-Antigravity-orange)](https://antigravity.dev)
[![Works with OpenCode](https://img.shields.io/badge/works%20with-OpenCode-white)](https://opencode.ai)
[![Works with Qwen Code](https://img.shields.io/badge/works%20with-Qwen%20Code-yellow)](https://qwen.ai/qwencode)

**Hand a pull request off to your *other* AI coding agents for an automated cross-review.**

</div>

---

You build a feature with one agent (Claude Code, Codex, Cursor, or Antigravity), it opens a PR — and the
**others** automatically review that PR, headless, and post their findings as PR comments. (Reviewers
are *asked* to be read-only; OpenCode and Grok enforce read-only (Grok via --deny '*' + sandbox; OpenCode via its own agent policy) — see
[Notes & caveats](#-notes--caveats).) Local, free (it uses the agent CLIs you already pay for), and idempotent.

```
 build feature  ──►  open PR  ──►  pr-review-relay --author <self>
                                         │
         ┌───────────────────────────────┼───────────────────────────────┐
         ▼                               ▼                               ▼
   claude -p                       codex exec                cursor-agent -p --model <cursor-pool>
   agy -p          opencode --pure run (own agent)     qwen --safe-mode --approval-mode yolo -p
         └───────────────────────────────┴───────────────────────────────┘
                                         │
                              each posts its review as a PR comment
```

No SaaS, no per-seat review bot, no extra subscription — just the CLIs on your machine.

## 🆕 What's new

**v1.6.0** — *the fixes below landed on `main` in #34; this is the release that names them.* **The
relay could write on the wrong repository, and said the right one while doing it.**
Inside a fork, `gh repo view` answers with the PARENT and ignores `GH_REPO`; that is where `$REPO`
came from, and `$REPO` is what the delete pass addresses. A posting round from a fork of
`android/snippets` would have deleted and posted on a stranger's pull request with every banner
naming the fork. The repository is now read off the URL `gh pr view` resolved, an unusable URL
refuses rather than falling back, the comment itself passes `--repo`, and the host comes off the same
URL so an Enterprise round stops resolving to a same-named repository on github.com. Also: `--pr <url>`
reaches the API as a number, so the delete pass works and a round no longer leaves a second copy of
its review; and a repository named `pull` parses.

**v1.5.0** — **an agent out of quota is benched, the gate ships with the repo, and every run leaves
evidence.** A quota-exhausted reviewer used to fail on every repo until its quota reset, and one
failed reviewer makes the whole round not clean — so the first run that sees the error now writes the
agent down with an expiry parsed from its own message, and later runs drop it until then. Alongside
it: a versioned `.githooks/pre-push` and `bin/ci` so the quality gate travels with the checkout
instead of living on one machine; a timestamped run log plus one sidecar per reviewer, so a round
killed mid-flight is diagnosable rather than a black hole; and one shared git isolation for the test
suites — whose stale-variable cleanup stopped depending on `seq` being installed, a silent no-op that
left every test green while *that cleanup* did nothing (the rest of the isolation still ran).

**v1.4.0** — **the `claude` seat is pinned, and the panel asks about tests.** It was the last
reviewer taking both its model and its permissions from ambient config, so a `/model` switch silently
changed what your panel reviewed with. It now runs on `CLAUDE_REVIEW_MODEL` (default `opus`, with a
load-bearing `--fallback-model`) and, in `pr-review-relay` and `pr-review-distill`, is held read-only
on the command line with `--permission-mode plan --safe-mode`. Alongside it: the `grok` reviewer, the
cursor model pin, and opt-in model overrides for codex and antigravity — `qwen` and `opencode` still
follow their own config. Every review prompt now asks about **regressions** and **missing tests**,
with a file and line reference per finding; the seats that run in your checkout are also asked to
read your repository's conventions (opencode and grok run tool-less from an isolated cwd, with no
checkout to read, so they are asked only for the criteria).
Requires **claude 2.1.220+**. See [Notes & caveats](#-notes--caveats).

**v1.3.0** — **`pr-review-distill`: turn review feedback into written rules.** Code review comments are the
rules you forgot to write down. The new sibling reads the review feedback from recent PRs, compares it to
your `AGENTS.md` / `CLAUDE.md`, and asks an agent to **propose** the unwritten conventions worth adding —
read-only, propose-only, never edits your rules file. See
[Distill unwritten rules](#-distill-unwritten-rules-from-reviews-pr-review-distill).

**v1.1.0** — **fail-closed exit codes.** `✔ Relay done.` used to print and exit `0` even if every reviewer
timed out, so a caller couldn't tell *"all reviewed"* from *"everything broke"*. The relay now signals its
outcome through the exit code — `0` clean, `3` not-clean (failure / stale SHA / no reviewers), `4` cap
reached — plus macOS Bash 3.2 compatibility and a fail-closed test suite. See
[Exit codes](#-exit-codes-fail-closed).

Full history in the [**CHANGELOG**](CHANGELOG.md).

## 🤔 Why

AI agents are great at *writing* code and decent at *reviewing* it — but a second (and third)
independent pair of eyes catches more. Most "AI PR review" products are paid add-ons. If you
already use Claude Code, Codex CLI, Cursor CLI and/or Antigravity CLI, you can get the same
cross-review for free: let whoever opened the PR delegate the review to the others.

## 📦 Requirements

- [`gh`](https://cli.github.com/) (GitHub CLI), authenticated (`gh auth login`).
- **git 2.31+** to run the test suites. They isolate their fixtures from your git environment with
  `GIT_CONFIG_COUNT`, which arrived in 2.31; on an older git they refuse to run rather than applying
  half the isolation and reporting green. Using the tools themselves has no such floor.
- [`jq`](https://jqlang.github.io/jq/) **1.7+** — `pr-review-distill` pipes the GitHub JSON through it,
  because `gh --jq` cannot emit the NUL-separated records its corpus cap needs. The `--raw-output0` flag
  it relies on landed in 1.7, and is feature-detected at startup. The other commands don't need jq.
- Any subset of these agent CLIs, logged in:
  - 🟣 [`claude`](https://docs.anthropic.com/en/docs/claude-code) (Claude Code) **2.1.220+** — uses
    `claude -p`, pinned to `$CLAUDE_REVIEW_MODEL` and (in `pr-review-relay` and
    `pr-review-distill`) held read-only with `--permission-mode plan --safe-mode`. The version
    floor is what `--fallback-model`, `--safe-mode` and `--effort` were measured on; an older CLI
    rejects them, which the relay sees as empty output and reports as a failed reviewer — fail-closed, but the message points at the reviewer rather than at the flag, so check the
    version first if the Claude seat starts failing after an upgrade to this tool
  - 🟢 [`codex`](https://github.com/openai/codex) (OpenAI Codex CLI) — uses `codex exec`
  - 🔵 [`cursor-agent`](https://docs.cursor.com/) (Cursor CLI) — uses `cursor-agent -p`, pinned to
    `composer-2.5` (see [Why the Cursor model is pinned](#-why-the-cursor-model-is-pinned))
  - 🟠 [`agy`](https://antigravity.google/) (Antigravity CLI) — uses `agy -p` (run from shell, not inside the agy TUI)
  - ⚪ [`opencode`](https://opencode.ai) (OpenCode CLI) — uses `opencode --pure run` with a read-only agent the relay defines
    (found on `PATH` or at the stock install path `~/.opencode/bin/opencode`)
  - 🟡 [`qwen`](https://qwen.ai/qwencode) (Qwen Code CLI) — uses `qwen --safe-mode --approval-mode yolo -p`
    (`--safe-mode` ignores any hooks/extensions/skills/MCP/project config in the reviewed checkout — see
    [Notes & caveats](#-notes--caveats)). Auth is the CLI's own: sign in with the free Qwen OAuth tier, or
    point it at a paid Qwen Cloud / DashScope OpenAI-compatible endpoint via `~/.qwen/.env`
    (`QWEN_DEFAULT_AUTH_TYPE`, `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OPENAI_MODEL`). Opt-in: name it
    explicitly in `--reviewers`.
  - ⚡ [`grok`](https://grok.com) (Grok Build CLI) — uses `grok --prompt-file … -m grok-4.5 --reasoning-effort medium --permission-mode plan --sandbox read-only --deny '*'` from an isolated cwd (full diff always embedded; stdin is ignored). Opt-in: name it explicitly in `--reviewers`.

You only need the agents you actually want as reviewers.

## ⚡ Install

### 🐧 Linux / macOS

```bash
BIN=~/.local/bin
mkdir -p "$BIN"
REPO=https://raw.githubusercontent.com/hamen/pr-review-relay/main
curl -fsSL "$REPO/pr-review-relay" -o "$BIN/pr-review-relay"
curl -fsSL "$REPO/review-local" -o "$BIN/review-local"
curl -fsSL "$REPO/pr-review-fetch" -o "$BIN/pr-review-fetch"
curl -fsSL "$REPO/pr-review-distill" -o "$BIN/pr-review-distill"
curl -fsSL "$REPO/pr-review-collapse-comments" -o "$BIN/pr-review-collapse-comments"
curl -fsSL "$REPO/pr-review-consensus" -o "$BIN/pr-review-consensus"
curl -fsSL "$REPO/wrap-collapsed-pr-comment.mjs" -o "$BIN/wrap-collapsed-pr-comment.mjs"
curl -fsSL "$REPO/lib-opencode.sh" -o "$BIN/lib-opencode.sh"
curl -fsSL "$REPO/lib-grok.sh" -o "$BIN/lib-grok.sh"
curl -fsSL "$REPO/lib-panel.sh" -o "$BIN/lib-panel.sh"
chmod +x "$BIN/pr-review-relay" "$BIN/review-local" "$BIN/pr-review-fetch" "$BIN/pr-review-distill" "$BIN/pr-review-collapse-comments" "$BIN/pr-review-consensus"
# lib-*.sh are sourced, not executed — they need no +x
# make sure ~/.local/bin is on your PATH
```

`pr-review-relay`, `pr-review-collapse-comments`, and `pr-review-consensus` expect `wrap-collapsed-pr-comment.mjs` in the same directory as those scripts (as in this repo). If you install only into `$BIN`, keep the `.mjs` file there too. `review-local` doesn't need it (it never posts anywhere).

`pr-review-relay` and `review-local` both source **`lib-opencode.sh`** and **`lib-grok.sh`** from their own directory — shared OpenCode and Grok reviewer policies so the two scripts cannot drift on security-relevant settings. Both refuse to start if either lib is missing.

**`lib-panel.sh`** is sourced by `pr-review-relay`, `review-local` and `pr-review-distill`, and they refuse to start without it. It is the one place that answers "who reviews, with which model" — install it alongside the others or those three stop at startup.

### Configure the panel — `~/.config/pr-review-relay/config`

Optional. With no config file every tool uses the default assigned in its own script, which is what a fresh machine gets.

```bash
mkdir -p ~/.config/pr-review-relay
curl -fsSL "$REPO/assets/config.example" -o ~/.config/pr-review-relay/config
$EDITOR ~/.config/pr-review-relay/config
```

`assets/config.example` documents every key; the short version:

```
REVIEWERS=claude,codex,grok,opencode
PLAN_REVIEWERS=claude,codex,grok45high,kimi3
AGENT_TIMEOUT=500
MODEL_claude=opus
MODEL_codex=gpt-5.6-sol
MODEL_grok=grok-4.6
MODEL_opencode=openrouter/z-ai/glm-5.2
```

A `MODEL_<seat>` key uses the **seat** name you pass to `--reviewers`, so you never need to know that opencode's variable is `PR_RELAY_OPENCODE_MODEL` and antigravity's is `AGY_REVIEW_MODEL`. (`MODEL_agy` still works as an alias of `MODEL_antigravity`.) A suffix that names no seat is kept — ship-feature reads this same file and knows seats this repo does not — but it is reported on stderr, so a typo cannot pass for a setting that quietly had no effect.

Precedence, strongest first: the command-line flag, then the environment variable, then this file, then the default in the script. An **empty value means "not configured"** and falls through — it does not disable anything.

The file is **read, never sourced**: no command substitution, no shell, and a key that is not a bare identifier is refused. Unknown keys and malformed lines are reported on stderr instead of being ignored, because a setting that vanishes in silence is the failure this file exists to prevent. Set `PR_RELAY_CONFIG` to read a different path.

Why it exists: the panel used to live in five places at once. On 2026-08-13 `cursor` was dropped from it and kept reviewing for weeks, because every caller that omits `--reviewers` got the default assigned inside the script rather than the configured panel.

### 🪟 Windows

The scripts are bash-only (`#!/usr/bin/env bash`) — there is no native PowerShell support, so
**PowerShell cannot execute them directly** (no shebang support). You need
[Git for Windows](https://git-scm.com/download/win) for its bundled Git Bash, which is enough to
run everything below.

1. `git clone` this repo somewhere permanent, e.g. `C:\Users\<you>\Project\Work\pr-review-relay`.
   This repo ships a `.gitattributes` that forces LF line endings on the scripts, so a normal
   `git clone` is safe even if your global `core.autocrlf` is set to `true` — no CRLF-related
   `\r`-in-shebang errors under Bash. (If you instead download a ZIP, its extracted files won't go
   through Git's checkout filters, so verify the scripts have LF endings before running them.)
2. Add that repo folder to your **user PATH** so the scripts can be found by name from any directory.
   Read and update the *user*-scoped PATH explicitly — don't use `$env:Path`, since that's the merged
   effective PATH (machine + user) for the current process, and writing it back would copy
   machine-level entries into the user PATH and bloat it over time. Guard the append so re-running
   this doesn't duplicate the entry:

   ```powershell
   $repoDir = 'C:\Users\<you>\Project\Work\pr-review-relay'
   $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
   if ($userPath -notlike "*$repoDir*") {
     [Environment]::SetEnvironmentVariable('Path', "$userPath;$repoDir", 'User')
   }
   ```
3. Make `bash` resolve without putting all of Git's `bin` (a large pile of GNU tooling) on your
   PATH, which would change command resolution globally in every PowerShell/cmd session. Instead,
   add a small function to your PowerShell profile (`notepad $PROFILE`) that points at `bash.exe`
   directly:

   ```powershell
   function bash { & "C:\Program Files\Git\bin\bash.exe" @args }
   ```

   (Adjust the path if Git for Windows is installed elsewhere.) This gives you a `bash` command in
   PowerShell without exposing the rest of Git's `bin` directory on PATH.
4. **Open a new PowerShell window.** PATH changes and profile edits only apply to new processes,
   not the current session.

From then on, invoke every script from PowerShell with an explicit `bash` prefix, e.g.:

```powershell
bash pr-review-relay --author claude
bash pr-review-relay --dry-run --author claude
bash review-local --author claude
```

Run it from **inside the repo you want reviewed** (`cd` there first) — not from inside the
pr-review-relay repo itself — since the relay resolves the PR for the current working repo's branch.

`wrap-collapsed-pr-comment.mjs` and `lib-opencode.sh` still need to sit next to the scripts, same as on Linux/macOS.

## 🚀 Usage

Run it from inside the repo (it resolves the PR for the current branch):

```bash
pr-review-relay --author claude                    # claude opened the PR → codex + cursor + antigravity review
pr-review-relay --pr 47 --parallel                 # explicit PR, reviewers run concurrently
pr-review-relay --pr 47 --reviewers codex          # only one reviewer
pr-review-relay --pr 47 --reviewers claude,agy     # pick specific reviewers
pr-review-relay --context-file SPEC.md             # make every reviewer read & verify against SPEC.md
pr-review-relay --diff                             # old behaviour: pipe the diff instead of a PR link
pr-review-relay --no-post                          # run every reviewer, print the reviews, write nothing
pr-review-relay --dry-run                          # show what it would do, run no agents
```

Flags:

| Flag | Meaning |
|------|---------|
| `--author <name>` | The agent that opened the PR. It auto-excludes itself from reviewing. |
| `--pr <number\|url>` | Target PR. Defaults to the PR for the current branch. |
| `--reviewers a,b,c` | Which agents review. Default: `claude,codex,grok,opencode` — four vendors, every seat on a flat-rate subscription. `cursor`, `antigravity`, and `qwen` are supported but opt-in — name them explicitly to include them. |
| `--context-file <path>` | Prepend a document (docs, spec, API reference) to every reviewer's prompt — they read it and verify the PR against it. Great for "check this against the official docs". |
| `--link` *(default)* | Reviewers read the changed files for context and review the embedded diff. When the relay runs from the PR's own checkout **and** that checkout is the PR head and clean, they read the files straight off local disk — no `gh` round-trips (the speed win, since each `gh` an agentic reviewer runs is an LLM call). Otherwise they fetch the files via `gh pr view`/`gh pr diff`. Either way the diff itself comes from `gh pr diff` (authoritative — matches GitHub, correct for forks). The diff is embedded as a fallback so a reviewer whose sandbox can't run `gh` still reviews something — **but only when it's under `LINK_DIFF_FALLBACK_MAX_BYTES` (default 100000)**; above that it's omitted so a huge inline diff can't blow past an agent's prompt limit. |
| `--diff` | Older behaviour: pipe the raw diff to each reviewer instead of a PR link. |
| `--parallel` | Run the reviewers concurrently. |
| `--no-post` | Run every reviewer for real, print the reviews to stdout, and skip the relay's own posting. For a PR that is not yours, where a person has to read the review before anybody else sees it. Not posting is not itself a failure, but an empty, truncated or timed-out review still exits 3: the flag changes where a review goes, not whether it counts.<br><br>**Scope:** it stops *this script* from commenting. It does not sandbox the reviewers, and several of them run with tool access, so text inside a hostile PR could still tell one of them to publish something. If you need that guaranteed, put a `gh` that refuses writes ahead of the real one on `PATH`: the agents inherit it, so the refusal covers them too. |
| `--dry-run` | Resolve the PR + diff and list reviewers, without invoking agents or posting. |
| `--max-rounds N` | Cap on **reviewed revisions** per PR — the counter advances when the head SHA changes, not on every invocation (default `3`, or `$PR_RELAY_MAX_ROUNDS`). See [Loop safety](#-loop-safety-no-runaway-iteration). |
| `--reset` | Reset the counters for this PR (force another round past a cap). Also discards that PR's run logs and sidecars. |

Environment:

| Variable | Meaning |
|----------|---------|
| `PR_RELAY_MAX_ROUNDS` | Default cap on reviewed revisions per PR (SHA transitions, not invocations). Default: `3`. `0` is accepted and means "always at cap". |
| `PR_RELAY_MAX_SAME_SHA` | Cap on dispatches against one **unchanged** head SHA. Default: `6` — a 3-reviewer panel run one reviewer at a time, with a retry each. Exists because the round counter deliberately ignores same-SHA re-runs, and something still has to bound a re-run loop. Also exits `4`, with its own message. `0` is accepted, but note the asymmetry with `PR_RELAY_MAX_ROUNDS=0`: the same-SHA cap is only consulted once a SHA has been seen before, so `0` still allows the first dispatch on each SHA and blocks every retry. |
| `PR_RELAY_LOG_MAX_BYTES` | Cap on a single reviewer's captured output, applied **on the write path** so a runaway agent cannot fill the disk, and on its captured stderr. The stderr bound keeps reading past the cap and discards the excess, rather than closing the pipe — closing it would make a merely chatty reviewer die of `SIGPIPE` mid-review. **Exception:** `opencode` and `grok` route stderr through a library function the call-site redirect cannot reach, so for those two the trim happens after the agent exits and the file can still grow while it runs. Default: `262144` (256 KiB). A truncated review is marked as such and makes the round **not clean** (exit `3`) — the findings that did not fit are indistinguishable from findings that do not exist. Does **not** apply to the run log, which only holds short event lines. |
| `PR_RELAY_AGENT_TIMEOUT` | Per-reviewer timeout in seconds. Default: `500`. Set `AGENT_TIMEOUT` in `~/.config/pr-review-relay/config` to change it in one place for this tool **and** for `ship-feature plan-review`, which reads the same file. Also handed to `agy` as `--print-timeout`, because it enforces its own wait (default 5m) on top of ours — left unset, that inner limit wins whenever you raise this one, and the round dies with `timeout waiting for response` no matter how high you set it. The outer `timeout` gets a few seconds of grace so agy reaches its own limit first and gets to say so. Whether the other reviewers have internal waits of their own has not been checked. |
| `CURSOR_REVIEW_MODEL` | Model for the `cursor` reviewer. Default: `composer-2.5` (Cursor's own model). Read by `pr-review-relay`, `review-local` **and** `pr-review-distill` — hence no `PR_RELAY_` prefix. Change it if Cursor retires the id, or to pick another Cursor-pool model (`cursor-agent --list-models` shows what your account has); an unknown id makes `cursor-agent` exit 1 with empty output, which the relay reports as a failed reviewer. See [Why the Cursor model is pinned](#-why-the-cursor-model-is-pinned). |
| `CODEX_REVIEW_MODEL` / `CODEX_REVIEW_EFFORT` | Model and reasoning effort for the `codex` reviewer. **Both default to empty, which means "use whatever `~/.codex/config.toml` says"** — the previous, and still normal, behaviour. Set them to review one PR with a specific model without editing that config, which every other use of the `codex` CLI shares. `CODEX_REVIEW_EFFORT` becomes `-c model_reasoning_effort=…`; note that an invalid model id fails the reviewer (e.g. `gpt-5.6` is rejected on a ChatGPT account, where the id is `gpt-5.6-sol`). Read by `pr-review-relay`, `review-local` **and** `pr-review-distill`. |
| `AGY_REVIEW_MODEL` | Model for the `antigravity` reviewer, e.g. `gemini-3.1-pro-high` (`agy models` lists them). Empty = agy's own configured default. Read by `pr-review-relay` and `review-local`. |
| `CLAUDE_REVIEW_MODEL` / `CLAUDE_REVIEW_EFFORT` | Model and effort for the `claude` reviewer. **The model defaults to `opus` — unlike the codex pair, this default is not empty.** Claude was the last seat taking its model from ambient config, so a `/model` switch silently changed what the panel reviewed with; an empty default would have left that in place for everyone. `opus` is a *family alias*: it pins the tier, not a frozen build. `CLAUDE_REVIEW_EFFORT` is opt-in (empty = the CLI's own default) and becomes `--effort …`; set it to `high` for a hard review, at proportional cost. Read by `pr-review-relay`, `review-local` **and** `pr-review-distill`. |
| `CLAUDE_REVIEW_FALLBACK_MODEL` | Model `claude` falls back to when the pinned one is unavailable. Default: `sonnet`. **This is load-bearing, not a convenience.** Measured on claude 2.1.220, an unavailable model (no entitlement, over quota, retired id) prints `There's an issue with the selected model …` on **stdout** and exits **1**, leaving stderr empty. A non-zero exit *with* output is still POSTED — the relay only marks the round unclean — so without a fallback that error text lands on the PR wearing a `Claude review` header, and the round is burnt. The fallback turns a guaranteed-wasted round into a real review. (Contrast `cursor-agent`, whose unknown-id error goes to **stderr** with stdout empty, so it is correctly reported as a failed reviewer and nothing is posted.) **Residual:** if the fallback model fails the same way, the error text is still what gets posted. |
| `PR_RELAY_OPENCODE_MODEL` | Model for the `opencode` reviewer, e.g. `opencode/nemotron-3-ultra-free`. **Unset by default** — opencode then uses your own configured model. See the caveat below before pinning one. |
| `PR_RELAY_OPENCODE_ALLOW_IN_REPO` | Set to `1` to allow `PR_RELAY_OPENCODE_BIN` to point at a binary **inside the repository under review**. Refused by default: that file is written by whoever wrote the diff. |
| `PR_RELAY_OPENCODE_BIN` | Path to the `opencode` binary. Any resolution that goes through `PATH` — implicit, or a **bare name** given here — refuses a binary found *inside the repository under review* (a `.` on your `PATH`, or a repo-local bin dir), since that file was written by the same person as the diff. A value **containing a `/`** that resolves inside the repo is refused too, unless `PR_RELAY_OPENCODE_ALLOW_IN_REPO=1`. The guard only applies inside a git worktree. Absolute paths, relative paths and bare `PATH` names all work — the value is resolved to an absolute path before use, because the reviewer runs from a different working directory. A leading `~` or `~/` **is** expanded (it reaches the variable as a literal character, so the shell never does it for you) — but only when `HOME` is set; the `~user/…` form is *not* supported, give a real path for that; otherwise the relay refuses rather than turning `~/bin/opencode` into `/bin/opencode`. Only needed for a non-standard install: the relay already finds it on `PATH` or at `~/.opencode/bin/opencode`. |

> **Before pinning `PR_RELAY_OPENCODE_MODEL`:** free-tier models can log submitted
> code for product improvement, and your PR diff is the input. Check the provider's
> terms before pointing this at a private repo. Leaving it unset keeps whatever you
> already trust in your own opencode config.

## 🧪 Review before there's a PR (`review-local`)

Same cross-review, but for a branch you haven't opened a PR for yet — no `gh`, no PR number, no
posted comments. It diffs your **current checked-out branch** against a base ref, sends that diff
to the other agents and prints each review straight to the screen. Use it to get a clean,
already-reviewed branch before you push and open the PR.

```bash
review-local --author claude                        # claude wrote this branch → codex + cursor + antigravity review
review-local --author claude --base develop          # diff against a different base ref (default: main)
review-local --author claude --reviewers codex,agy   # pick specific reviewers
review-local --author claude --parallel              # run reviewers concurrently
```

Flags:

| Flag | Meaning |
|------|---------|
| `--author <name>` | The agent that wrote the branch. It auto-excludes itself from reviewing. |
| `--base <ref>` | Ref to diff against. Default: `main`. |
| `--reviewers a,b,c` | Which agents review. Default: `claude,codex,grok,opencode` — four vendors, every seat on a flat-rate subscription. `cursor`, `antigravity`, and `qwen` are supported but opt-in — name them explicitly to include them. |
| `--parallel` | Run the reviewers concurrently. |

Reviewers that read stdin (`claude` / `codex` / `cursor` / `qwen`) get the diff piped in, so a large branch
scales the same way `pr-review-relay --diff` does; `agy` takes it as an argument (it doesn't read a
prompt from stdin); `opencode` receives it as an attached file and reviews it in isolation from the
repo (see the OpenCode note under [Notes & caveats](#-notes--caveats)). Nothing is pushed or posted
anywhere — `review-local` only ever prints to your terminal.

## 🔁 Make it automatic (the handoff)

Tell each agent to call the relay right after it opens a PR. Add a line to each agent's
instructions file (these are global, so they apply in every repo):

**🟣 Claude Code** — `~/.claude/CLAUDE.md`:
> When you open a Pull Request, run `pr-review-relay --author claude`.

**🟢 Codex** — `~/.codex/AGENTS.md`:
> After you open a Pull Request, run `pr-review-relay --author codex`.

**🔵 Cursor** — `~/.cursor/AGENTS.md`:
> After you open a Pull Request, run `pr-review-relay --author cursor`.

**🟠 Antigravity** — `~/.antigravity/AGENTS.md` (or equivalent):
> After you open a Pull Request, run `pr-review-relay --author antigravity` (or `--author agy`).
> Use `agy -p` from a normal shell — not from inside the interactive agy chat.

> **Note:** the relay invokes Antigravity as `agy --dangerously-skip-permissions --print-timeout <PR_RELAY_AGENT_TIMEOUT>s -p`. That is headless, but it is **not** sandboxed — see the caveat under [Notes & caveats](#-notes--caveats).

**⚪ OpenCode** — `~/.opencode/AGENTS.md`:
> After you open a Pull Request, run `pr-review-relay --author opencode`.

**🟡 Qwen Code** — `~/.qwen/QWEN.md`:
> After you open a Pull Request, run `pr-review-relay --author qwen`.

> **Note:** as a *reviewer*, qwen runs `--safe-mode`, so it ignores this `QWEN.md` (and any other
> checkout config) — the snippet only wires the *authoring* role. See the caveat under
> [Notes & caveats](#-notes--caveats).

Now whoever opens the PR, the others review it — no manual step.

## 🔄 Closing the loop: read the reviews and iterate

The relay runs the reviewers **synchronously** and **prints every review to stdout** (in addition to
posting them as PR comments). So the agent that launched the relay gets the full feedback back **in
its own command output** — it can analyze the findings, fix them, push, and re-run. Because the relay
is idempotent, re-running just refreshes the comments (one per agent).

A typical agent instruction to make this a loop:

> After opening a PR, run `pr-review-relay --author <self>`. **Branch on its exit code — only `0` is a
> clean round** (every reviewer actually ran and posted, PR head unchanged; with `--no-post`, ran and
> produced). On `3` the round is not
> trustworthy (a reviewer failed / the SHA couldn't be confirmed / HEAD moved) — **don't act on the
> posted reviews, re-run against the current head**. On `4` a loop cap is hit — read the message: the
> **round** cap (3 reviewed revisions) means stop and escalate; the **same-SHA** cap means you have
> re-run the panel on unchanged code and should push a fix instead.
> On a clean `0`, read the reviews it prints, address every **Blocker** and **Should-fix**, commit and
> push, then run it again. Repeat until no blockers remain (~3 revisions), then summarize what you changed.
> If a run is interrupted, its log path was printed at startup — the reviewers that finished are in it.
>
> When reviewers agree on what still matters, save a **consensus work card** (only agreed Blockers /
> Should-fix / Nits) and run `pr-review-consensus --consensus-file path.md` so the PR description
> shows the consensus and cross-review comments stay collapsed.

Need to re-read the latest reviews later (e.g. a slower reviewer landed after you moved on)? Use the
companion command:

```bash
pr-review-fetch         # prints the cross-review comments for the current branch's PR
pr-review-fetch 47      # …for a specific PR
```

## 📋 Consensus + collapsed reviews (clean PR page)

Cross-review comments are posted **collapsed** by default (`<details>/<summary>` — click to expand, like forum hide/show). The **PR description** stays the place readers focus on after you synthesize consensus.

**Workflow:**

1. Open PR → `pr-review-relay --author <self>` (iterate fix/push/re-run until blockers are gone).
2. Read all review comments (`pr-review-fetch`) and write a **consensus work card** (only items multiple reviewers agreed on — Blockers / Should-fix / Nits).
3. Apply consensus to the PR description and collapse any still-expanded review comments:

```bash
pr-review-consensus --consensus-file reviews/pr-47-consensus.md
# or: pr-review-consensus --pr 47 --consensus-file path.md
```

| Command | Purpose |
|---------|---------|
| `pr-review-consensus` | Replace PR body with consensus markdown; collapse cross-review comments |
| `pr-review-collapse-comments` | Collapse existing relay comments only (no body change) |
| `--append-original` | Keep original PR description in a collapsed block at the bottom |
| `--no-collapse` | Update body only, leave comment expand state unchanged |

Retrofit old PRs (comments only):

```bash
pr-review-collapse-comments 47
```

Consensus file format: same idea as dac-audit-skill issue bodies — summary table, **Blockers (consensus)**, **Should-fix (consensus)**, optional Consider. The file becomes the PR description (plus a PR link header).

## 🧭 Distill unwritten rules from reviews (`pr-review-distill`)

> Inspired by [Marco Gomiero — *Code review comments are the rules you forgot to write down*](https://www.marcogomiero.com/posts/2026/code-review-agents-update/).

The relay makes reviewers repeat themselves — the same "add a test", "use snake_case", "don't do X"
lands on PR after PR. Each repeat is a project convention that isn't yet written in your instructions file.
`pr-review-distill` closes that loop: it mines the review feedback from recent PRs, subtracts what your
`AGENTS.md` / `CLAUDE.md` already says, and asks an agent to **propose** the rules worth adding.

It is **read-only and propose-only** — it never edits your rules file. You get a ready-to-paste markdown
proposal (each rule cites the PRs it came from); you decide what to keep.

```bash
pr-review-distill                          # last 20 merged PRs of the current repo, propose via claude
pr-review-distill --limit 40 --agent codex # more history, a different agent
pr-review-distill --dry-run                # show which PRs + rules file, don't call an agent
pr-review-distill --print-comments         # just dump the gathered feedback corpus
pr-review-distill --out proposed-rules.md  # also write the proposal to a file
```

It reads three feedback sources per PR — top-level review bodies, inline review comments, and issue-style
comments (which include the relay's own automated cross-reviews). The rules baseline is auto-detected
from the git root (`AGENTS.md`, `CLAUDE.md`, or a `.cursor/rules` directory); point it at a specific one
with `--rules-file`.

Point it at another repo with `--repo OWNER/NAME` — but pass `--rules-file` too, since the rules
baseline is otherwise auto-detected from the current directory (the wrong repo). `--state` takes
`merged` (default), `closed`, `open`, or `all`.

Run it **monthly** (a cron job or a Claude skill) so the instructions file self-heals from the review
loop instead of drifting.

**Untrusted input — read-only, but not a sandbox.** The corpus is PR comments, and a comment can try to
prompt-inject the agent. The corpus is passed inside a **fence** whose marker is generated per run and
checked against the corpus before use, and the task states that anything within it is data — so a
comment cannot forge a section boundary using the prompt's own `---` / `## …` markers (ending the
feedback early, faking the existing-rules block, or emitting the empty-result sentinel). That closes the
structural forgery only; prose that argues with the model is still prose it may believe. `--agent` only offers agents pinned to a read-only mode on the command line
(never relying on ambient settings a checkout could carry): `claude` (default, `--permission-mode plan` —
plan mode refuses writes and mutating commands, though **not** read-only ones), `codex` (`-s read-only`), `cursor` (`--mode=ask`, on the same
pinned `CURSOR_REVIEW_MODEL` as the reviewers). Each runs from
an empty scratch directory so no checkout-local config or hooks load, and the prompt is fed via **stdin**
(so a large review history can't blow the ~128 KiB argv limit). `antigravity` is not offered — its
headless CLI would need `--dangerously-skip-permissions`.

This blocks **writes and mutating commands**, but it is **not full isolation**: read-only commands
still run (claude's plan mode refuses `touch` but runs `git` and `gh`), and a read-only agent can
still read files it can reach and use whatever MCP tools / network your ambient config grants, so a
crafted comment could in principle steer those. Same threat model as the rest of this toolkit (see
[Notes & caveats](#-notes--caveats)) — run it on repos whose review history you don't consider actively
hostile. The corpus is capped (`PR_DISTILL_MAX_CORPUS_BYTES`, default 300 KB) so a flooded history can't
exhaust memory or blow the agent's context. The cap applies **while reading**, not after: records
arrive NUL-separated and are cut at a record boundary, so a single PR carrying more than the cap
is bounded and no comment is delivered half-written. Truncation says which kind it was — whole PRs
skipped, or one PR's feedback cut short. A cap too small for even one comment is a config error,
not an empty result. A non-zero agent exit fails the run (a truncated proposal is never emitted as
complete), and a failed GitHub fetch — or a `jq` failure — is surfaced as an `INCOMPLETE CORPUS`
warning. Raise the per-agent budget with `PR_DISTILL_AGENT_TIMEOUT` (default 300s).

## 🔵 Why the Cursor model is pinned

Every `cursor-agent` call in this repo passes `--model "$CURSOR_REVIEW_MODEL"`
(default `composer-2.5`). Left off, `cursor-agent` uses the model in your
`~/.cursor/cli-config.json`, which out of the box is **Auto**. Auto routes to the frontier models,
and that breaks two things at once:

- **It drains the wrong quota.** Auto bills Cursor's *Other Models* pool (Claude, GPT), which is much
  smaller than the Cursor-branded pool. A relay that runs on every PR empties it mid-cycle and the
  cross-review starts failing for a billing reason that looks like a bug.
- **It can collapse the panel to one model.** Auto may pick a Claude model. A PR written by Claude
  then gets reviewed by Claude wearing a Cursor badge — the output still says "🔵 Cursor", so four
  reviewers *look* independent while two of them are the same model agreeing with itself. The whole
  value of a cross-review is that the reviewers fail differently from the author.

`composer-2.5` fixes both. It is Cursor's own model, so it draws on the Cursor-branded pool, and it
is not Claude, GPT, Codex or Grok — every reviewer in the panel stays on the model its own vendor
built, which is the cleanest way to keep them failing differently from each other.

That last point is why the default is Composer rather than Cursor's Grok build. With
`cursor-grok-4.5-high`, anyone who also opts into the `grok` reviewer ends up with two Grok-family
readers in a panel that reports two independent ones — the same defect as Auto picking Claude, one
row further down.

Override with `CURSOR_REVIEW_MODEL` — `cursor-agent --list-models` shows what your account offers.
An id your account does not have is safe to try: as of `cursor-agent 2026.07`, an unknown model makes
it exit 1 and print the error on **stderr**, leaving stdout empty, so the relay reports a failed
reviewer (exit 3) instead of a review. Note the guarantee rests on that stdout being empty — the relay
does post non-empty stdout even on a non-zero exit, marking the round unclean, so a future CLI that
printed the error on stdout would surface it as a (clearly broken-looking) review rather than silently.

> Whatever you override to, keep it out of the other reviewers' families. Setting it to `auto`, to a
> `claude-*` id, or to a `cursor-grok-*` id while you also run the opt-in `grok` reviewer all
> collapse two nominally independent seats onto one model family.

## 🛡️ Loop safety (no runaway iteration)

Telling an agent to "fix and re-run" can spiral. Two layers keep it bounded:

- **Soft:** the agent is told to stop once there are no Blockers/Should-fix left.
- **Hard:** two counters, both exiting `4` with a ⛔ STOP message that says which one fired, so the
  agent ends the loop instead of mistaking it for a pass.

| Counter | Advances when | Default | Tune with |
|---|---|---|---|
| **Round** | the PR head **SHA changes** | 3 | `--max-rounds N`, `PR_RELAY_MAX_ROUNDS` |
| **Same-SHA dispatches** | every dispatch on an **unchanged** SHA | 6 | `PR_RELAY_MAX_SAME_SHA` |

The round counter is what bounds a real read→fix→re-run cycle, and a real cycle always involves a
push — so it counts **reviewed revisions**, not invocations. Splitting a panel across several
invocations on one commit (`--reviewers codex`, then `cursor`, then `grok`) therefore costs **no
rounds at all**, which is what you need when the relay keeps dying mid-round and you have to run the
reviewers one at a time. The same-SHA counter is what keeps that from becoming an unbounded loop; its
default of 6 covers a 3-reviewer panel run singly with one retry each.

Strictly the round counter counts **SHA transitions**: only the last SHA is stored, so
`shaA → shaB → shaA` spends three rounds. That is intended — a revert-and-retry loop should cost.

State lives in `$XDG_CACHE_HOME/pr-review-relay/` (or `$HOME/.cache/…`), **auto-resets after 6h** of
inactivity, and can be cleared with `--reset`. Both discard the run logs for that PR at the same
time, so you never read a fresh counter next to a stale transcript. Runs that never wrote state have
no counter to reset; their leftovers expire on the same 6h clock — see **Retention** below.

> **Concurrency:** the counters are an unlocked read-modify-write. Two relays racing on the same PR
> can lose an update and therefore **undercount** dispatches, weakening *both* guards. Don't run
> concurrent relays on one PR and rely on the caps.

## 🔦 Evidence and forensics

Every run writes the files below under the same state directory. The log is opened — and its path printed — as
soon as the PR number and repository are known, which is **before** the head-SHA read and before
`gh pr diff`: those are the calls that can hang, and a hang there used to leave nothing at all. It
cannot be opened any earlier, because the file name is derived from the repository, and that itself
comes from `gh` — so a hang while resolving the PR still leaves no trace.

- `<key>.run.XXXXXXXX` — the **run log**: a timestamped start, each dispatch, the state decision,
  each reviewer's outcome, and the final verdict — including the failure verdicts, which are the
  ones worth reading. The start is written in three parts, as the facts become known: PR and
  repository when the log opens, the reviewed SHA as soon as it is read, then the reviewer list,
  PID, PGID and round counters once the round state is resolved. So a log that stops early still
  tells you how far the run got — a kill during the diff fetch names the commit under review; one
  during the SHA read cannot, and its absence is the tell.
- `<key>.run.XXXXXXXX.k_<reviewer>.review` — one **sidecar per reviewer**, carrying that reviewer's
  output as the CLI produces it.

The path is printed at **startup**, not just at the end — a run that is killed never reaches the
closing banner, and that is exactly the run you want the log for. Each file has a single writer, so
nothing interleaves under `--parallel`; the name is unique per invocation, so a retry never
overwrites the evidence of the attempt that died.

This exists because relay runs do get killed mid-round, and every investigation so far has ended
outside this script. It does not prevent that — it means the next occurrence leaves proof of which
reviewers were dispatched, which finished, and what the one in flight had written.

Three honest limits. Partial capture is **best-effort**, because many CLIs block-buffer when stdout
is not a terminal (`stdbuf` is used when available, never required). A `SIGKILL` can always land
between two writes. And the sidecar-path symlink refusal is belt-and-braces that no test exercises:
the path comes from a `mktemp` that created it `O_EXCL` moments earlier inside a mode-700 directory
you own, so it provably did not exist — the real control is the directory, not the check.

**Retention.** Every invocation that gets as far as opening a run log leaves its own files. They are removed when that PR's state is
discarded — by `--reset` or by the 6h inactivity reset — and, for runs that never wrote any state at
all (a dry run, one that resolves no reviewer, one killed before the pre-dispatch write), by a
sweep that expires those leftovers on their own 6h clock. Expiry is by **family**: a log and its
sidecars go together, so you never read a transcript whose log is gone.

Three honest limits, all following from one rule: **the sweep runs only when that PR has no `.round`
file at all.** That is deliberate — a live session's first-round log is legitimately older than 6h,
and age-deleting it would destroy the forensics of a run still in progress.

- It is **lazy and per-PR**: it runs when that PR is relayed again, so a PR never touched again keeps
  its files indefinitely. `--reset` or a manual delete is the answer there.
- An orphan created **while a session is alive** is not collected on the 6h clock either — it waits
  for `--reset`, or for the session's own state to go stale, which then clears the whole key.
- A run blocked for more than 6h *before* it writes state (a hung `gh pr diff`, say) can have its log
  swept by a later run while it is still alive — but only if no `.round` file exists for that PR.
  The alternative was a second, divergent notion of "stale", which is worse.

The sweep covers the `<key>.state.XXXXXXXX` temps a killed state write leaves behind, on the same
clock and under the same rule.

A PR reviewed many times inside one session accumulates one log plus one sidecar per reviewer per
run, holding review text, until one of the above fires. Output is capped by
`PR_RELAY_LOG_MAX_BYTES` (default 256 KiB) per reviewer, on the write path and for stderr too, so a
single runaway agent cannot fill the disk; the cap does not apply to the run log itself, which only
ever holds short event lines. If you want them gone sooner, `--reset` on the PR, or delete
`<key>.run.*` from the state directory.

## 🔍 How it works

1. Resolves the PR (current branch or `--pr`), opens the run log (see
   [Evidence and forensics](#-evidence-and-forensics) — it is opened here, before the calls that can
   hang), then reads the diff with `gh pr diff` (used as a sanity guard and for the line/byte
   summary).
2. For each reviewer (except `--author`), runs the agent **headless** with a focused
   review prompt. By default (**`--link`**) the reviewer reads the changed files in context — so it
   reviews the *whole* PR, not just a diff snapshot. When the relay is run from the PR's own checkout and
   that checkout is the PR head and clean, it reads those files **straight off local disk** (no `gh`
   round-trips — the speed win); otherwise it fetches them via `gh pr view`/`gh pr diff`. The diff itself
   always comes from `gh pr diff` (authoritative, fork-safe) and is embedded as a **fallback** so a
   reviewer whose sandbox can't run `gh` still returns a review — but the fallback is **omitted for large
   diffs** (over `LINK_DIFF_FALLBACK_MAX_BYTES`, default 100000) so an oversized inline diff can't exceed
   an agent's prompt limit. With **`--diff`** only the raw diff is sent. A **`--context-file`** is
   prepended so every reviewer verifies against it.
3. Posts each review as a **collapsed** PR comment via `gh pr comment` (forum-style `<details>`),
   tagged per agent (🟣 Claude / 🟢 Codex /
   🔵 Cursor / 🟠 Antigravity / ⚪ OpenCode).
4. **Idempotent:** before posting, it deletes any previous review from the *same* agent on that PR,
   so re-runs replace rather than duplicate — one current review per agent.

## 🚦 Exit codes (fail-closed)

`✔ Relay done.` alone doesn't mean "everyone reviewed" — so the relay signals the outcome through its
**exit code**, and fails closed (any doubt → non-zero). A script driving the handoff should branch on it:

| Code | Meaning | What to do |
|------|---------|------------|
| `0` | Every reviewer that ran produced **and posted** a review, and the PR head didn't move. With `--no-post`, produced is the bar and nothing is posted. May be a **PARTIAL** panel — a reviewer can be skipped (CLI not installed) or [benched](#-benched-reviewers-out-of-quota) (out of quota). The banner says which, and how many. | Everyone *ran* — not that it's approved. Read the reviews, resolve every Blocker/Should-fix, then merge. |
| `3` | Not a clean round: a reviewer returned empty / timed out / exited non-zero / failed to post, **or** an explicitly-requested reviewer was missing (**except** when it is [benched](#-benched-reviewers-out-of-quota) for quota — that is the one carve-out, and the round can still exit `0` as PARTIAL), **or** no reviewer ran, **or** HEAD moved mid-round (reviews now describe stale code). | Fix the cause and re-run; don't treat as reviewed. |
| `4` | A loop cap was reached — either the **round** cap (`--max-rounds`, counted per reviewed SHA) or the **same-SHA dispatch** cap (`PR_RELAY_MAX_SAME_SHA`). The message says which. | Stop looping; escalate to a human. On the same-SHA cap, pushing a fix is what unblocks it. |
| `1`/`2` | Usage/precondition error (no `gh`, no PR, empty diff, bad arg). | Fix the invocation. |

A missing CLI from the **default** reviewer set is a tolerated skip (users have different agents
installed); only reviewers named explicitly via `--reviewers` are required to be present.

### ⏸ Benched reviewers (out of quota)

There is **one exception** to "explicitly requested must be present". An agent that reports having
exhausted its quota is **benched**: dropped from the panel until the reset time it told us, and the
round can still be clean without it.

The reason is that the alternative is worse. A quota-exhausted agent fails *every* round, on *every*
repo, for days — so every verdict reads "not clean" even when all the other reviews arrived. People
then either re-run and pay for it again, or learn to ignore the verdict, which is worse than never
printing one.

The safeguards are what make this acceptable:

- **It expires by itself.** The expiry comes from the agent's own message (`Resets in 56h55m40s`),
  so the reviewer returns without anyone remembering to undo anything.
- **It is announced on every round**, and the verdict says `PARTIAL cross-review` with the reason.
  A thinner panel is never presented as a full one.
- **Only an explicit quota message benches.** A timeout or a crash still fails the round — those are
  usually a large diff or a bad afternoon, and hiding them would hide a regression.
- **An empty panel is still exit 3.** If everything is benched, nothing was reviewed, and that is
  never clean.

`--reset` does **not** clear the bench — it forgets the round counter for one PR, while the bench is
global and time-based. If you reset a PR and a reviewer is still skipped, that is why.

To force a reviewer back before its reset, delete its line from the bench file (one tab-separated
line per agent: name, expiry epoch, reason). It sits beside the round state — under
`$XDG_CACHE_HOME/pr-review-relay/benched`. The **directory** is the thing created `0700` and
ownership-checked (the file itself lands `0600` via `mktemp`), because a file that decides who
reviews is worth the same protection as the reviews themselves. Each posted
review's footer records the **reviewed SHA** so you can tell whether a review predates a later push.

> **Note:** reviews are posted as they complete, *before* the end-of-round SHA re-check. So a round that
> ends in `3` (a reviewer failed, or HEAD moved mid-round) may still have left comments on the PR — tagged
> with the SHA they reviewed. Trust the **exit code**, not the mere presence of comments: on `3`, re-run
> and read the fresh round.
>
> **What a round costs.** The state is recorded **before** reviewers are dispatched, so an
> interrupted run has already accounted for itself — that is what bounds a kill→retry loop. A
> dispatch on a **new** SHA spends one round even if it ends in `3` or is killed (a persistently
> flaky reviewer must still hit the cap). A dispatch on an **unchanged** SHA spends **no round**,
> only one same-SHA slot. A run where *nobody* was dispatched (`--reviewers bogus`, everything
> skipped, `--dry-run`) spends nothing at all.

### A note on `PATH`

Both scripts **refuse to start** (exit `2`) if any `PATH` entry resolves inside the repository being
reviewed — a `.` entry, a repo-local `bin/`, or a symlink to either. Everything the relay runs (`gh`,
`git`, `timeout`, `node`, …) comes from `PATH`, so a repo-controlled entry means the branch under
review chooses those binaries. If you see that error, take the entry out of `PATH`.

One limit worth knowing: the check cannot cover the *interpreter*. `#!/usr/bin/env bash` has already
picked a `bash` through `PATH` before the first line runs. Nothing a script does can fix that — if
`PATH` points into an untrusted checkout, every command you type is affected, not just this one.

### `review-local` exit codes

`review-local` follows the same fail-closed idea as the relay, on a smaller surface:

| Code | Meaning |
|------|---------|
| `0` | every dispatched reviewer produced a review |
| `3` | a reviewer produced nothing usable (empty / whitespace-only / timed out / non-zero), **or** an explicitly requested reviewer was missing, **or** no reviewer ran at all |
| `1`/`2` | precondition or usage error (not a repo, unknown base ref, bad argument, unusable `PR_RELAY_OPENCODE_BIN`) |

## 📋 Notes & caveats

- **⚠️ OpenCode, Grok and Claude are enforced read-only (codex, antigravity and cursor are asked).** The rest are asked not to modify
  anything and normally don't — but a prompt is not a boundary, and the thing they are reading is
  exactly what would try to argue them out of one. They all predate the OpenCode work and are
  documented rather than quietly changed: tightening any of them affects that agent's reviews and
  belongs in its own PR, where the effect can be tested.
  - **Codex** — `pr-review-relay` invokes it as `codex exec -s danger-full-access`, so it can write
    files and run commands while reading a diff an untrusted contributor wrote. (`review-local` uses
    `-s read-only`, so the two disagree with each other.)
  - **Antigravity** — `agy --dangerously-skip-permissions -p` auto-approves permissions. The prompt
    asks it not to modify anything, but a prompt is not a boundary, and the content it is reading is
    exactly what would try to talk it out of one.
  - **Claude** — now enforced on the command line: `--permission-mode plan --safe-mode`. Plan mode
    refuses writes and mutating commands; `--safe-mode` disables checkout-supplied customizations
    (CLAUDE.md, skills, plugins, hooks, MCP, commands, agents), which is what closes the old hole
    where a PR-controlled `.claude/settings.json` could pre-authorise Bash or Write — plan mode
    alone does **not** stop those hooks from running at session start.
    **Residual, stated precisely:** plan mode does not refuse *read-only* commands. Measured on
    claude 2.1.220, `git --version` and `gh pr diff` run under it while `touch` is refused — which
    is deliberate, since the link-mode prompt tells the reviewer to fetch the PR itself. So a
    prompt-injected reviewer keeps a **network-capable read channel** (`gh`, `curl`): it cannot
    alter your checkout, but it can read and exfiltrate. There is no OS sandbox and `Read` is
    unrestricted. Note also that plan mode still writes a plan file under `~/.claude/plans/`, so
    "blocks writes" is true of the checkout, not of the whole filesystem.
    `review-local` deliberately gets the model pin **without** plan/safe mode: it reviews your own
    branch, so there is no untrusted author, and `--safe-mode` there would only disable your own
    CLAUDE.md, hooks and MCP for your own review.
  - **Cursor** — `cursor-agent -p --trust --mode=ask --model "$CURSOR_REVIEW_MODEL"` keeps it in Q&A
    mode, which is the closest to a real constraint of the three, but it is still the agent's own mode
    rather than an enforced policy. The model is pinned rather than left to Cursor's `Auto` — see
    [Why the Cursor model is pinned](#-why-the-cursor-model-is-pinned).
  - **Qwen** — `qwen --safe-mode --approval-mode yolo -p`. It takes no model flag, so it is now the
    one remaining seat whose model is whatever its own config says; pinning it belongs in its own PR.
    `yolo` auto-approves shell/write with no
    sandbox, the same unconfined posture as Codex and Antigravity above. What it adds over them is
    `--safe-mode`: Qwen Code otherwise loads `.qwen/settings.json` / `QWEN.md` / hooks / extensions /
    skills / MCP servers from the checkout it runs in — the same PR-controlled injection surface the
    Claude bullet warns about — and `--safe-mode` turns all of that off, so a reviewed branch can't ship
    config that executes during review. `yolo` (rather than `--approval-mode plan`) is kept so the
    reviewer can still run `gh` to fetch the PR in link mode; for stricter isolation, run it under a
    sandbox (`--sandbox` / `QWEN_SANDBOX`) if your machine has one configured. The relay sets
    `QWEN_CODE_SUPPRESS_YOLO_WARNING=1` on the invocation purely to keep the yolo-no-sandbox banner off
    the captured review output — it changes nothing about what the reviewer may do.
- **Grok is also enforced (tool-less + sandbox):** `grok --prompt-file … --deny '*' --sandbox read-only --permission-mode plan`. Headless Grok **ignores stdin**, so the full diff is always embedded in the prompt-file (the link-mode size threshold that strips inline diffs for other agents does **not** apply to Grok). `--deny '*'` removes tools so a malicious PR cannot drive host file reads via tools; the sandbox blocks writes and (on Linux) child network. Checkout-scoped `.grok` is avoided via an isolated cwd. **Residual:** global `~/.grok` config/plugins may still load — treat that as a trust boundary, not a sealed sandbox.
- **OpenCode is the exception, and it is enforced:** `opencode --pure run` with a primary agent the
  relay defines itself and an inline default-deny policy. `--pure` matters — it stops external plugins,
  which execute at startup regardless of permissions.
- **OpenCode read-only is enforced by config, not by the agent name.** Selecting a built-in agent is *not* a
  sandbox — their permissions are user-configurable, and `agent.plan.mode: "subagent"` in a config makes
  OpenCode fall back to `build` with *that* agent's rules (verified: shell came back). The relay
  therefore defines and selects its own primary agent, whose mode and permissions are both fixed. Each invocation sets
  `OPENCODE_CONFIG_CONTENT` (a runtime override that outranks your own `opencode.json`) to a
  **deny-everything** policy — `"*": "deny"`, no allowlist (see the next bullet) — repeated on the
  relay's own agent, because OpenCode applies agent-scoped permissions
  *after* the global ones, so the agent actually in use has to carry the policy too. It also runs with `--pure` so external plugins, which execute at startup, don't load.
  Deliberately **not** run with `--auto`, which would auto-approve every `ask` permission.
- **The OpenCode reviewer gets no tools at all.** Not "no writes" — nothing: `"*": "deny"`, with no
  allowlist. It does not need any, because the diff reaches it as prompt content via `-f` rather than
  through a tool call; a review of the attachment is identical with every tool denied. Allowing reads
  was the last exfiltration route, since they were not confined to the attachment and the relay
  **posts** the result: a prompt-injected diff could have had the model read a credential and quote it
  into a public PR comment.
- **Shell is denied, so OpenCode never fetches the PR itself** — the diff is attached to the prompt as
  a file instead, in both modes and at any size. Narrower designs were tried first and each was demonstrably
  bypassable: the original `--dangerously-skip-permissions` (an undocumented alias for `--auto`, so it
  approved everything); selecting the built-in `plan` agent (its permissions and even its mode are
  user-configurable — it ran `id`, and redirecting it to a subagent fell back to `build`); allowing just `gh pr view` / `gh pr diff` (defeated by shell
  redirection — `gh pr view N > file` matches the allowed prefix and writes); omitting the
  policy on the agent actually selected (agent-scoped permissions apply after the global ones); and denying tools by
  name (anything unnamed — custom tools, MCP servers — stays allowed by default). The full list, with
  what each failed on, is in `lib-opencode.sh`.
- **OpenCode runs outside the repository, and therefore reviews the diff alone.** It does not browse
  the checkout the way the other reviewers do. This is not a limitation we could avoid: OpenCode reads
  the project `opencode.json` from its working directory, and an `mcp` server declared there is
  **launched at startup, before any tool permission applies** — so a pull request that adds an
  `opencode.json` would get arbitrary command execution simply by being reviewed. Verified: a planted
  MCP entry ran its command with `"*": "deny"` and `--pure` both in force. Neither the permission
  policy nor `--pure` (plugins only) prevents it; not reading attacker-authored config does.
- **Cursor needs `--trust`** in headless mode or it blocks on a workspace-trust prompt — handled.
- **Cursor is slower/chattier** than Codex; its comment may land a bit later.
- **Link mode is the default:** each reviewer fetches the PR itself and reads the changed files in
  context — deeper than a diff snapshot. The diff is embedded as a fallback, so a sandbox that can't run
  `gh` (notably `codex exec --read-only`) still reviews the diff instead of returning nothing. Pass
  `--diff` for the older diff-only behaviour. Either way the agent runs in the repo — except OpenCode, which is deliberately launched outside it (see the caveats above).
- **Verify against sources** with `--context-file <path>`: the document is prepended to every
  reviewer's prompt, so they cross-check the PR against e.g. an official spec or API reference instead
  of relying on memory. The reviewer comment is footnoted with the context file's name.
- **Antigravity** needs `agy` on PATH; invoke `agy -p` from zsh/bash (not inside the agy TUI). In some sandboxes it may hang — run relay from your Mac terminal if needed.
- Runs on your machine, so it works when your machine is on. It's a local relay, not a hosted bot.

## 🧰 Developing this repo

This section is for working **on** pr-review-relay. If you only want to *use* it, the
[Install](#-install) section above is all you need — it downloads the scripts, no clone involved.

```bash
git clone https://github.com/hamen/pr-review-relay
cd pr-review-relay
git config core.hooksPath .githooks   # once per clone — see below
bin/ci                                # the gate; run it before pushing
```

**There is no CI.** The GitHub Actions workflow was disabled on 2026-08-01 and its file removed, so
`bin/ci` is the only thing between a change and `main`. It runs a syntax check over every shell file
the repo ships — including the libraries that are *sourced* at runtime, whose errors would otherwise
surface only when a user selects that reviewer — a capability probe for `jq --raw-output0`, and the three
test suites.

`.githooks/pre-push` runs `bin/ci` for you and refuses the push if it fails. Its own behaviour is
covered by `test/test-gate.sh`, which `bin/ci` runs — twelve cases against a throwaway remote. It also refuses in
cases where a passing gate would be a lie: pushing a ref that is not your checked-out `HEAD` (the
gate tests the working tree, so `git push origin HEAD~3:main` would ship something nobody tested), a
dirty or untracked-file tree, and a gate run that modified tracked files or moved `HEAD` while
running. Annotated tags pointing at `HEAD` and delete-only pushes are allowed through.

**`core.hooksPath` is repo-local config, so a fresh clone has no gate until you run that command.**
Versioning the hook makes the gate possible everywhere; git deliberately does not activate
repository-controlled hooks on clone, so it cannot be made automatic from inside the repo. If you
have an old `.git/hooks/pre-push` from before this change, delete it — once `core.hooksPath` is set
it is never consulted, so it will only confuse the next person who reads it.

Do not reach for `--no-verify`. A failing gate is a finding.

### Pull requests from outside

With no CI, nothing on GitHub's side tests an external PR. The maintainer runs `bin/ci` against the
PR head before merging, and re-checks that the head SHA has not moved between the run and the merge —
a contributor can push again in between, and a gate run against a superseded commit proves nothing.
Please say in the PR whether `bin/ci` passes locally for you; it saves a round trip.

## 📄 License

MIT © Ivan Morgillo
