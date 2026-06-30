# pr-review-relay

![header](assets/header.png)

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/shell-bash-89e051?logo=gnu-bash&logoColor=white)](pr-review-relay)
[![Works with Claude](https://img.shields.io/badge/works%20with-Claude%20Code-blueviolet?logo=anthropic&logoColor=white)](https://docs.anthropic.com/en/docs/claude-code)
[![Works with Codex](https://img.shields.io/badge/works%20with-Codex%20CLI-green?logo=openai&logoColor=white)](https://github.com/openai/codex)
[![Works with Cursor](https://img.shields.io/badge/works%20with-Cursor-0098FF?logo=cursor&logoColor=white)](https://cursor.com)
[![Works with Antigravity](https://img.shields.io/badge/works%20with-Antigravity-orange)](https://antigravity.dev)

**Hand a pull request off to your *other* AI coding agents for an automated cross-review.**

</div>

---

You build a feature with one agent (Claude Code, Codex, Cursor, or Antigravity), it opens a PR — and the
**others** automatically review that PR, headless and read-only, and post their findings as
PR comments. Local, free (it uses the agent CLIs you already pay for), and idempotent.

```
 build feature  ──►  open PR  ──►  pr-review-relay --author <self>
                                         │
         ┌───────────────────────────────┼───────────────────────────────┐
         ▼                               ▼                               ▼
   claude -p                       codex exec                      cursor-agent -p
   agy -p                                                                │
         └───────────────────────────────┴───────────────────────────────┘
                                         │
                              each posts its review as a PR comment
```

No SaaS, no per-seat review bot, no extra subscription — just the CLIs on your machine.

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
  - 🟠 [`agy`](https://antigravity.dev) (Antigravity CLI) — uses `agy -p`

You only need the agents you actually want as reviewers.

## ⚡ Install

```bash
curl -fsSL https://raw.githubusercontent.com/hamen/pr-review-relay/main/pr-review-relay \
  -o ~/.local/bin/pr-review-relay
chmod +x ~/.local/bin/pr-review-relay
# make sure ~/.local/bin is on your PATH
```

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
| `--reviewers a,b,c` | Which agents review. Default: `claude,codex,cursor,antigravity`. |
| `--context-file <path>` | Prepend a document (docs, spec, API reference) to every reviewer's prompt — they read it and verify the PR against it. Great for "check this against the official docs". |
| `--link` *(default)* | Hand reviewers the PR reference; each fetches it itself (`gh pr view`/`gh pr diff`) and reads the full files in context. |
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
> After you open a Pull Request, run `pr-review-relay --author antigravity`.

Now whoever opens the PR, the others review it — no manual step.

## 🔄 Closing the loop: read the reviews and iterate

The relay runs the reviewers **synchronously** and **prints every review to stdout** (in addition to
posting them as PR comments). So the agent that launched the relay gets the full feedback back **in
its own command output** — it can analyze the findings, fix them, push, and re-run. Because the relay
is idempotent, re-running just refreshes the comments (one per agent).

A typical agent instruction to make this a loop:

> After opening a PR, run `pr-review-relay --author <self>`. Read the reviews it prints, address every
> **Blocker** and **Should-fix**, commit and push, then run it again. Repeat until no blockers remain
> (max ~3 rounds), then summarize what you changed.

Need to re-read the latest reviews later (e.g. a slower reviewer landed after you moved on)? Use the
companion command:

```bash
pr-review-fetch         # prints the cross-review comments for the current branch's PR
pr-review-fetch 47      # …for a specific PR
```

## 🛡️ Loop safety (no runaway iteration)

Telling an agent to "fix and re-run" can spiral. Two layers keep it bounded:

- **Soft:** the agent is told to stop once there are no Blockers/Should-fix left.
- **Hard:** the relay enforces a **per-PR round cap** (default 3). Once hit, it refuses to run
  reviewers and prints a clear ⛔ STOP message, so the agent ends the loop. The counter lives in
  `$XDG_CACHE_HOME/pr-review-relay/`, **auto-resets after 6h** of inactivity (a fresh session), and
  can be cleared with `--reset`. Tune with `--max-rounds N` or `PR_RELAY_MAX_ROUNDS`.

## 🔍 How it works

1. Resolves the PR (current branch or `--pr`) and reads the diff with `gh pr diff` (used as a sanity
   guard and for the line/byte summary).
2. For each reviewer (except `--author`), runs the agent **headless and read-only** with a focused
   review prompt. By default (**`--link`**) the prompt hands the agent the PR reference and tells it to
   fetch the PR itself (`gh pr view`/`gh pr diff`) and read the changed files in context — so it reviews
   the *whole* PR, not just a diff snapshot. With **`--diff`** the raw diff is piped instead. A
   **`--context-file`** is prepended to the prompt so every reviewer reads and verifies against it.
3. Posts each review as a PR comment via `gh pr comment`, tagged per agent (🟣 Claude / 🟢 Codex /
   🔵 Cursor / 🟠 Antigravity).
4. **Idempotent:** before posting, it deletes any previous review from the *same* agent on that PR,
   so re-runs replace rather than duplicate — one current review per agent.

## 📋 Notes & caveats

- **Read-only:** reviewers never modify code. They run with `codex exec -s read-only`,
  `claude -p` (no auto-approve), `cursor-agent -p --trust --mode=ask` (trust the workspace to read it, but
  keep the agent in Q&A/read-only mode), and `agy --dangerously-skip-permissions -p` (skips interactive
  permission prompts; the prompt itself is read-only).
- **Cursor needs `--trust`** in headless mode or it blocks on a workspace-trust prompt — handled.
- **Cursor is slower/chattier** than Codex; its comment may land a bit later.
- **Link mode is the default:** each reviewer fetches the PR itself and reads the changed files in
  context — deeper than a diff snapshot. Pass `--diff` for the older diff-on-stdin behaviour (faster,
  but the agent only sees the diff unless it opens files). Either way the agent runs in the repo.
- **Verify against sources** with `--context-file <path>`: the document is prepended to every
  reviewer's prompt, so they cross-check the PR against e.g. an official spec or API reference instead
  of relying on memory. The reviewer comment is footnoted with the context file's name.
- Runs on your machine, so it works when your machine is on. It's a local relay, not a hosted bot.

## 📄 License

MIT © Ivan Morgillo
