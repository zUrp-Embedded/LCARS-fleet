---
name: push-github
context: fork
description: >
  Pre-push automation for LCARS: update header stardates on modified
  scripts, check README relevance, then push to GitHub.
  Run before any git push on LCARS repository.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Glob
  - Grep
when_to_use: >
  Use before any git push on the LCARS repository. Updates stardates on
  modified scripts, checks README relevance, then pushes.
  Examples: '/push-github', 'push LCARS', 'push to github'.
---

# /push-github

Pre-push automation for LCARS. Run from repo root (`/local/LCARS/`).

## Step 0 — Danger assessment

Classify **unpushed** changes to determine if validation is required before push.

```bash
# Scope: unpushed commits + staged changes only — NOT working tree
git log origin/main..HEAD --name-only --format=""   # committed, not pushed
git diff --cached --name-only                        # staged, not yet committed
```

Score rules (first match wins):

| Pattern | Danger | Action |
|---------|--------|--------|
| `.claude/hooks/*.sh` | HIGH | QA obligatoire — send procedure via spool, **STOP** |
| `.claude/skills/*/SKILL.md` (new or behavioral change) | HIGH | QA obligatoire — **STOP** |
| `.claude/CLAUDE*.md` | ARCH | Architect validates directly. Read diff, confirm no behavioral regression, then continue. |
| `.claude/skills/*/SKILL.md` (doc/header only) | LOW | skip QA |
| `fleet/*.py` or `fleet/*.sh` | LOW | skip QA |
| `docs/`, `assets/`, header/date only | LOW | skip QA |

**If HIGH (QA_REQUIRED) — check existing ACK first:**

Check spool inbox for a `[qualifier] PASS` message mentioning the HIGH files.
An ACK is **valid** if:
- it contains `PASS` and names the hook/skill files found in the HIGH list
- its ref commit is ≥ the last commit touching those files (`git log --oneline -- <file>` first line)

If valid ACK found → log one line "QA ACK confirmed (ref …) — skipping QA gate" → continue to Step 1.

**If no valid ACK — ⛔ STOP EXECUTION NOW:**
1. `fleet-send.sh qualifier "QA required: <files list> — test procedure: <description>"`
2. **Do not proceed to Step 1.** Return to user. Resume only after ACK in spool inbox.

**If ARCH (engineer validates):** read the diff, confirm no behavioral regression, then continue to Step 1.

**If LOW or no match:** continue to Step 1.

## Step 1 — Identify what will be pushed

```bash
git log --oneline origin/main..HEAD    # commits pending push
git diff origin/main --name-only       # files changed vs remote
```

## Step 2 — Check README relevance

Note: STARDATE updates are handled automatically by the pre-commit hook.
No manual stardate step needed.

Inspect the diff for changes that should be reflected in `README.md`.

**Update README if:**
- New script added or removed in `fleet/` or `toolbox/`
- New instance type, IPC channel, or tmux window added
- New skill or command added to `.claude/`
- Provisioning workflow changed significantly

**Do NOT update README for:**
- Bug fixes in existing scripts (user-facing behavior unchanged)
- Header/date-only changes
- Internal changes in `docs/`
- Mechanical `deploy.sh` fixes

If update needed: make the targeted edit, then `git add README.md`.

## Step 3 — Commit pre-push changes (if any)

If Step 2 produced staged changes (README update), commit before pushing:

```bash
git commit -m "$(cat <<'EOF'
chore(pre-push): update README

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

If nothing changed: skip.

## Step 4 — Push

```bash
git push
```

⚠️ **Règles strictes :**
- Push la branche courante uniquement (`git push`, jamais `git push origin <autre-branche>`)
- **Jamais de merge automatique** (pas de `git merge`, `git rebase --onto`, `git pull --merge`)
- Si non sur `main` : push la branche, ne pas merger sur main — mentionner la branche dans le rapport
- Si `git push` est rejeté (non-fast-forward) : STOP, signaler à architect, ne pas forcer

Report the push result and list of commits pushed.
