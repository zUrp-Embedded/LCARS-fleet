# Modop — persuasion-discipline (Cialdini patterns)

**Date** : 2026-05-18
**Dernière révision** : 2026-05-26
**Statut** : actif — modop bundle SP positif transverse
**Dérivé de** : superpowers/skills/writing-skills/persuasion-principles.md (ADOPT innovation)
**Référencé par** : tous modop bundles (couche transverse)

---

## Pourquoi

Étude académique Meincke et al. (2025) "Call Me a Jerk: Persuading AI" N=28000 conversations : les LLMs répondent aux mêmes principes de persuasion (Cialdini) que les humains.

Application LCARS : la **discipline d'écriture** des modop bundles + fragments role + brief mandate doit utiliser ces patterns pour **résister à la rationalisation sous pression**.

C'est une couche transverse — pas un modop activé/désactivé, mais une **discipline de rédaction** appliquée à tous les modop.

---

## Les 7 principes appliqués

### 1. Authority

**Pattern** : impératif ALL-CAPS pour règles bloquantes.

- `MUST`, `MUST NOT`, `Iron Law`, `EXTREMELY-IMPORTANT`, `NO EXCEPTIONS`
- Cite la doctrine canonique (ex: `Canon LCARS §0 #1 — refus par défaut`)
- Cite le standard externe quand pertinent (IEC 61508, DO-178C, MISRA C)

**Anti-pattern** : "il est recommandé de", "généralement", "habituellement". Faiblesse délibérée détectable.

### 2. Commitment

**Pattern** : "announce-then-act". L'agent **annonce** publiquement ce qu'il va faire avant de le faire.

- "Using modop:tdd. Starting RED phase."
- "Reading <files>."
- "Verdict : <verdict>. Issues : N."

**Mécanique** : l'engagement public augmente la cohérence comportementale. L'agent qui annonce ne triche pas avec l'annonce.

### 3. Social Proof

**Pattern** : norme behavioral universelle.

- "Every time", "always", "the agent checks before any task"
- "All workers MUST verify GREEN before commit"
- "Every modop bundle includes announce-then-act"

**Mécanique** : positionnement comme norme évidente, pas comme exception fragile.

### 4. Scarcity

**Pattern** : checkpoints time/scope-bound.

- "BEFORE proceeding to <next-stage>"
- "WITHIN this session, this pod"
- "ONCE per task, no retry on same approach"

**Mécanique** : rareté du moment de décision augmente attention.

### 5. Unity

**Pattern** : relation co-équipier, pas service/utilisateur.

- "your human partner" (pas "the user")
- "we're working on this together"
- "your colleagues qualifier/reviewer" (pas "downstream agents")

**Mécanique** : sentiment d'appartenance augmente alignement.

### 6. Reciprocity

**Pattern** : don/contre-don implicite.

- "you've been given full context — use it"
- "you've received the spec — implement it fully"
- "the user has invested in this brainstorm — deliver the plan"

**Mécanique** : engagement par redevabilité implicite.

### 7. Liking

**Pattern** : ton concis, factuel, sans flatterie inutile.

- LCARS profile user explicite : "humour sec, fonctionnel. pas de retour attendu. encouragement refusé."
- Cohérence ton fleet : court = décision claire. Longueur = doute ou irritation.

**Mécanique** : éviter le rejet par dissonance de ton.

---

## Application aux modop bundles

### Format minimal d'un modop bundle (sp.md)

```markdown
# Modop — <nom>

[1 ligne statut + dérivation]

---

## Iron Law (ou Principe)

[1-2 phrases — règle bloquante, ALL-CAPS sur les MUST]

## Cycle / Stages / Discipline

[étapes numérotées, format : verbe impératif + checkpoints]

## Announce

[patterns de phrases que l'agent dit avant/pendant/après]

## Discipline anti-rationalisation

[liste des rationalisations courantes + leur refus explicite]

## Gate / Loop / Escalade

[conditions de blocage/itération + max iterations + escalade]
```

### Discipline d'écriture

Tout modop bundle DOIT contenir :
- AU MOINS UNE `Iron Law` (Authority)
- DES sections "Announce" (Commitment)
- DES expressions "every time / always / MUST" (Social Proof)
- DES checkpoints "BEFORE" (Scarcity)

Tout modop bundle DEVRAIT contenir :
- Référence au partner humain ou aux collègues fleet (Unity)
- Référence au contexte fourni (Reciprocity)

Tout modop bundle DOIT respecter :
- Ton LCARS user profile (concis, factuel, sans flatterie) (Liking)

---

## Cas d'usage : composer SP positif

Quand `fleet_spbuilder.compose/3` assemble le SP par rôle :

```
SP composé = [
  anthropic-lcars        # couche fournisseur expurgée
  core/v1                # canon LCARS (axiomes, GO, qualité, périmètre, discipline, édition, conventions)
  organisation/topologie # qui fait quoi
  organisation/workflow  # comment on travaille
  user/protocole         # interface user (Tier 0)
  modop/<modop_set>      # discipline runtime composée  ← persuasion-discipline transverse
  role-fragment          # mission rôle
  subagent-template      # template subagent (si role worker)
]
```

Le modop `persuasion-discipline` n'est **pas inclus explicitement** dans `modop_set` — c'est une **discipline de rédaction** appliquée aux autres modop bundles + fragments role. Sa présence est implicite via la qualité de l'écriture des autres composants.

---

## Référence externe

- Meincke et al. (2025), "Call Me a Jerk: Persuading AI" — académique
- superpowers `skills/writing-skills/persuasion-principles.md` — application concrète obra/superpowers
- Cialdini, R.B. (2007), *Influence: The Psychology of Persuasion* — référence fondatrice
