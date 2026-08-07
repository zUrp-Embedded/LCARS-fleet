<a id="top"></a>
# Guide — qualifier test procedures for fleet artifacts

Reference for writing test procedures sent to the qualifier instance.
Derived from the post-mortem of the first automated test (2026-03-04).

> 🇫🇷 [Version française](../#05_qa-test-procedure.md)

---

**Sections** — [🎯 Principle](#principe) · [📋 Structure](#structure) · [🧪 Test types](#types-de-tests) · [✅ Checklist](#checklist) · [🔔 Artifacts](#artefacts)

<a id="principe"></a>
## 🎯 Segmentation principle

*qualifier operates in its own WSL home — explicitly separate local tests from verifications to delegate.*

The qualifier instance (Haiku) operates in its own WSL home. It does **not have access** to:
- `/local/LCARS-fleet/` (LCARS-fleet repo, ext4 user home)
- `/home/lordzurp/` (lead home)

It **has access** to:
- Its own home (`/home/qualifier/`)
- `/home/commons/` (handoffs, IPC channels)
- Its `.local/bin/` deployed by deploy.sh

**Mandatory rule**: explicitly separate tests into two blocks.

---

<a id="structure"></a>
## 📋 Structure of a test procedure

*The canonical template: two separate blocks (qualifier-local / lead) with explicit reply protocol.*

> [!IMPORTANT]
> Each test must have an ID (T1, T2…) and an explicit expected value. A procedure without an expected value is an unverifiable procedure.

```markdown
### [engineer] Validate <artifact> — ACK required

<One-line description of what is being tested and why.>

#### qualifier-local tests (executable by qualifier directly)

**T1 — <description>**
```bash
<command>
# expected: <expected value>
```

**T2 — ...**

#### architect tests (paths not accessible from qualifier)

The following tests require paths in `/local/LCARS-fleet/`.
qualifier **escalates** them — architect verifies and reports in `to-qualifier.md`.

- T_N: <description> — path: `/local/LCARS-fleet/<path>`
- T_M: <description>

#### Reply protocol

Reply in `to-engineer.md [qualifier]` with:
- `ACK: OK` if all local tests pass and escalated tests are confirmed
- `ACK: KO — <list>` with test ID and observed value

**Important**: when the task comes from `[engineer]`, also set `notify: lordzurp`
in your handoff after writing the response (architect is non-wakeable).
```

[↑ table of contents](#top)

---

<a id="types-de-tests"></a>
## 🧪 Appropriate test types for qualifier

*Distinction between static tests executable locally and integration tests to always escalate.*

### Tests qualifier can run (static/structural)

| Type | Example |
|------|---------|
| File existence | `test -f /home/commons/to-qualifier.md` |
| YAML frontmatter | `grep "^name:" skill.md` |
| Section presence | `grep -c "^## Step" skill.md` |
| Absence of dangerous patterns | `grep -E "\bmaster\b" file.md` |
| Logic coherence (reading) | Narrative review — "workflow is complete, unambiguous" |
| Tests in qualifier home | Files deployed in `~/.local/bin/` |

### Tests out of qualifier scope (always escalate)

| Type | Reason |
|------|--------|
| Paths in `/home/wsl-root/` | Not mounted on qualifier |
| Execution of fleet scripts | May have side effects |
| Integration tests (network calls, ports) | Out of scope + side effects |
| Reading files in `/home/lordzurp/` | Not accessible |

[↑ table of contents](#top)

---

<a id="checklist"></a>
## ✅ Checklist before sending a procedure to qualifier

*Five control points to ensure a procedure is executable without ambiguity by qualifier Haiku.*

- [ ] Each test has an ID (T1, T2...) and an explicit expected value
- [ ] Tests are classified as "qualifier-local" vs "lead"
- [ ] The reply protocol includes `notify: lordzurp`
- [ ] The procedure does not ask qualifier to run code that modifies system state
- [ ] Static tests cover: existence, structure, absence of forbidden patterns, logic

[↑ table of contents](#top)

---

<a id="artefacts"></a>
## 🔔 Artifacts that trigger a mandatory qualifier procedure

*Three categories of fleet artifacts that systematically require qualifier validation before deploy.*

> [!NOTE]
> These triggers are defined in `home_claude_CLAUDE.md` lead scope section. Modifying these artifacts without a qualifier procedure is a workflow violation.

See `home_claude_CLAUDE.md` lead scope section:
- New skills `.claude/skills/*/SKILL.md`
- New or modified hooks `.claude/hooks/*.sh`
- New or modified directives `home_claude_CLAUDE*.md`

[↑ table of contents](#top)
