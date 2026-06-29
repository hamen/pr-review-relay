# pr-review-relay

![header](assets/header.png)

<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Shell Script](https://img.shields.io/badge/shell-bash-89e051?logo=gnu-bash&logoColor=white)](pr-review-relay)
[![Works with Claude](https://img.shields.io/badge/works%20with-Claude%20Code-blueviolet?logo=anthropic&logoColor=white)](https://docs.anthropic.com/en/docs/claude-code)
[![Works with Codex](https://img.shields.io/badge/works%20with-Codex%20CLI-green?logo=openai&logoColor=white)](https://github.com/openai/codex)
[![Works with Cursor](https://img.shields.io/badge/works%20with-Cursor-0098FF?logo=cursor&logoColor=white)](https://cursor.com)

**Hand a pull request off to your *other* AI coding agents for an automated cross-review.**

</div>

---

You build a feature with one agent (Claude Code, Codex, or Cursor), it opens a PR — and the
**other two** automatically review that PR, headless and read-only, and post their findings as
PR comments. Local, free (it uses the agent CLIs you already pay for), and idempotent.

```
 build feature  ──►  open PR  ──►  pr-review-relay --author <self>
                                         │
                 ┌───────────────────────┴───────────────────────┐
                 ▼                                                 ▼
   the OTHER agents review it (headless, read-only)     each posts its review
   claude -p  /  codex exec  /  cursor-agent -p   ───►   as a comment on the PR
```

No SaaS, no per-seat review bot, no extra subscription — just the CLIs on your machine.

## 🤔 Why

AI agents are great at *writing* code and decent at *reviewing* it — but a second (and third)
independent pair of eyes catches more. Most "AI PR review" products are paid add-ons. If you
already use Claude Code, Codex CLI and/or Cursor CLI, you can get the same cross-review for free:
let whoever opened the PR delegate the review to the others.

## 📦 Requirements

- [`gh`](https://cli.github.com/) (GitHub CLI), authenticated (`gh auth login`).
- Any subset of these agent CLIs, logged in:
  - 🟣 [`claude`](https://docs.anthropic.com/en/docs/claude-code) (Claude Code) — uses `claude -p`
  - 🟢 [`codex`](https://github.com/openai/codex) (OpenAI Codex CLI) — uses `codex exec`
  - 🔵 [`cursor-agent`](https://docs.cursor.com/) (Cursor CLI) — uses `cursor-agent -p`

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
pr-review-relay --author claude            # claude opened the PR → codex + cursor review
pr-review-relay --pr 47 --parallel         # explicit PR, reviewers run concurrently
pr-review-relay --pr 47 --reviewers codex  # only one reviewer
pr-review-relay --dry-run                  # show what it would do, run no agents
pr-review-relay --mode google-style \
  --kb-path ~/code/dac-audit-skill/knowledge --author claude --parallel
```

Flags:

| Flag | Meaning |
|------|---------|
| `--author <name>` | The agent that opened the PR. It auto-excludes itself from reviewing. |
| `--pr <number\|url>` | Target PR. Defaults to the PR for the current branch. |
| `--reviewers a,b,c` | Which agents review. Default: `claude,codex,cursor`. |
| `--parallel` | Run the reviewers concurrently. |
| `--dry-run` | Resolve the PR + diff and list reviewers, without invoking agents or posting. |
| `--mode code\|google-style` | `code` = bugs/security (default). `google-style` = doc prose vs [dac-audit-skill](https://github.com/hamen/dac-audit-skill) knowledge base. |
| `--kb-path <dir>` | Knowledge root (`manifest.json` inside). Required for `google-style` unless `DAC_KB_PATH` is set. |
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

Now whoever opens the PR, the other two review it — no manual step.

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

1. Resolves the PR (current branch or `--pr`) and fetches the diff with `gh pr diff`.
2. For each reviewer (except `--author`), runs the agent **headless and read-only**, feeding it the
   diff plus a focused review prompt. The agent runs in the repo, so it can read files for context.
3. Posts each review as a PR comment via `gh pr comment`, tagged per agent (🟣 Claude / 🟢 Codex /
   🔵 Cursor).
4. **Idempotent:** before posting, it deletes any previous review from the *same* agent on that PR,
   so re-runs replace rather than duplicate — one current review per agent.

## 📋 Notes & caveats

- **Read-only:** reviewers never modify code. They run with `codex exec -s read-only`,
  `claude -p` (no auto-approve), and `cursor-agent -p --trust --mode=ask` (trust the workspace to read it, but
  keep the agent in Q&A/read-only mode).
- **Cursor needs `--trust`** in headless mode or it blocks on a workspace-trust prompt — handled.
- **Cursor is slower/chattier** than Codex; its comment may land a bit later.
- Reviews are **diff-centric** (the agent gets the diff and can read repo files). For deeper context
  you can `gh pr checkout` the PR branch before running.
- Runs on your machine, so it works when your machine is on. It's a local relay, not a hosted bot.

## 📄 License

MIT © Ivan Morgillo
