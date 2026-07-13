<a id="top"></a>

> 🇫🇷 [Version française](../#07_token-optimization.md)

# Token optimization — techniques and savings

_Catalogue of techniques applied in LCARS Fleet to reduce cost per session._

**Core principle**: never touch security directives (shell constraints, edit constraints, handoff locks, builder escalation). Optimization targets passive context, duplications, and verbose behaviors — not safeguards.

**Sections** — [T1](#technique-1) · [T2](#technique-2) · [T3](#technique-3) · [T4](#technique-4) · [T5](#technique-5) · [T6](#technique-6) · [T7](#technique-7) · [T8](#technique-8) · [T9](#technique-9) · [T10](#technique-10) · [T11](#technique-11) · [T12](#technique-12) · [📋 Summary](#recapitulatif)

---

<a id="technique-1"></a>

## Technique 1 🔍 — Role-based handoff filtering (session-startup.sh)

*Injecting only the handoffs relevant to each role eliminates 30 to 50% of startup context.*

**Problem**: session-startup.sh injected all relevant handoffs without role distinction. Dev received inter-builder handoffs. Builders received starfleet-handoff.md.

**Solution**: `case $INSTANCE_NAME` in session-startup.sh → each instance receives only the files that concern it.

**Target matrix**:

| Instance | Its handoff | Receives full | Receives STATE-only | Does not inject |
|---|---|---|---|---|
| dev | dev-handoff | steward-notes, to-dev | builder-handoff (STATE) | to-build, steward-handoff |
| builder | builder-handoff | to-build, steward-notes | — | to-dev, steward-handoff |
| steward | steward-handoff | to-steward, to-build, to-dev | — | steward-notes (it writes it) |
| qualifier | qualifier-handoff | to-qualifier, steward-notes | — | builder handoffs |

**Saving**: 30-50% fewer tokens at startup depending on the instance.

[↑ table of contents](#top)

---

<a id="technique-2"></a>

## Technique 2 📊 — STATE-only for secondary handoffs

*Extracting only the STATE block from secondary handoffs reduces 60-100 lines to 5 lines per file.*

**Problem**: dev receives builder handoffs in full (STATE + ACTIONS + DONE, 60-100 lines) when it mainly needs the status (5 lines STATE).

**Solution**: `inject_state_only()` function in session-startup.sh, extracts only the `## STATE` block via sed. If dev needs the narrative, it reads the file directly.

```bash
inject_state_only() {
    local file="$1" label="$2"
    [ -f "$file" ] || return 0
    echo "=== $label (summary) ==="
    sed -n '/^## STATE$/,/^## /{ /^## STATE$/p; /^## [^S]/!{ /^## STATE$/!p; }; }' "$file"
}
```

**Saving**: 55-95 lines → 5 lines per secondary handoff. For dev receiving the builder handoff: ~400-700 tokens saved.

[↑ table of contents](#top)

---

<a id="technique-3"></a>

## Technique 3 ✂️ — Trimmed ipc-protocol.md

*Removing non-operational implementation content from the `@`-imported file saves ~800 permanent tokens per session.*

**Problem**: `memory/ipc-protocol.md` was imported via `@` in CLAUDE.md (~2.5K tokens). It contained implementation content (diagrams, benchmarks) that is not an operational directive.

**Removed sections**:
- ASCII bare repo workflow diagram (15 lines)
- Benchmark `ext4 is 4-14× faster than 9P` (the rule is sufficient)
- `deploy.sh` section (human doc, already in DIRECTIVES.md)
- Full STATE/ACTIONS/DONE format (kept condensed, detail in `/handoff` command)

**Kept**: reader/writer matrix, session start rules, double-file rule, decommissioning.

**Saving**: ~800 tokens/session permanent.

> [!TIP]
> This pattern applies to any `@`-imported file: audit regularly to remove human documentation sections that are not actionable directives.

[↑ table of contents](#top)

---

<a id="technique-4"></a>

## Technique 4 🏷️ — DIRECTIVES.md no-read tag

*An HTML comment at the top of the file is enough to prevent spontaneous reads that would double the CLAUDE.md context.*

**Problem**: `DIRECTIVES.md` is a human index. Not imported via `@`, but Claude may read it spontaneously, doubling the CLAUDE.md + imports context.

**Solution**: HTML comment at the top:
```markdown
<!-- Human reference only. If CLAUDE.md + @imports are in context, do not read this file — it duplicates their content. -->
```

**Saving**: prevention of a potential ~2K token duplicate.

[↑ table of contents](#top)

---

<a id="technique-5"></a>

## Technique 5 🎭 — Progressive disclosure: conditional sections

*Extracting role-specific sections from CLAUDE.md into dedicated files reduces permanent context by ~550 tokens.*

**Problem**: `home_claude_CLAUDE.md` is loaded in every session of every instance (~3.2K tokens). Some sections are only relevant to certain roles.

**Extracted sections**:

| Section | Destination | Trigger in CLAUDE.md |
|---|---|---|
| Builders — mandatory escalation (~400 tokens) | `memory/builder-rules.md` | `IMPORTANT: read builder-rules.md before any build action` |
| Test table (~150 tokens) | `memory/test-policy.md` | `Test policy in test-policy.md` |
| Bug journal — repo list | Header of bug-journal.md itself | Simplified section |

**Why the `IMPORTANT` trigger**: confirmed empirically (Vercel data: 56% non-invocation without explicit trigger on skills). With `IMPORTANT`, Claude identifies the file as relevant and reads it before starting.

**Saving**: ~550 tokens removed from permanent context. Builders never see the test section, dev never sees the builder escalation rules.

> [!NOTE]
> The `IMPORTANT` trigger is necessary: without it, the referenced file is read in only 44% of cases according to Vercel data on skill invocations.

[↑ table of contents](#top)

---

<a id="technique-6"></a>

## Technique 6 🍴 — context:fork on the cross-arm64 skill

*Running the skill in an isolated subagent prevents its ~800 tokens from accumulating in the main context on each invocation.*

**Problem**: the `cross-arm64` skill (~800 tokens) is injected inline into the main conversation. For builders with repetitive build cycles, this content accumulates in context.

**Solution**: `context: fork` in the skill frontmatter → runs as an isolated subagent. Only the result surfaces back into the main context.

**Condition**: verify that Haiku (builder model) works correctly in isolation — the skill may need more detailed instructions without the parent context.

**Saving**: ~800 tokens recovered in the main context per invocation.

[↑ table of contents](#top)

---

<a id="technique-7"></a>

## Technique 7 🔧 — filter-build-output.sh (hook PreToolUse)

*Filtering cmake output via a PreToolUse hook reduces a clean build from 200+ lines to ~5 lines.*

**Problem**: a clean cmake output produces 200+ lines in context. Only errors and warnings are actionable.

**Solution**: PreToolUse hook that detects build commands (cmake, make, ninja, cargo, pip) and filters output to keep only error/warning lines.

Result: a clean build → ~5 lines instead of 200+. A build with errors → readable errors, without the noise.

**Estimated saving**: 600-800 tokens per build depending on output.

[↑ table of contents](#top)

---

<a id="technique-8"></a>

## Technique 8 🌐 — Per-role env variables

*Reducing the thinking budget and compaction threshold for builders aligns cost with the actual complexity of their tasks.*

**Problem**: builders do not need the same reasoning budget as dev/StarFleet. The default 16K thinking is oversized for diagnosing a build error.

**Solution**: variables in `.bashrc` or `post-install-builder.sh`:

| Variable | dev/StarFleet | builder |
|---|---|---|
| `MAX_THINKING_TOKENS` | 16000 | 8000 |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | 70 | 50 |

8K thinking is sufficient for builder tasks. Compaction at 50%: builds generate ephemeral context, compacting early keeps the budget light for subsequent cycles.

**Estimated saving**: ~70% reduction in thinking tokens on builders.

[↑ table of contents](#top)

---

<a id="technique-9"></a>

## Technique 9 💬 — Conciseness directives (output tokens)

*Output tokens cost 5× input tokens — targeted directives reduce verbosity by ~20%.*

**Cost context**: output tokens cost 5× more than input tokens (Sonnet: $3 input / $15 output per million).

**Directives added** in home_claude_CLAUDE.md:
- `After file edits: state only what changed and why. No recap of unchanged context.`
- `No status reports or session recaps unless explicitly requested. The dashboard covers fleet state.`
- `/compact proactive at 60% capacity` (vs 95% default)

**Estimated saving**: ~20% reduction in verbose responses. Over 50 interactions/session × 200 tokens: ~2000 output tokens saved.

> [!IMPORTANT]
> Output tokens (Sonnet $15/M) cost 5× input tokens ($3/M). Optimizing output tokens has a stronger economic impact than optimizing input context.

[↑ table of contents](#top)

---

<a id="technique-10"></a>

## Technique 10 📦 — Read-cache rule

*Reformulating the "always read before writing" directive to skip re-reads when content is already in context and unmodified.*

**Problem**: the "always read before writing" directive caused systematic re-reads even when the content was already in context and up to date.

**Reformulated directive**:

> Read is not required if the content is already in context (via Read tool) AND no tool or bash command has modified the file since that Read.

**Cache invalidation**:
- Write tool modified the file
- Bash command may have modified the file (sed, echo >, patch...)
- Another agent may have modified the file (files in `/home/commons/`: always re-Read)
- Conversation compacted (context loss)

**Special case**: consecutive Edits on the same file — the initial Read is valid for the entire series as long as no invalidating event occurs between Edits.

**Estimated saving**: 1500-8000 tokens/session on intensive development sessions (20+ file modifications).

[↑ table of contents](#top)

---

<a id="technique-11"></a>

## Technique 11 📢 — fleet-notify.sh (STATE notification)

*Replacing Edit tool with a shell script for `notify:` field updates reduces cost per notification by a factor of 7×.*

**Problem**: updating the `notify:` field in a handoff file via Edit tool costs ~100 tokens (Read + Edit).

**Solution**: `fleet-notify.sh <instance> <target>` — shell script that does the sed directly.

**Saving**: 100 → 15 tokens, factor 7×. On frequent IPC flows (ACK, state transitions), significant savings over long sessions.

[↑ table of contents](#top)

---

<a id="technique-12"></a>

## Technique 12 🤖 — Per-role model + auto-reset at launch

*Encoding the model matrix in deploy.sh and calling it at fleet-launch guarantees automatic reset without operational friction.*

**Problem**: engineer may be manually switched to Opus for an intensive session. If forgotten, the next session starts on Opus — 3× cost without justification.

**Solution**: model matrix encoded in `deploy.sh --update-models`, called automatically by `fleet-launch.sh` at each fresh launch.

```
builder / qualifier   → claude-haiku-4-5-20251001   (repetitive tasks, low judgment)
dev / starfleet / engineer → claude-sonnet-4-6   (coordination, code, architecture)
```

**Implementation**:
- `post-install-<role>.sh`: sets the model in `settings.local.json` at provisioning
- `deploy.sh --update-models`: idempotent patch of `settings.local.json` for all active instances
- `fleet-launch.sh`: calls `deploy.sh --update-models` before opening tmux windows

**Behavior**:
- `fleet-launch.sh` only runs at fresh launch (`tmux has-session` guard at the top of the script)
- Opus escalation: manual (`/model` in the engineer session), reset guaranteed at next `fleet-launch`
- Full deploy.sh remains a manual engineer command — only `--update-models` is automated

**Saving**: prevention of cost drift (Opus ≈ 3× Sonnet) without operational friction.

[↑ table of contents](#top)

---

<a id="recapitulatif"></a>

## Summary 📋

*Consolidated view of all techniques, their saving type, order of magnitude, and survival across a WSL rebuild.*

| Technique | Saving type | Estimated saving | Rebuild-safe |
|---|---|---|---|
| 1. Role-based filtering | Startup context | 30-50% tokens startup | ✅ repo |
| 2. STATE-only secondary handoffs | Startup context | 400-700 tokens/session | ✅ repo |
| 3. Trimmed ipc-protocol.md | Permanent context | ~800 tokens/session | ✅ repo |
| 4. DIRECTIVES.md no-read | Passive context | ~2K tokens (prevention) | ✅ repo |
| 5. Progressive disclosure | Permanent context | ~550 tokens/session | ✅ repo |
| 6. context:fork skill | Per invocation | ~800 tokens/invocation | ✅ repo |
| 7. filter-build-output.sh | Per build | 600-800 tokens/build | ✅ repo + post-install |
| 8. Per-role env variables | Thinking budget | ~70% builders | ✅ post-install |
| 9. Conciseness directives | Output tokens | ~20% output | ✅ repo |
| 10. Read-cache rule | Unnecessary re-reads | 1500-8000 tokens/session | ✅ repo |
| 11. fleet-notify.sh | IPC STATE updates | 7× per notification | ✅ repo |
| 12. Per-role model + auto-reset | Opus cost drift | 3× prevention | ✅ repo + post-install |

**Absolute constraint**: all these techniques are Rebuild-safe — they survive `wsl --unregister` + `Instanciator.ps1` because they live in the repo or in post-install scripts.

[↑ table of contents](#top)
