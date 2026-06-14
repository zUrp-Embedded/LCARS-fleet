# Modop — rubber-duck (verbalisation pré-action)

**Date** : 2026-05-18
**Dernière révision** : 2026-06-14
**Statut** : actif — modop bundle SP positif
**Dérivé de** : doctrine YOLO D-Y-1 4 marqueurs verbalisation + §2.6 verbalisation pre-edit inconditionnelle (beyond_#1 doctrine-anti-yolo + LCARS canon)

---

## Principe

**Verbalise ton raisonnement AVANT d'agir, à chaque marqueur critique.**

Le rubber-duck est la mécanique anti-yolo LCARS : forcer l'agent à expliciter SON modèle mental avant action irréversible. C'est exactement le pattern superpowers "announce-then-act" (Commitment) appliqué au raisonnement, pas juste à l'annonce d'action.

**Référence canon LCARS** :
- `audit-doctrinal/from-3/methodo-yolo-beta/REGLES-YOLO.md` §R6-bis "Rubber duck aux moments critiques" + §R6-bis-adversarial "Check-list rubber duck format triadique"
- `audit-doctrinal/from-3/methodo-yolo-beta/doctrine-YOLO-fonctionnement-interieur.md` §2.4 "D-Y-1 — Discipline rubber duck systématique aux marqueurs"

## 4 marqueurs critiques (D-Y-1)

Verbalisation obligatoire avant :

1. **Edit / Write** d'un fichier source ou config
2. **Bash** avec side-effect (rm, mv, push, install, deploy)
3. **Dispatch** d'un autre agent (engineer → worker, etc.)
4. **Commit / push / merge** (write public state)

## Format verbalisation

Avant chaque action sur marqueur critique :

```
Rubber-duck:
  Je vais : <action verbatim>
  Pourquoi : <raison liée à la task / spec / plan>
  Préconditions vérifiées : <ce que j'ai check avant>
  Risque si erreur : <conséquence si je me trompe>
  Reversibilité : <réversible | irréversible>
```

Si une des cases est faible ou vide → **STOP**. Re-check avant action.

## Discipline

- **Pas de raccourci verbalisation** : "c'est évident" = signal de rationalisation, pas validation.
- **Pas de batch sans verbalisation** : 5 Edits d'un coup = 5 verbalisations distinctes.
- **Pas de verbalisation après-coup** : "j'ai fait X parce que Y" post-action ≠ rubber-duck. La discipline est PRE-action.

## Application au pipeline V2

Cap-profile dont `modop_set: [rubber-duck, ...]` :
- engineer (workers code) — toute écriture code
- architect — toute proposition irréversible (plan, dispatch)
- starfleet — toute opération système (sudo, deploy, merge)

Cap-profile **dispensé** :
- qualifier, reviewer (read-only par scope, pas de marqueurs critiques)
- consultant (audit-only, scope advisory)

## Anti-pattern superpowers

Le pattern superpowers "announce skill" est plus léger (juste annonce du skill utilisé). Le rubber-duck LCARS est **plus dur** : verbalisation du raisonnement, pas juste annonce.

Les deux coexistent :
- announce-then-act = "Using modop:X" (Commitment lightweight)
- rubber-duck = "Je vais X parce que Y..." (Commitment + introspection)

Modop bundles peuvent inclure les deux : announce au début, rubber-duck aux marqueurs critiques.
