# Modop — brainstorming (Socratic design pre-code) rev2 enrichi

**Date** : 2026-05-18 (rev1) — 2026-05-18 rev2 enrichi M5 item 16
**Dernière révision** : 2026-08-13
**Statut** : actif — modop bundle SP positif
**Dérivé de** : superpowers/skills/brainstorming (ADAPT enrichi) — design Socratique avant code + reverse outbox/#3_ponce-reverse/superpowers/superpowers-reverse/blocS1-workflow-core.md

---

## HARD-GATE — Do NOT violate

**You MUST use modop:brainstorming before any creative work** :
- creating features
- building components
- adding functionality
- modifying behavior

Brainstorm est OBLIGATOIRE dès que l'intensité déclarée dépasse le jetable (**C1+**). Le bypass **C0**
(PoC jetable) est le SEUL cas autorisé et doit être justifié par la déclaration d'intensité du projet
(`.lcars.json`). **"Simple projects skip design"** reste **FORBIDDEN à C1+**.

Rationale : unexamined assumptions cause wasted work, même sur tâches triviales. Un brainstorm de 5 minutes économise des heures de re-work.

---

## Iron Law

**One question at a time. No multi-question dumps. Approach exploration with tradeoffs BEFORE design commitment.**

L'agent NE PROPOSE PAS le design directement. Il pose des questions, écoute, propose 2-3 approches avec tradeoffs explicites, laisse l'user choisir.

## Pattern Socratique

### Étape 1 — Comprendre le problème

Une question à la fois :
- "Quel est le core problem ?"
- "(a) X, (b) Y, (c) Z, (d) autre ?"

L'user répond. L'agent pose la suivante. Et ainsi de suite.

### Étape 2 — Explorer les contraintes

- Tech stack imposé ou libre ?
- Performance / sécurité / portabilité priorités ?
- Cas d'usage primary / secondary ?

### Étape 3 — Présenter approches

Quand assez de contexte :

```
Approach A: <description> — pros: [...] — cons: [...]
Approach B: <description> — pros: [...] — cons: [...]
Approach C: <description> — pros: [...] — cons: [...]

Which fits your context?
```

### Étape 4 — Design par sections

User choisit. Agent présente le design **par sections** :
- Architecture globale
- Modules / composants
- Data flow
- Edge cases / failure modes

User approve **section par section**. Pas de "approve all" en bloc.

### Étape 5 — Spec doc

Quand toutes sections approuvées :
- Agent écrit `docs/specs/<date>-<slug>.md` (typiquement 200-500 lignes)
- Self-review : relit le doc, fix placeholders, vérifie consistency
- User review : user lit le doc, demande clarifications
- **Approval gate explicite** : "Spec approved → next stage `plan`" — sans approval, pas de plan

## MANDATORY checklist (avant proceed plan stage)

You MUST create a TodoWrite task pour chaque item ET completer dans l'ordre :

- [ ] Core problem identified (question 1 answered)
- [ ] Tech stack constraints understood (questions 2+ answered)
- [ ] Edge cases / failure modes listed
- [ ] 2-3 approaches with tradeoffs presented to user
- [ ] User chose approach
- [ ] Design sections approved one-by-one (no batch approval)
- [ ] Spec document written (`docs/specs/<date>-<slug>.md`)
- [ ] **Spec Self-Review with fresh eyes** : agent re-lit le doc, fix placeholders, vérifie consistency BEFORE user review
- [ ] User review explicit (user lit le doc, demande clarifications)
- [ ] Approval gate explicit ("Spec approved → next stage `plan`")

**Can't check all boxes? Loop back, fix gap, retry.**

## Discipline anti-rationalisation (étendue)

| Rationalisation | Réfutation |
|---|---|
| "Je propose ça directement, c'est plus efficace" | **NO.** Toujours questions d'abord. Direct proposal = unexamined assumptions. |
| "Approve all sections at once, pas besoin de granular" | **NO.** Sections séparées. Approval granular permet user catch issues précoces. |
| "I'll skip the spec doc, let's just code" | **NO.** Spec doc obligatoire. Code without spec = re-work + drift. |
| "Spec is good enough, user va le voir" | **NO.** User review explicite OBLIGATOIRE. Self-review fresh eyes AVANT user. |
| "C'est juste un petit utilitaire, skip brainstorm" | **NO.** Petits utilitaires ont aussi edge cases. Brainstorm = 5 min, économise heures. |
| "Je connais déjà le design, pas besoin de questions" | **Spec Self-Review fresh eyes test.** Si tu connaissais, écris-le et lis-le froid. Test : peux-tu nommer 3 edge cases sans regarder ? Non = brainstorm requis. |
| "Going to discuss design in plan stage anyway" | **NO.** Plan = tasks 2-5 min. Brainstorm = design global. Différents niveaux. Skip brainstorm = plan sera bancal. |

## Spec Self-Review (MANDATORY, fresh eyes)

After writing spec document, **STOP for 30s**. Re-lis comme si c'était un autre agent qui l'avait écrit :

- **Placeholders restants** ? (e.g., "TODO", "X to be determined", "[fill in]") → FIX
- **Consistency interne** ? (e.g., "Section 3 said Y, Section 5 contradicts Y") → FIX
- **Edge cases missing** ? → ADD (re-questionner user si nécessaire)
- **Tech stack constraints exhaustifs** ? → ADD
- **Failure modes listed** ? → ADD
- **Approaches tradeoffs balanced** (pas que pros, aussi cons de l'approach retenue) → ADD

**FIX issues BEFORE user gate.** PAS de "user va le voir et corriger" — c'est ton job d'agent. User review = check final, pas correction baseline.

## Cap-profile usage

Stage `brainstorm` du pipeline `standard-qa` :
- Role : `architect` (Tier 0, front user)
- Modop_set : `[brainstorming, rubber-duck, persuasion-discipline]`
- Output : `docs/specs/<date>-<slug>.md`
- Gate : user-approval explicite

## Différence v1 LCARS

Le workflow des cartes n'a pas de stage brainstorm formalisé — l'architect propose direct. Le modop:brainstorming **introduit** le pattern Socratique comme discipline obligatoire pour les tâches non-triviales (intensité C1+).

Pour un projet déclaré C0 (PoC jetable), brainstorm est skipped (cf. .lcars.json).

## Announce

> "Using modop:brainstorming to refine the design. First question: <Q1>"

(une question à la fois, pas de batch)
