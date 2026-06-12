# Modop — dual-review (spec-compliance + code-quality)

**Date** : 2026-05-18
**Dernière révision** : 2026-05-26
**Statut** : actif — modop bundle SP positif
**Dérivé de** : superpowers/skills/requesting-code-review (ADAPT) + LCARS pipeline standard-qa 6 hops

---

## Principe

**Two-stage review per task** : spec-compliance review **PUIS** code-quality review. **Critical bloque progress, severity-graded.**

Cap-profile `qualifier` et `reviewer` consomment ce modop selon stage pipeline :
- Stage `spec-review` : qualifier check spec compliance
- Stage `code-review` : reviewer check code quality

## Stage 1 — spec-compliance review (qualifier)

**Iron Law** : *Do not trust the report. Read the actual code. Compare line-by-line to the spec.*

1. Lis la spec (output stage `plan`).
2. Lis le code produit (output stage `implement`).
3. Pour chaque task du plan :
   - Vérifie que le code implémente exactement ce que la task décrit.
   - Détecte les écarts : missing, extra, divergent.
4. Génère verdict structuré JSON :
   ```json
   {
     "stage": "spec-compliance",
     "verdict": "proven|partial|fail",
     "severity_max": "critical|important|minor",
     "issues": [
       {"task_id": "N", "severity": "critical|important|minor", "description": "..."}
     ]
   }
   ```

### Gate severity

- **critical** : implémentation ne fait pas ce que la spec dit. **BLOCKING** — engineer reprend.
- **important** : implémentation fait ce que la spec dit mais avec un écart notable (perf, sécurité, edge case). Engineer **doit** corriger avant code-review.
- **minor** : améliorations possibles. Non-blocking, noté pour amélioration future.

## Stage 2 — code-quality review (reviewer)

**Iron Law** : *Read the diff. Read the surrounding context. Don't trust prior reviews.*

1. Diff vs main / vs base commit.
2. Pour chaque hunk :
   - Convention (style, naming, structure)
   - Defensive programming (inputs validation, errors, edge cases)
   - Sécurité (injections, leaks, permissions)
   - Maintenabilité (lisibilité, complexité, couplage)
   - Tests (couverture, qualité des assertions)
3. Génère verdict structuré JSON :
   ```json
   {
     "stage": "code-quality",
     "verdict": "proven|partial|fail",
     "severity_max": "critical|important|minor",
     "issues": [
       {"file": "path:line", "severity": "...", "description": "..."}
     ]
   }
   ```

### Gate severity (idem)

- critical = BLOCKING
- important = MUST FIX before merge
- minor = noted

## Discipline anti-rationalisation

- Pas de "ça a l'air bon" sans lecture line-by-line.
- Pas de "le test passe donc c'est bon" → tests peuvent être faibles, le test n'est pas le contrat.
- Pas de review sans le diff complet en main.

## Review discipline (source superpowers requesting-code-review)

Lors de la formulation issues :

1. **Categorize by actual severity** (not nitpicks as Critical) — cohérent gate severity ci-dessus
2. **Specific file:line references** OBLIGATOIRES — format `path/to/file.ex:42-58`. Pas de "il y a un problème quelque part dans le module X"
3. **Explain WHY each issue matters** dans `description` (pas juste "tests faibles" mais "tests faibles parce que <raison> → impact <conséquence>")
4. **Acknowledge strengths before listing issues** (review balanced)
   - `summary` JSON output commence par 1-2 strengths du code reviewed
   - Évite review déprimante / démotivante
   - Pattern Cialdini Unity ("we're colleagues, your work has value")
5. **Pattern format issue enrichi** (JSON output) :
   ```json
   {
     "file": "lib/example.ex:42-58",
     "severity": "critical|important|minor",
     "category": "missing|extra|divergent|convention|defensive|security|maintenability|testing",
     "description": "Issue concise + WHY it matters + impact concret",
     "spec_excerpt": "..." (si stage spec-compliance),
     "code_excerpt": "..." (si stage code-quality),
     "suggestion": "..." (optionnel — alternative concrete proposée)
   }
   ```
6. **Clear verdict** :
   - `proven` : aucune issue critical ou important. Maybe minor notes.
   - `partial` : issues important (≥1) qui MUST FIX before merge mais pas blocking maintenant.
   - `fail` : issues critical (≥1) qui BLOQUENT merge.

## Announce

Avant review :
> "Using modop:dual-review — stage <spec-compliance|code-quality>. Reading <files>."

Après verdict :
> "Verdict : <proven|partial|fail>. Severity max : <critical|important|minor>. Issues : N."

## Loop iteration

Si verdict `fail` ou `partial` avec severity ≥ important :
1. Issues structurées → `fleet_event_router` broadcast `audit.verdict.{spec|code}` 
2. `fleet_coord` table policy lookup → engineer reprend task affectée (action `revision`)
3. Engineer fix → re-run TDD GREEN → re-dispatch review (loop)

Max 3 iterations (anti-storm canon LCARS). Au-delà → escalade gatekeeper.
