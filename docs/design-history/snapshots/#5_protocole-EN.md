# User Protocol — Keyword Reference

**Date** : 2026-03-10
**Dernière révision** : 2026-03-10
**Statut** : template onboarding (EN) — full rewrite from #4_protocole.md
**Référencé par** : #4_protocole.md
**Dérivé de** : #4_protocole.md (FR, source of truth)

> [!NOTE] **VALIDATED 2026-03-10 — full rewrite from updated source. Triplets restructured, `audit`/`inspect` added, `deep-scan` replaces old `audit` (repo), `elaborate` added to Clarification, `x/10` excluded from closing gate.**

## Protocol rules — read first

**This file is a translation.** It is derived from `#4_protocole.md` (FR, sole source of truth). All translations are by design derived from the FR canonical version. deploy.sh injects the protocol matching `fleet.lang` from `fleet.yaml` — FR by default, translated variants from `directives/protocole-lang/`.

**Nothing is implicit.** Every keyword, every behavior, every nuance is explicitly documented. An undocumented behavior does not exist — it is not "obvious", it is absent. The agent does not infer intended behavior. The user does not assume the agent understands implicit intent. See founding principle in `glossaire-systeme.md`.

**Exclusive channel for user keywords**: every user↔agent keyword MUST be defined in this file (or its HR equivalent) AND in the MR injected file. Defining a keyword elsewhere without registering it here is a GO-0 violation — the keyword does not exist for the interactive agent.

**This file is NOT customizable.** No keyword defined here may be modified, renamed, or substituted — by user or agent. The only customization concerns two session control keywords, defined in a separate file: `#4-1_protocole-user.md`. This file is the interaction contract, not a template to be tweaked.

**Customization — onboarding only, strict scope:**
Only session control keywords are customizable, once, at onboarding:
- `resume` — session resume (replace with any arbitrary token)
- `end-session` — session close (replace with any arbitrary token)

All other keywords are fixed. No substitution is tolerated, even if another term feels "more natural".

**Evolution — append-only:**
Once personalized, the user's protocol file is never modified. It grows only by appending to existing sections or adding new sections. Single exception: confirmed bug-fix, explicitly documented with date and reason above the correction. Disagreement with an existing keyword does not justify modification — it justifies a documented bug-fix or an architecture discussion.

**Execution rule**: if the agent has expressed a clear preference and the operator confirms without restriction, the agent executes immediately without prompting again.

**Non-interpretation rule**: a keyword in backticks (`` `go` ``) is a reference, not a command. Quoted keywords (`"..."`) — behavior undefined, not guaranteed. Use backticks to cite keywords safely.

**Conflict resolution**: multiple active keywords in one message are processed sequentially in order of appearance. If two keywords produce contradictory effects on the same target, the last one wins. Separated by `===`: fully independent blocks — no cross-effects.

**Modifier on compound keywords**: a modifier applies to the full compound keyword as a unit. `dry-minor update` = simulate `minor update` (reduced scope + no side effect). The modifier attaches to the first token; the compound is parsed as a unit.

**Protocol error**: if the agent detects an inconsistency (contradictory keywords on the same token, undocumented behavior requested): signal in one line, ask for disambiguation before acting. Do not self-resolve.

**HR → MR derivation**: see `#3_system-conventions.md § dérivation HR → MR`.

---

## Session Control

The first two keywords are customizable (see `#4-1_protocole-user.md` for active values). All others are fixed.

| Keyword | Behavior | Customizable |
|---|---|---|
| *(session resume)* | Read handoff, resume without recap or questions | yes — see `#4-1_protocole-user.md` |
| *(session close)* | Clean session close via skill `/handoff`. Case-insensitive. | yes — see `#4-1_protocole-user.md` |
| `quiet` | Reduce output to one line per action — session scope — resets at session end | no |
| `verbose` | Show intermediate reasoning for each action — session scope — resets at session end | no |

---

## Analysis keywords — read-only

Column `lvl.` — output granularity: ⚡ = short/inline · 📋 = structured · 🔭 = broad exploration · — = not scalable.
Grammar: each thematic domain forms a triplet ⚡ · 📋 · 🔭. Keywords shared across groups repeat their full definition at each occurrence.
**MR rule**: see `#3_system-conventions.md § dérivation HR → MR`.

### Evaluation

| lvl. | Keyword | Context | Behavior | Nuance | Expected output |
|---|---|---|---|---|---|
| ⚡ | `opinion` | Design or architecture decision | Short opinion + justification | `opinion?` end of sentence → last sentence only · `evaluate` → full prompt | Short inline text |
| 📋 | `evaluate` | Artifact or input | Structured assessment: strengths · gaps · corrections | Targets semantics/content · no source cross-check · `qualify` = form | Structured sections |
| 🔭 | `analyze` | File or subject to explore | Deep exploration: implications · gaps · dependencies | Reads sources by default · without reading = zero value · exception: doc-as-object | Long report |

### Clarification

| lvl. | Keyword | Context | Behavior | Nuance | Expected output |
|---|---|---|---|---|---|
| ⚡ | `clarify` | Point to clarify | Clarify directly — not an action | One point in current thread · `elaborate` = developed · `explain` = full object | Direct inline response |
| 📋 | `elaborate` | Targeted point or proposal | Develop and detail the targeted point | Free position in sentence · `clarify` = short clarification · `explain` = full object | Developed inline response |
| 🔭 | `explain` | Module, architecture, concept, code | Pedagogical explanation at variable depth | 1 = overview · 2 = structured + examples · 3 = deep dive · `clarify` = one point · `elaborate` = developed | Structured text, variable depth |

### Research

| lvl. | Keyword | Context | Behavior | Nuance | Expected output |
|---|---|---|---|---|---|
| ⚡ | `summary` | Current context or provided document | Condensed summary in a few lines — no web search | From context only · `tldr` = web search | Inline summary |
| 📋 | `tldr` | Subject or query to research | Web search + inline condensed brief | Queries the web, not current context · `analyze` = internal exploration | Inline brief + sources |
| 🔭 | *(Claude web)* | Deep research | Out of protocol scope — delegated to Claude web | No protocol keyword at this level | — |

### Code

| lvl. | Keyword | Context | Behavior | Nuance | Expected output |
|---|---|---|---|---|---|
| ⚡ | `opinion` | Design or architecture decision | Short opinion + justification | identical to Evaluation | Short inline text |
| 📋 | `review` | Source code (file, function, module) | Code analysis: correctness · security · performance · patterns · debt | Executable code only · reads code by default · `evaluate` = textual artifact | Structured sections |
| 🔭 | `audit` | Directory or set of code files | Systematic file-by-file audit · incremental report written BEFORE each new Read | `analyze` = free exploration · `audit` = systematic with written checkpoint · proposes fixes | Exhaustive report structured by file |

### Verification

| lvl. | Keyword | Context | Behavior | Nuance | Expected output |
|---|---|---|---|---|---|
| ⚡ | `valid?` | Formulation or proposition | Confirm or correct — never triggers an action | Pure checkpoint · secondary occurrence — canonical definition in Meta-conversation | Inline confirmation |
| 📋 | `check` | Target file(s) + list of corrections | Compare current state vs list · validate each point | Binary verification · `evaluate` = explores content · `analyze` = explores implications | Status per point (✅/❌/⚠️) |
| 🔭 | `inspect` | System, directory, or set of files | Exhaustive methodical verification — conformity, coherence, references | `check` = known list · `inspect` = open exploration without predefined checklist · `audit` = code specifically | Exhaustive structured report |

### External audit

| lvl. | Keyword | Context | Behavior | Nuance | Expected output |
|---|---|---|---|---|---|
| ⚡ | `opinion` | Design or architecture decision | Short opinion + justification | identical to Evaluation | Short inline text |
| 📋 | `qualify` | Document or file | Formal quality assessment + explicit verdict | Targets form/quality · no source cross-check · `evaluate` = content | Structured sections + verdict |
| 🔭 | `deep-scan` | Online repository | See dedicated section | Always both outputs · one only requested = `analyze`, not `deep-scan` | brief.md + insight.md + condensed brief |

### Standalone

| lvl. | Keyword | Context | Behavior | Nuance | Expected output |
|---|---|---|---|---|---|
| — | `x/10` | Proposal or feature | Score 0→10 + 2 lines explanation | 0 = trivial · 10 = critical · fast signal, not an analysis | Score + 2 lines inline |

### Closing gate — cross-cutting rule

Every decisional analysis output (`opinion`, `evaluate`, `qualify`, `analyze`, `audit`, `review`, `check`, `inspect`) ends with: **score x/10 + one routing question** (`backlog?`, `now?`, `nope?`, or context-appropriate variant). The agent proposes, the user routes in one word.

**Exclusions**: `summary`, `clarify`, `elaborate`, `explain`, `tldr`, `x/10` — purely informational outputs or fast signal, no decision point.

### Modifiers — `re-`, `up-`, `dry-`, `cross-`

Four prefix modifiers, applicable to any keyword. Dash is mandatory.

| Modifier | Effect | Example |
|---|---|---|
| `re-` | Replay the previous action of the same keyword. Output: **diff** vs prior output — what changed, disappeared, appeared. No repetition of identical content. | `re-analyze`, `re-evaluate` |
| `up-` | Operator has modified the target document. Re-process with fresh context — not a diff, a new pass. Edit content (annotations, corrections, instructions) is interpreted on read. | `up-evaluate`, `up-apply` |
| `dry-` | Simulate the action without side effects. Applies to any keyword with a file side effect (`update`, `apply`, `fix`, `append`, `+xxx`…). Displays what would be done. No-op on analysis keywords (no file side effects to simulate). | `dry-update`, `dry-apply`, `dry-append` |
| `cross-` | Compare two explicit targets. Changes execution mode: agent reads both targets and produces a comparative analysis. Extends to any analysis keyword. | `cross-analyze A B`, `cross-evaluate A B` |

### Evaluation — `analyze`

*(Dedicated section pending — current behavior defined in triplet table.)*

### Clarification — `explain`

*(Dedicated section pending — current behavior defined in triplet table.)*

### Code — `audit`

Target: complete directory or set of code files. Default scope: **ALL** files in the target directory — no skip, no shortcut.

**Prerequisite**: before any action, re-read the full definition of `audit` in the protocol. Rare and costly operation — a framing error compounds across the entire audit.

Mandatory sequence per file:

1. Read file N
2. Analyze: conformity, methods, procedures, inter-file links
3. Audit: bugs, patterns, technical debt, security, broken references, trivial errors
4. **Write** findings to report (append) — BEFORE reading file N+1
5. Propose fixes if applicable

The report is incremental: each Write is a checkpoint. If the session drops, the partial report is usable.

Progress tracker: at each checkpoint, write to `audit-report/_progress.md` the list of processed and remaining files. Before each Read of a file to audit, check `_progress.md` to see if already processed — if so, skip.

Batch: ≤3 files per Read→Write cycle. Beyond that, use sub-agents (Agent tool, subagent_type=Explore).

Analysis points evaluated per file:

1. Conformity (headers, conventions, style)
2. Methods and procedures implemented
3. Links and inter-file dependencies
4. Bugs and trivial errors
5. Patterns and anti-patterns
6. Technical debt
7. Security (injections, permissions, secrets)
8. Broken references (imports, paths, variables)

All three outputs are always produced:

1. **detailed report** — one file per audited file, exhaustive structured analysis on the 8 points above → saved in `audit-report/<file>-audit.md`
2. **drift report** — consolidation of ALL drifts, broken references, trivial errors discovered across the entire directory → saved in `audit-report/drifts.md`
3. **summary report** — summary of what was done and discovered, observed metrics (files read, drifts detected, critical vs minor errors), ~5 line conclusion, x/10 audit score → saved in `audit-report/summary.md`

Display: the summary report is presented at the end of the audit for immediate feedback. Detailed reports stay in `audit-report/` — the operator consults on demand.

### Verification — `inspect`

*(Dedicated section pending — current behavior defined in triplet table.)*

### External audit — `deep-scan`

Clone if absent (URL provided, or GitHub search — 98% of sources; private GitLab = operator-provided URL).

Reputation metrics evaluated:

1. Repository age
2. Last activity date
3. Stars count
4. Forks count
5. Commits count
6. PRs count
7. Owner responsiveness on issues
8. Active contributors count
9. License
10. Transitive dependencies (if library)

Both outputs are always produced (if only one is requested, that is an `analyze`, not a `deep-scan`):

1. **brief** — credibility report, functional specs, relevance to active project, methods of interest, overall assessment → saved as `<repo>-brief.md`
2. **insight** — long analysis report, key method source code → saved as `<repo>-insight.md`

Display: condensed brief rendered inline for immediate feedback ("toxic repo", "reliable source", with short rationale).

---

## Validation / Execution

| Keyword | Context | Behavior |
|---|---|---|
| `ok` | Pending proposal | Validate + proceed |
| `ok for X` | Partial proposal | Validate X only. Remainder stays open |
| `go` | Planned action | Execute. May interrupt if ambiguity ≥ 6/10 |
| `GO` | Same, stronger | Immediate execution, zero interruption even on minor ambiguity |
| `do X` | Named step | Execute X explicitly. Scope limited to X, no implicit extension |
| `scope?` | Before a large action | List files, functions, and modules that will be touched — no action taken. Pre-execution transparency. Distinct from `align` (understanding check) |

### Disambiguation: go / GO / do X

1. **`go`** — execute the plan as discussed. May signal a blocker or prompt if ambiguity ≥ 6/10.
2. **`GO`** — no interruption. Reserve for 100%-validated sequences.
3. **`do X`** — designates a precisely named step. No scope overflow.

### Disambiguation: ok / ok for X

1. **`ok`** — validates the entire pending proposal.
2. **`ok for X`** — validates X only. After execution: restate remaining points + action summary.

---

## Modification

| Keyword | Context | Behavior |
|---|---|---|
| `update` | Post-discussion | Apply all modifications discussed |
| `minor update` | Same, reduced scope | Scope limited to the discussed correction only. No extension |
| `apply` | Explicit doc target or `up-` modifier | Apply instructions found in the document. Requires a reference (`apply file.md`) or the `up-` modifier |
| `correct` | Post qualify / evaluate | Agent applies its own identified corrections from its analysis. Prompts only if the choice is purely stylistic |
| `fix` | Identified point(s) to correct | Apply correction immediately on cited point(s). `fix 1, 3` = points 1 and 3 only. Strict scope — no implicit extension |
| `draft` | Content to produce (doc, spec, text) | Produce content without definitive side effects — no file write. Cycle: `draft` → operator review → `update` or `go` to finalize. Agent explicitly marks output as draft |
| `diff` | Current state vs last stable state | Show all changes since last `update` or baseline — statement of current delta, not simulation |

`update` alone = post-discussion. No ambiguity with `update <doc>` (different context — prompt if unclear).

**Out-of-context fallback**: if an action keyword is used without required prior context (`fix` without identified issue, `correct` without prior `qualify`/`evaluate`): the agent signals the missing context in one line and asks to confirm before acting.

### Disambiguation: update / minor update / correct

1. **`update`** — apply everything discussed since the last stable state.
2. **`minor update`** — one targeted correction only. Do not use the pass to clean or extend.
3. **`correct`** — agent applies its own corrections from a prior `qualify` or `evaluate`. Confirms only when the choice is purely stylistic (no objectively correct answer).

### TUI vs file mode

- **File mode** (editor open): one confirmation line is sufficient — editor auto-refresh shows the diff. Format: `filename.md — nature of change`.
- **TUI mode** (no editor): render the modified block in the response.

---

## Meta-conversation

| Keyword | Context | Behavior |
|---|---|---|
| `idea` | Proposal to evaluate | Operator floats an idea in current context. Short assessment: relevant now? conflicts with current approach? good timing? No action |
| `question` | Request for response | Operator asks a question. Agent answers, does not execute. No action triggered unless followed by `go` or `ok` |
| `align` / `align?` | Pre-execution comprehension check | Operator submits their understanding of an agent proposal. If correct: agent executes. If not: agent surfaces the misunderstanding and corrects — agent does NOT bend its proposal to match an incorrect understanding. **Exception: only keyword that triggers execution without explicit `go`/`ok`.** |
| `correct?` | Comprehension check — no execution | Operator verifies understanding of a concept or mechanism. Agent confirms or re-explains. No action triggered — `align?` if an action must follow |
| `valid?` | Confirmation of formulation | Operator asks if a formulation, entry, or proposition is correct. Agent confirms or corrects. Never triggers an action — pure checkpoint |
| `nope` | Rejection | Reject. Propose alternative, do not insist |
| `reroll` | Incoherent response or open question | Replay the same sequence for a statistically different output. Useful when initial token misoriented generation, or on open questions with no single correct answer |

---

## Observations and Digressions

Interrupt prefix family — user signals a point orthogonal to the current task. Syntax: prefix at beginning of phrase (like `TODO:`, `note well:`). Levels ⚡→📋→🔭.

| lvl. | Prefix | Context | Behavior |
|---|---|---|---|
| ⚡ | `note:` | Minor point raised mid-output | Agent reacts ≤2 lines, continues immediately. No action, no persistence. |
| 📋 | `aside:` | Actionable observation, orthogonal | Treat immediately (fix or explicit backlog). Structured response ≤1 section, then resumes task. |
| 🔭 | `side quest:` | Multi-session orthogonal mini-project | Create `work/doing/<slug>.md` + short assessment on timing. No immediate execution. |

**Distinction `note:` vs `aside:`**: `note:` = inline opinion, no action required · `aside:` = demands an action (immediate fix or explicit backlog). Criterion: actionability, not length.
**Distinction**: `note:` ≠ `note well:` — `note:` = react inline now · `note well:` = persist to memory.
**UPPERCASE mid-sentence**: imperative signal — the UPPERCASE word marks a non-negotiable constraint. Treated as an implicit `aside:` without explicit prefix.

---

## Flow Control — STOP / ESC

| Signal | Nature | Behavior |
|---|---|---|
| `stop` (prompt) | Agent-managed breakpoint | Agent stops cleanly at next prompt read. Use: debug, explicit pause, checkpoint. Agent informs user via output. |
| ESC | External emergency stop | Interrupts compute instantly, independent of agent state. By design: safety chain is external to the system (traditional safety logic). |

**Distinction**: `stop` = agent chooses to halt (cooperative) · ESC = user cuts (independent). An emergency stop must NOT depend on system operability — if it does, that's a design flaw.

---

## Persistence / Memory

| Keyword | Context | Behavior |
|---|---|---|
| `note well:` | Information to retain | Persist in handoff or ACTIONS. Do not merely acknowledge |
| `TODO:` | Idea or deferred action | Add to backlog. No immediate execution — idea, not a command |
| `TODO_now:` | Immediate action | Handle immediately — session may terminate at any time |
| `backlog:` | Canonical reference | Task list: `backlog.md` — items referenced by `#N` — read-only reference, no action triggered |

---

## Incoming Content / Manipulation

| Keyword | Context | Behavior |
|---|---|---|
| `for reference` | Incoming material | Integrate/process content. Confirm reception in one line |
| `append` | Targeted addition | No ref: add to end of current file. With ref (`append: FILE / ...`): locate and add/modify target section. If section absent: create at end, then add. Rephrase if needed |
| `+xxx` | Addition by category | Add following content to section or document named `xxx` — concept-name routing, not path-based. Distinct from `append` (path-based) |
| `inbox` | File dropped by user | User has dropped a file in the exchange inbox. Interactive agent fetches, processes or dispatches per context. Fleet clears after processing. |
| `outbox` | File deposited by fleet | Fleet has deposited a file in the exchange outbox. Agent states verbally in session. User retrieves and clears. Fleet does not delete after deposit. |

---

## Inline Notation — `<=` and `=>`

Annotations in a message or document, without interrupting the main thread.

| Notation | Direction | Usage |
|---|---|---|
| `<=` | Past → present | Context, nuance, correction on what precedes |
| `<=:` | Term definition | The term immediately before `<=:` is a keyword to document — text after `:` is the associated entry. Term = single or atomic compound (e.g. `minor update`). **Agent behavior: immediate append in protocol or glossary per term nature. If destination ambiguous: ask first. Priority: `<=:` is processed in parallel with any action keyword on the same token — never absorbed by it. `check (<=: ...)` triggers both the append and the action.** |
| `=>` | Present → future | Consequence, rename, resulting action, implication |

**Behavior**: enriching metadata, no action of its own — except when an active keyword (`TODO:`, `idea`, etc.) is encapsulated within.

**Composition `=>` + digression keyword**: when `=>` points to a keyword from `## Observations and Digressions` (`note:`, `aside:`, `side quest:`), the full keyword behavior applies. `=>` carries causality ("what precedes generates"), the keyword carries handling. Lazy form: avoids interrupting the thread to reformulate what was just said. Example: `=> side quest:` = "the preceding discussion implies a side quest" — same behavior as standalone `side quest:`.

In a document processed via `up-`: `<=` and `=>` notations are treated as revision annotations, not session directives.

---

## Imperative Signal

**UPPERCASE mid-sentence**: one or more words in ALL CAPS within a sentence = imperative directive — non-negotiable constraint — overrides current action including scope boundaries. Effect: immediate stop or override of in-progress action. Scope: action-scoped (not session-scoped).

Example: "you push NOTHING" → NOTHING triggers stop on any push action — no further push attempt without explicit re-authorization.

---

## Block Separator — `===`

Context: WSL terminal without multi-line input support — true paragraph breaks are not possible.

`===` separates two distinct blocks in a single message. Agent processes each block as an independent point, in order.

```
first point === second point === third point
```

**Non-collision rule**: if `===` appears in quoted code or technical content, context (backticks, indentation) takes precedence — it is not a block separator.

---

## Navigation — shorthand `#N`

LCARS directory trees follow the `#N_name` convention (see `system-conventions.md`). In conversation, `#N` alone designates the directory with that number at the relevant level.

`commons/#1/#2/` = `commons/#1_docs/#2_directives/` — unambiguous, resolved locally.

The agent resolves the shorthand via `ls` if needed. The operator can cite an abbreviated path without writing the full name.

---

## Examples

_Narrative section — not parsed by the MR._

### Evaluation

- `opinion?` end of sentence: "we could set the buffer to 512 bytes, opinion?" → targets that proposition only, not the entire context
- `evaluate this spec` → structured assessment of the provided document
- `analyze src/scheduler.c` → reads the file before producing the report

### Clarification

- `clarify the scope of check here` → direct clarification, no action
- `these conventions are ambiguous, elaborate` → `elaborate` at end of line, develops what precedes
- `elaborate option 2` → at beginning of line, develops option 2 from the previous list
- `explain the MR deduplication mechanism` — depth on demand: `[1]` overview · `[2]` structured + examples · `[3]` deep dive

### Research

- `summary` alone → condensed summary of the current session context
- `tldr cmsis-dap` → web search, inline brief + sources

### Code

- `review src/parser.c` → reads code, analyzes correctness / security / patterns
- `opinion` on a code architecture choice → identical to Evaluation group
- `audit fleet/` → systematic file-by-file audit with incremental checkpoint writes

### Verification

- `valid? "append-only except documented bug-fix"` → confirmation or correction of the formulation, no action
- `check main.c` (with correction list in context) → status ✅/❌/⚠️ per point
- `inspect docs_and_plans/` → exhaustive methodical verification, no predefined checklist

### External audit

- `qualify this report` → formal quality + explicit verdict
- `deep-scan https://github.com/foo/bar` → full audit → brief.md + insight.md

### Standalone

- `x/10 — add a Redis cache in front of the API` → score + 2 lines

---

## Notes

# Notes — #5_protocole-standard.md

**Date** : 2026-03-10
**Statut** : companion narratif du fichier canonique
**Fichier canonique** : `#5_protocole-standard.md` (seul fichier faisant foi)

> Ce fichier est une version narrative et explicative. Il n'est pas injecté, pas dérivé, pas normatif.
> Toute règle ou contrainte doit vivre dans le fichier canonique. Ce fichier documente le *pourquoi*,
> stocke le changelog, et capture les discussions de refonte.

---

## Changelog version canonique

| Date | Nature | Détail |
|------|--------|--------|
| 2026-03-10 | Création | Full rewrite EN depuis #4_protocole.md |
| 2026-03-10 | Audit v2 | Mapping FR→EN non documenté (ponce→deep-scan, avis→opinion, raccord→align, fais→do, aparté→aside), `elaborate` ajouté sans source FR, rôle opérationnel flou (MR utilise les keywords FR) |

---

## Notes d'analyse (session v2)

### Question ouverte : ce fichier sert à quoi ?

Le MR `CLAUDE-protocol.md` injecté dans les agents utilise les keywords FR. Ce fichier EN est labellé "onboarding template" mais aucun flux d'onboarding ne le consomme. À trancher : garder comme référence EN, déplacer en annexe, ou supprimer.

*(à compléter lors de la revue fichier par fichier)*
