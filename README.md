# pr-review-relay

**Hand a pull request off to your *other* AI coding agents for an automated cross-review.**

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

## Why

AI agents are great at *writing* code and decent at *reviewing* it — but a second (and third)
independent pair of eyes catches more. Most "AI PR review" products are paid add-ons. If you
already use Claude Code, Codex CLI and/or Cursor CLI, you can get the same cross-review for free:
let whoever opened the PR delegate the review to the others.

## Requirements

- [`gh`](https://cli.github.com/) (GitHub CLI), authenticated (`gh auth login`).
- Any subset of these agent CLIs, logged in:
  - [`claude`](https://docs.anthropic.com/en/docs/claude-code) (Claude Code) — uses `claude -p`
  - [`codex`](https://github.com/openai/codex) (OpenAI Codex CLI) — uses `codex exec`
  - [`cursor-agent`](https://docs.cursor.com/) (Cursor CLI) — uses `cursor-agent -p`

You only need the agents you actually want as reviewers.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/hamen/pr-review-relay/main/pr-review-relay \
  -o ~/.local/bin/pr-review-relay
chmod +x ~/.local/bin/pr-review-relay
# make sure ~/.local/bin is on your PATH
```

## Usage

Run it from inside the repo (it resolves the PR for the current branch):

```bash
pr-review-relay --author claude            # claude opened the PR → codex + cursor review
pr-review-relay --pr 47 --parallel         # explicit PR, reviewers run concurrently
pr-review-relay --pr 47 --reviewers codex  # only one reviewer
pr-review-relay --dry-run                  # show what it would do, run no agents
```

Flags:

| Flag | Meaning |
|------|---------|
| `--author <name>` | The agent that opened the PR. It auto-excludes itself from reviewing. |
| `--pr <number\|url>` | Target PR. Defaults to the PR for the current branch. |
| `--reviewers a,b,c` | Which agents review. Default: `claude,codex,cursor`. |
| `--parallel` | Run the reviewers concurrently. |
| `--dry-run` | Resolve the PR + diff and list reviewers, without invoking agents or posting. |

## Make it automatic (the handoff)

Tell each agent to call the relay right after it opens a PR. Add a line to each agent's
instructions file (these are global, so they apply in every repo):

**Claude Code** — `~/.claude/CLAUDE.md`:
> When you open a Pull Request, run `pr-review-relay --author claude`.

**Codex** — `~/.codex/AGENTS.md`:
> After you open a Pull Request, run `pr-review-relay --author codex`.

**Cursor** — `~/.cursor/AGENTS.md`:
> After you open a Pull Request, run `pr-review-relay --author cursor`.

Now whoever opens the PR, the other two review it — no manual step.

## How it works

1. Resolves the PR (current branch or `--pr`) and fetches the diff with `gh pr diff`.
2. For each reviewer (except `--author`), runs the agent **headless and read-only**, feeding it the
   diff plus a focused review prompt. The agent runs in the repo, so it can read files for context.
3. Posts each review as a PR comment via `gh pr comment`, tagged per agent (🟣 Claude / 🟢 Codex /
   🔵 Cursor).
4. **Idempotent:** before posting, it deletes any previous review from the *same* agent on that PR,
   so re-runs replace rather than duplicate — one current review per agent.

## Notes & caveats

- **Read-only:** reviewers never modify code. They run with `codex exec -s read-only`,
  `claude -p` (no auto-approve), and `cursor-agent -p --trust` (trust the workspace to read it, but
  not run-everything).
- **Cursor needs `--trust`** in headless mode or it blocks on a workspace-trust prompt — handled.
- **Cursor is slower/chattier** than Codex; its comment may land a bit later.
- Reviews are **diff-centric** (the agent gets the diff and can read repo files). For deeper context
  you can `gh pr checkout` the PR branch before running.
- Runs on your machine, so it works when your machine is on. It's a local relay, not a hosted bot.

## License

MIT © Ivan Morgillo
