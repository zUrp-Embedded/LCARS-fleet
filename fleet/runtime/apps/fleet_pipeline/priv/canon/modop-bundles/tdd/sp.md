# Modop — TDD (test-driven-development) rev2 enrichi

**Date** : 2026-05-18 (rev1) — 2026-05-18 rev2 enrichi M5
**Dernière révision** : 2026-05-26
**Statut** : actif — modop bundle SP positif
**Dérivé de** : superpowers/skills/test-driven-development (ADAPT enrichi) + LCARS canon (modop-driven) + reverse outbox/#3_ponce-reverse/superpowers/superpowers-reverse/blocS2-test-debug.md

---

## Iron Law

**NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST. NO EXCEPTIONS.**

Le code écrit avant un test failing est **supprimé** (`Delete means delete` — répété par doctrine source). Pas d'argumentation. Pas de sunk cost ("la time investie déjà est perdue, la garder n'est pas pragmatique").

> "Production code → test exists AND failed first, sinon NOT TDD" — The Final Rule.

## Cycle RED → Verify RED → GREEN → Verify GREEN → REFACTOR → REPEAT

**6 étapes, pas 3.** Les `Verify` ne sont pas des sous-étapes inline — ce sont des **étapes mandataires** distinctes.

### Étape 1 — RED (Write Failing Test)

1. Lis la task : entrée, sortie attendue, edge cases listés.
2. Écris **UN** test (pas plusieurs) :
   - Minimal
   - Clear name (`it("returns X when Y", ...)`)
   - Real code (no mocks unless unavoidable — cf. Anti-patterns 1+3+4 ci-dessous)
   - Tests **one** behavior

### Étape 2 — Verify RED (MANDATORY)

3. **Run le test**.
4. Confirme :
   - Test fails (assertion error, NOT syntax error)
   - Failure message expected (correspond à l'absence de feature)
   - Fails **because feature is missing** (pas parce que le runner est cassé)
5. Si test passes → tu testes existing behavior (FIX IT). Le passing test prouve rien.
6. Si test errors (syntax/import) → fix error, re-run jusqu'à fails correctly.

**MANDATORY** : sans étape 2 verified, tu n'as PAS encore le test. Stop. Ne passe pas à étape 3.

### Étape 3 — GREEN (Minimal Code)

7. Écris le **strict minimum** pour faire passer le test.
8. **NO over-engineering** :
   - Don't add features non requested
   - Don't refactor other code
   - Don't "improve" while you're there
   - YAGNI (You Aren't Gonna Need It) — explicitement rejeté toute extension prématurée

### Étape 4 — Verify GREEN (MANDATORY)

9. **Run le test**.
10. Confirme :
    - Test passes
    - **Other tests still pass** (no regression — cf. RED Flag #6 ci-dessous)
    - Output pristine (no warnings, no errors latents)
11. Si test fails → FIX **CODE**, not test (cf. Anti-pattern #12 ci-dessous).
12. Si autres tests fail → FIX **NOW** (régression introduite).

### Étape 5 — REFACTOR (Clean Up)

13. After green ONLY (jamais avant).
14. Remove duplication, improve names, extract helpers.
15. **Keep tests green** — re-run après chaque modification structure.
16. Don't add behavior (refactor = preserve behavior, change shape only).

### Étape 6 — REPEAT

17. Next failing test. Retour étape 1.

---

## Discipline anti-rationalisation (10 patterns courants)

Top 10 common rationalizations (source `testing-anti-patterns.md` superpowers). Pour chacune, **réfutation brutale** :

| # | Rationalisation | Réfutation |
|---|---|---|
| 1 | "Code before test, then I'll add test after" | **NO.** Tests-after = "what tests passed?" (descriptive). Tests-first = "should this pass?" (prescriptive). Fondamentalement différents. |
| 2 | "I already manually tested it" | **Ad-hoc ≠ systematic.** Manual testing ne couvre pas edge cases ni régression. |
| 3 | "Tests after achieve same purpose" | **FALSE.** Tests after = biaisés par implementation (tu écris des tests qui passent ton code, pas qui prouvent le contrat). |
| 4 | "It's about spirit not ritual" | **NO.** Spirit IS ritual, ritual IS spirit. Violating the letter of the rules is violating the spirit. |
| 5 | "Keep this code as reference, write tests first" | **You'll adapt it.** = testing after déguisé. Throw it away. |
| 6 | "I need to explore first before TDD" | **Throw away exploration.** Start with TDD. Exploration is not implementation. |
| 7 | "30 min of tests after TDD = same coverage" | **You get coverage, lose proof tests work.** Tests-after may pass for wrong reasons. |
| 8 | "Just this once" / "Exception for this task" | **RED FLAG.** "Just once" devient "every time". Iron Law = no exceptions. |
| 9 | "Sunk cost — I already wrote X hours of code, deleting wasteful" | **Sunk cost fallacy. The time is already gone.** Keeping bad code locks you in. |
| 10 | "Simple code doesn't break, no need for test" | **Simple code breaks.** All code breaks. If trivial, test is trivial too. |

### 6 Red Flags — STOP and Start Over

Si tu observes l'un de ces patterns dans ta session, **STOP et restart depuis étape 1** :

1. **Code écrit avant test** — Delete code. Restart RED.
2. **Test passes immediately at first run** — Test prouve rien. Fix test (probably testing existing behavior).
3. **Can't explain why test failed** — Test is meaningless. Rewrite.
4. **Mocking sans understanding** — Mock breaks test logic. Use real code unless unavoidable.
5. **Incomplete mock** (partial mock, missing fields) — Mock doesn't represent real behavior. Either complete or remove.
6. **GREEN test causes other tests to fail** — Régression introduite. Fix maintenant, pas plus tard.

---

## Verification Checklist (cohérent source 8 items)

Avant marquer task as `DONE` :

- [ ] **RED phase** : test was actually failing (witnessed output)
- [ ] **GREEN phase** : test passes maintenant + all other tests still pass
- [ ] **REFACTOR phase** : code clean (no duplication, clear names, no dead code) AND tests still green post-refactor
- [ ] **Commit phase** : commit message cite task_id + action verbatim from plan
- [ ] **Anti-pattern check** : pas mocking sans understanding, pas test-only methods en production, pas incomplete mocks
- [ ] **No rationalization used** : pas d'exception "just this once" ni sunk cost
- [ ] **Regression check** : `mix test` ou équivalent complet PASSE (pas seulement le test individuel)
- [ ] **Iron Law respected** : test existed AND failed BEFORE production code (re-vérifier mentalement)

**Can't check all boxes? You skipped TDD. Start over.** (source verbatim)

---

## Example concret — Bug Fix Retrait Email

**Task** : "Fix : `extract_email/1` retourne nil sur addresses avec `+tag` (e.g., `user+tag@example.com`)."

### Étape 1 — RED

```elixir
test "extracts email with +tag" do
  assert Mailer.extract_email("Bonjour user+tag@example.com !") == "user+tag@example.com"
end
```

### Étape 2 — Verify RED MANDATORY

```
$ mix test test/mailer_test.exs:42
  1) test extracts email with +tag (MailerTest)
     test/mailer_test.exs:42
     Assertion with == failed
     code:  assert Mailer.extract_email("Bonjour user+tag@example.com !") == "user+tag@example.com"
     left:  nil
     right: "user+tag@example.com"
```

✓ Test fails as expected. Reason : `extract_email/1` regex ne matche pas `+`. Failure message correspond.

### Étape 3 — GREEN (minimal)

Avant : `~r/[a-z0-9._-]+@[a-z0-9.-]+\.[a-z]{2,}/i`
Après : `~r/[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}/i` (ajout `%` et `+`, cohérent RFC 5322 caractères locaux)

### Étape 4 — Verify GREEN MANDATORY

```
$ mix test test/mailer_test.exs
.. (12 tests, 0 failures)
```

✓ Test passe + 11 autres tests passent (no regression).

### Étape 5 — REFACTOR

Renommer regex constant `~r/.../` en `@email_regex` au top du module pour réutilisabilité. Re-run tests : GREEN.

### Étape 6 — Commit + REPEAT

```bash
git commit -m "task 5: extract_email handles +tag (RFC 5322 local-part chars)"
```

Next task.

---

## When Stuck — table troubleshooting

| Trouble | Solution |
|---|---|
| Test passe immediately at first run | Tu testes existing behavior. Fix test (more specific assertion). |
| Test fails for wrong reason (syntax error, import, missing dep) | Fix error first, re-run. RED phase ne compte pas tant que tu n'as pas vu assertion error. |
| Implementation more complex than expected | Décompose en plus petits tests. 1 test = 1 behavior. |
| Tempted to mock everything | Real code first. Mock only if unavoidable (e.g., HTTP external, FS slow, time-sensitive). |
| Multiple tests failing après GREEN | Tu as introduit régression. Revert changes, refactor smaller increments. |
| Test passes mais doute sur correctness | Ajoute edge cases (empty input, null, boundary values). Tests should prove behavior. |

---

## Commit discipline

- Commit après chaque GREEN ou après chaque REFACTOR stable.
- Message commit : `task <task-id>: <action verbatim from plan>`.
- **PAS de commit avec tests failing**.
- 1 task = N commits (1 par GREEN + 1-2 par REFACTOR). PAS 1 commit "task complete" en bloc.

## Announce

Avant chaque task :
> "Using modop:tdd. Starting RED phase for task <task-id>."

Quand RED verified :
> "RED verified — test fails as expected (reason: <verbatim message>). Starting GREEN."

Quand GREEN verified :
> "GREEN verified — all tests pass (N tests, 0 failures). Refactoring."

Quand REFACTOR done :
> "REFACTOR complete — tests still pass. Committing."

## Rejet d'ambiguïté

Si la task ne spécifie pas un comportement testable (entrée/sortie/edge cases), **STOP** et escalade au stage `plan` pour clarification. Ne commence pas RED sur une spec floue.

---

## Discipline d'écriture (persuasion-discipline appliquée)

Cohérent modop `persuasion-discipline/sp.md` — 7 Cialdini principles :

- **Authority** : "NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST", "Iron Law", "MANDATORY", "No exceptions", "Delete means delete"
- **Commitment** : "Announce phrases" (announce-then-act explicit)
- **Social Proof** : "Production code → test exists AND failed first" (norme universelle)
- **Scarcity** : "Verification Checklist" — Can't check all boxes? You skipped TDD. Start over.
- **Unity** : "your colleagues qualifier/reviewer" (consommateurs aval pipeline standard-qa)
- **Reciprocity** : "you've been given task spec — implement it fully with tests"
- **Liking** : ton concis, factuel, sans flatterie (LCARS user profile)
