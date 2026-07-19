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

**Hand a pull request off to your *other* AI coding agents for an automated cross-review.**

</div>

---

You build a feature with one agent (Claude Code, Codex, Cursor, or Antigravity), it opens a PR — and the
**others** automatically review that PR, headless, and post their findings as PR comments. (Reviewers
are *asked* to be read-only; only the OpenCode one has that enforced — see
[Notes & caveats](#-notes--caveats).) Local, free (it uses the agent CLIs you already pay for), and idempotent.

```
 build feature  ──►  open PR  ──►  pr-review-relay --author <self>
                                         │
         ┌───────────────────────────────┼───────────────────────────────┐
         ▼                               ▼                               ▼
   claude -p                       codex exec                      cursor-agent -p
   agy -p                  opencode --pure run (own agent)                      │
         └───────────────────────────────┴───────────────────────────────┘
                                         │
                              each posts its review as a PR comment
```

No SaaS, no per-seat review bot, no extra subscription — just the CLIs on your machine.

## 🆕 What's new

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
- Any subset of these agent CLIs, logged in:
  - 🟣 [`claude`](https://docs.anthropic.com/en/docs/claude-code) (Claude Code) — uses `claude -p`
  - 🟢 [`codex`](https://github.com/openai/codex) (OpenAI Codex CLI) — uses `codex exec`
  - 🔵 [`cursor-agent`](https://docs.cursor.com/) (Cursor CLI) — uses `cursor-agent -p`
  - 🟠 [`agy`](https://antigravity.google/) (Antigravity CLI) — uses `agy -p` (run from shell, not inside the agy TUI)
  - ⚪ [`opencode`](https://opencode.ai) (OpenCode CLI) — uses `opencode --pure run` with a read-only agent the relay defines
    (found on `PATH` or at the stock install path `~/.opencode/bin/opencode`)

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
curl -fsSL "$REPO/pr-review-collapse-comments" -o "$BIN/pr-review-collapse-comments"
curl -fsSL "$REPO/pr-review-consensus" -o "$BIN/pr-review-consensus"
curl -fsSL "$REPO/wrap-collapsed-pr-comment.mjs" -o "$BIN/wrap-collapsed-pr-comment.mjs"
curl -fsSL "$REPO/lib-opencode.sh" -o "$BIN/lib-opencode.sh"
chmod +x "$BIN/pr-review-relay" "$BIN/review-local" "$BIN/pr-review-fetch" "$BIN/pr-review-collapse-comments" "$BIN/pr-review-consensus"
# lib-opencode.sh is sourced, not executed — it needs no +x
# make sure ~/.local/bin is on your PATH
```

`pr-review-relay`, `pr-review-collapse-comments`, and `pr-review-consensus` expect `wrap-collapsed-pr-comment.mjs` in the same directory as those scripts (as in this repo). If you install only into `$BIN`, keep the `.mjs` file there too. `review-local` doesn't need it (it never posts anywhere).

`pr-review-relay` and `review-local` both source **`lib-opencode.sh`** from their own directory — it holds the OpenCode reviewer's binary resolution and read-only permission policy, kept in one place so the two scripts cannot drift apart on a security-relevant setting. Both refuse to start if it is missing.

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
pr-review-relay --dry-run                          # show what it would do, run no agents
```

Flags:

| Flag | Meaning |
|------|---------|
| `--author <name>` | The agent that opened the PR. It auto-excludes itself from reviewing. |
| `--pr <number\|url>` | Target PR. Defaults to the PR for the current branch. |
| `--reviewers a,b,c` | Which agents review. Default: `claude,codex,cursor,antigravity`. `opencode` is supported but opt-in — name it explicitly to include it. |
| `--context-file <path>` | Prepend a document (docs, spec, API reference) to every reviewer's prompt — they read it and verify the PR against it. Great for "check this against the official docs". |
| `--link` *(default)* | Hand reviewers the PR reference; each fetches it itself (`gh pr view`/`gh pr diff`) and reads the full files in context. The diff is also embedded as a fallback so a reviewer whose sandbox can't run `gh` (e.g. `codex exec --read-only`) still reviews something — **but only when the diff is under `LINK_DIFF_FALLBACK_MAX_BYTES` (default 100000).** Above that the fallback is omitted so a huge inline diff can't blow past an agent's prompt limit and make it return empty; reviewers just fetch the PR via `gh`. |
| `--diff` | Older behaviour: pipe the raw diff to each reviewer instead of a PR link. |
| `--parallel` | Run the reviewers concurrently. |
| `--dry-run` | Resolve the PR + diff and list reviewers, without invoking agents or posting. |
| `--max-rounds N` | Hard cap on review rounds per PR (default `3`, or `$PR_RELAY_MAX_ROUNDS`). |
| `--reset` | Reset the round counter for this PR (force another round past the cap). |

Environment:

| Variable | Meaning |
|----------|---------|
| `PR_RELAY_MAX_ROUNDS` | Default max review rounds per PR. |
| `PR_RELAY_AGENT_TIMEOUT` | Per-reviewer timeout in seconds. Default: `300`. |
| `PR_RELAY_OPENCODE_MODEL` | Model for the `opencode` reviewer, e.g. `opencode/nemotron-3-ultra-free`. **Unset by default** — opencode then uses your own configured model. See the caveat below before pinning one. |
| `PR_RELAY_OPENCODE_BIN` | Path to the `opencode` binary. Any resolution that goes through `PATH` — implicit, or a **bare name** given here — refuses a binary found *inside the repository under review* (a `.` on your `PATH`, or a repo-local bin dir), since that file was written by the same person as the diff. Giving a value **containing a `/`** is exempt: naming a specific file is your decision and cannot be caused by a pull request. The guard only applies inside a git worktree. Absolute paths, relative paths and bare `PATH` names all work — the value is resolved to an absolute path before use, because the reviewer runs from a different working directory. A leading `~` is **not** expanded (that is shell syntax, not part of a path): use `$HOME/...`. Only needed for a non-standard install: the relay already finds it on `PATH` or at `~/.opencode/bin/opencode`. |

> **Before pinning `PR_RELAY_OPENCODE_MODEL`:** free-tier models can log submitted
> code for product improvement, and your PR diff is the input. Check the provider's
> terms before pointing this at a private repo. Leaving it unset keeps whatever you
> already trust in your own opencode config.

## 🧪 Review before there's a PR (`review-local`)

Same cross-review, but for a branch you haven't opened a PR for yet — no `gh`, no PR number, no
posted comments. It diffs your **current checked-out branch** against a base ref, sends that diff
to the other agents read-only, and prints each review straight to the screen. Use it to get a clean,
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
| `--reviewers a,b,c` | Which agents review. Default: `claude,codex,cursor,antigravity`. `opencode` is supported but opt-in — name it explicitly to include it. |
| `--parallel` | Run the reviewers concurrently. |

Reviewers that read stdin (`claude` / `codex` / `cursor`) get the diff piped in, so a large branch
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

> **Note:** the relay invokes Antigravity as `agy --dangerously-skip-permissions -p`. That is headless, but it is **not** sandboxed — see the caveat under [Notes & caveats](#-notes--caveats).

**⚪ OpenCode** — `~/.opencode/AGENTS.md`:
> After you open a Pull Request, run `pr-review-relay --author opencode`.

Now whoever opens the PR, the others review it — no manual step.

## 🔄 Closing the loop: read the reviews and iterate

The relay runs the reviewers **synchronously** and **prints every review to stdout** (in addition to
posting them as PR comments). So the agent that launched the relay gets the full feedback back **in
its own command output** — it can analyze the findings, fix them, push, and re-run. Because the relay
is idempotent, re-running just refreshes the comments (one per agent).

A typical agent instruction to make this a loop:

> After opening a PR, run `pr-review-relay --author <self>`. **Branch on its exit code — only `0` is a
> clean round** (every reviewer actually ran and posted, PR head unchanged). On `3` the round is not
> trustworthy (a reviewer failed / the SHA couldn't be confirmed / HEAD moved) — **don't act on the
> posted reviews, re-run against the current head**. On `4` the round cap is hit — stop and escalate.
> On a clean `0`, read the reviews it prints, address every **Blocker** and **Should-fix**, commit and
> push, then run it again. Repeat until no blockers remain (max ~3 rounds), then summarize what you changed.
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

## 🛡️ Loop safety (no runaway iteration)

Telling an agent to "fix and re-run" can spiral. Two layers keep it bounded:

- **Soft:** the agent is told to stop once there are no Blockers/Should-fix left.
- **Hard:** the relay enforces a **per-PR round cap** (default 3). Once hit, it refuses to run
  reviewers, prints a clear ⛔ STOP message, and **exits `4`** so the agent ends the loop instead of
  mistaking it for a pass. The counter lives in `$XDG_CACHE_HOME/pr-review-relay/`, **auto-resets after
  6h** of inactivity (a fresh session), and can be cleared with `--reset`. Tune with `--max-rounds N` or
  `PR_RELAY_MAX_ROUNDS`.

## 🔍 How it works

1. Resolves the PR (current branch or `--pr`) and reads the diff with `gh pr diff` (used as a sanity
   guard and for the line/byte summary).
2. For each reviewer (except `--author`), runs the agent **headless** with a focused
   review prompt. By default (**`--link`**) the prompt hands the agent the PR reference and tells it to
   fetch the PR itself (`gh pr view`/`gh pr diff`) and read the changed files in context — so it reviews
   the *whole* PR, not just a diff snapshot. The diff is also embedded as a **fallback** so a reviewer
   whose sandbox can't run `gh` (e.g. `codex exec --read-only`) still returns a review — but the fallback
   is **omitted for large diffs** (over `LINK_DIFF_FALLBACK_MAX_BYTES`, default 100000) so an oversized
   inline diff can't exceed an agent's prompt limit and make it silently return empty; those reviewers
   fetch the PR via `gh` instead. With **`--diff`** only the raw diff is sent. A **`--context-file`** is
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
| `0` | Every reviewer that ran produced **and posted** a review, and the PR head didn't move. | Everyone *ran* — not that it's approved. Read the reviews, resolve every Blocker/Should-fix, then merge. |
| `3` | Not a clean round: a reviewer returned empty / timed out / exited non-zero / failed to post, **or** an explicitly-requested reviewer was missing, **or** no reviewer ran, **or** HEAD moved mid-round (reviews now describe stale code). | Fix the cause and re-run; don't treat as reviewed. |
| `4` | Review-round cap reached. | Stop looping; escalate to a human. |
| `1`/`2` | Usage/precondition error (no `gh`, no PR, empty diff, bad arg). | Fix the invocation. |

A missing CLI from the **default** reviewer set is a tolerated skip (users have different agents
installed); only reviewers named explicitly via `--reviewers` are required to be present. Each posted
review's footer records the **reviewed SHA** so you can tell whether a review predates a later push.

> **Note:** reviews are posted as they complete, *before* the end-of-round SHA re-check. So a round that
> ends in `3` (a reviewer failed, or HEAD moved mid-round) may still have left comments on the PR — tagged
> with the SHA they reviewed. Trust the **exit code**, not the mere presence of comments: on `3`, re-run
> and read the fresh round. A round that actually dispatched reviewers **consumes one cap slot even when it
> ends in `3`** (a persistently flaky reviewer must still hit the cap) — a round where *nobody* ran does not.

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

- **⚠️ Only the OpenCode reviewer is enforced read-only.** The others are asked not to modify
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
  - **Claude** — `claude -p` honours permission rules from `settings.json`, and the relay runs inside
    the checkout, so a PR-controlled `.claude/settings.json` can pre-authorise Bash or Write. No
    enforced deny-list is supplied on the command line.
  - **Cursor** — `cursor-agent -p --trust --mode=ask` keeps it in Q&A mode, which is the closest to a
    real constraint of the three, but it is still the agent's own mode rather than an enforced policy.
- **OpenCode is the exception, and it is enforced:** `opencode --pure run` with a primary agent the
  relay defines itself and an inline default-deny policy. `--pure` matters — it stops external plugins,
  which execute at startup regardless of permissions.
- **OpenCode read-only is enforced by config, not by the agent name.** Selecting a built-in agent is *not* a
  sandbox — their permissions are user-configurable, and `agent.plan.mode: "subagent"` in a config makes
  OpenCode fall back to `build` with *that* agent's rules (verified: shell came back). The relay
  therefore defines and selects its own primary agent, whose mode and permissions are both fixed. Each invocation sets
  `OPENCODE_CONFIG_CONTENT` (a runtime override that outranks your own `opencode.json`) to a
  **default-deny** policy — `"*": "deny"` plus an explicit read-only allowlist (`read`, `grep`, `glob`,
  `list`) — repeated on the relay's own agent, because OpenCode applies agent-scoped permissions
  *after* the global ones, so the agent actually in use has to carry the policy too. It also runs with `--pure` so external plugins, which execute at startup, don't load.
  Deliberately **not** run with `--auto`, which would auto-approve every `ask` permission.
- **What the OpenCode policy does NOT stop:** it prevents *execution*, not *reading*. `read`, `grep`,
  `glob` and `list` stay allowed — the reviewer needs them — and they are not confined to the
  attachment. A prompt-injected diff can therefore ask the model to read a file and quote it back in
  the review, which is then posted to the PR. Treat the review output as attacker-influenceable, and
  note that this is not limited to the launch directory: the reviewer can read anything the
  account running it can read, and quote it into a public PR comment.
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

## 📄 License

MIT © Ivan Morgillo
