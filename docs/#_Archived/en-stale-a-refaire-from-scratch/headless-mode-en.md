# Claude Code — Headless Mode

_Source: notes_en_vrac.md — extracted 2026-03-08_

## Principle

The `-p` (or `--print`) flag is the entry point. It launches Claude Code in non-interactive mode, outputs the response to stdout, then terminates the process. Anthropic historically called this "headless mode" — the term persists in the docs but the flag remains `-p`.

---

## What works

### Output formats

`--output-format` accepts three values:
- `text` — default
- `json` — structured object with metadata
- `stream-json` — newline-delimited JSON for real-time streaming

### Unix pipes

The `-p` flag accepts context via stdin. In practice, this combination with Unix pipes covers 80% of headless use cases.

```bash
cat src/utils.ts | claude -p "Add missing TypeScript types"
git diff HEAD~1 | claude -p "Review this diff"
```

### Multi-turn sessions

Session IDs allow chaining multiple `claude -p` invocations while preserving conversational context. Sessions retain approximately 200,000 tokens of context.

```bash
session_id=$(claude -p "Analyse the architecture" --output-format json | jq -r '.session_id')
claude -p "Now generate the tests" --resume "$session_id"
```

### Tool control

The `--allowedTools` flag uses permission rules syntax. The `*` suffix activates prefix matching: `Bash(git diff *)` allows everything starting with `git diff`. The space before `*` matters — without it, `Bash(git diff*)` would also match `git diff-index`.

```bash
claude -p "Commit staged changes" \
  --allowedTools "Bash(git diff *),Bash(git log *),Bash(git status *),Bash(git commit *)"
```

---

## Limitations

**Permissions blocking by default**
The default permission system blocks 100% of write operations in headless mode without explicit configuration. Always declare each allowed tool explicitly with `--allowedTools`.

**Slash commands unavailable**
User-invoked skills like `/commit` and built-in commands are only available in interactive mode. In `-p` mode, describe the task directly in the prompt.

**Ephemeral sessions**
Headless sessions have a default lifetime of 15 minutes. Beyond that, the `session_id` expires.

**Incomplete planning mode**
When combining `--permission-mode plan` with `-p`, the CLI still requests user confirmation before acting — which blocks automated workflows. Documented open bug/limitation on the repo.

---

## Shell limits

### Full permission bypass

`--dangerously-skip-permissions` bypasses all permission checks unconditionally. Use only in fully isolated environments (containers, VMs). Documented bug: `--allowedTools` may be ignored in bypass mode — `--disallowedTools` works correctly in all modes.

```bash
# Git checkpoint first
git add -A && git commit -m "Checkpoint pre-Claude"
# YOLO mode
claude --dangerously-skip-permissions -p "Refactor all src/"
# Rollback if needed
git reset --hard HEAD
```

### Parallelisation

Multiple Claude Code instances can run simultaneously. Claude Code can also launch sub-instances (Tasks) of itself.

```bash
find src -name "*.py" | parallel -j 4 \
  claude -p "Optimize this code" --allowedTools "Read" < {}
```

### Cost control

`--max-turns` of 1 to 3 is sufficient for the majority of simple tasks. Multi-turn sessions increase token consumption by 30 to 50% per additional turn.

---

## Flags recap

| Flag | Usage |
|------|-------|
| `-p "prompt"` | Non-interactive mode |
| `--output-format json` | Parse with `jq -r '.result'` |
| `--output-format stream-json` | Real-time streaming |
| `--allowedTools "Read,Write,Bash(git *)"` | Tool whitelist |
| `--disallowedTools "Bash(rm:*)"` | Blacklist — reliable even in bypass |
| `--max-turns N` | Cap on agent iterations |
| `--resume $session_id` | Continue an existing session |
| `--append-system-prompt "..."` | Inject instructions without overwriting default prompt |
| `--dangerously-skip-permissions` | YOLO mode — containers only |
| `--no-user-prompt` | Prevent any confirmation request |

---

## Recommended IPC pattern (LCARS-fleet)

For a tmux orchestrator with handoff file-based IPC, the cleanest pattern:

```bash
claude -p "$prompt" \
  --output-format stream-json \
  --allowedTools "Read,Write,Bash(make *),Bash(git *)" \
  --max-turns 10 \
  | jq -r 'select(.type=="result") | .result' \
  > handoff/agent-output.txt
```

---

## Bridge Claude Web ↔ Claude Code

> [!WARNING]
> Section à vérifier avant implémentation — source mars 2026, non confirmé indépendamment.

### Claude Code → Web (claude.ai)

From Claude Code CLI, the `--remote` flag creates a web session on claude.ai. The task runs in the cloud while you continue working locally. You can then open the session on claude.ai or the mobile app to interact directly.

```bash
claude --remote "Your task here"
```

Track progress:

```bash
/tasks
```

### Web → Local (teleport)

Claude Code for Web (available at `claude.ai/code`) includes a **"teleport"** feature that copies both the chat transcript and edited files to your local Claude Code CLI if you want to resume locally.

### Recommended pattern

**Plan locally, execute remotely:**

1. Start Claude in plan mode to collaborate on the approach
2. Claude can only read files and explore the codebase in plan mode
3. Once satisfied with the plan, launch a remote session for autonomous execution

```bash
# Local plan mode
claude --plan

# Remote execution
claude --remote "Implement the validated plan"
```

### Parallelisation

Each `--remote` command creates its own independent web session. You can launch multiple tasks simultaneously in separate sessions.

```bash
claude --remote "Task A"
claude --remote "Task B"
claude --remote "Task C"
```

### LCARS-fleet use case

The `--remote` bridge allows offloading certain agents to the cloud while keeping local tmux orchestration — heavy agents (Architect, Dev) run remotely, StarFleet stays local for file-based IPC.
