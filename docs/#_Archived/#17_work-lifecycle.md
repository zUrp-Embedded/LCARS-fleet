# Cycle de travail — scratchpad, backlog, plans

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : guide opératoire
**Référencé par** : #00_index.md, #26_user-guide.md

Détail commandes : `fleet-plan.sh --help`, `fleet-scrub.sh --help`.

---

## Conteneurs de travail

```text
work/
├── index.md
├── scratchpad.md
├── backlog.md
├── TODO/
├── doing/
└── done/
```

Rôle de chaque conteneur :
- `scratchpad.md` : capture brute, append-only
- `backlog.md` : file d'attente structurée
- `TODO/` : plans pas encore démarrés
- `doing/` : plans actifs
- `done/` : plans terminés et validés

---

## Pipeline standard

```text
scratchpad → scrub → now / backlog / caduc
backlog    → scrub → now / plan / caduc
TODO/      → start → doing/ → done
```

Règle :
- le cycle normal d'un plan passe par `TODO/`, puis `doing/`, puis `done/`

---

## `side quest:` est une exception explicite

`side quest:` n'est pas un plan standard.

Effet :
- création directe d'un chantier parallèle
- pas d'exécution immédiate automatique
- bypass assumé du passage initial par `TODO/`

Lecture correcte :
- plan normal → cycle standard
- `side quest:` → raccourci explicite pour chantier parallèle

Il ne faut pas confondre les deux.

---

## Discipline du scratchpad

Le scratchpad sert à ne rien perdre pendant la conversation.

Règles :
- capture brute
- pas de structuration prématurée
- tri périodique via scrub

---

## Persistance

La continuité utile ne doit pas dépendre d'une session unique.

Principe :
- transitions de plans synchronisées
- handoffs et `work/` exportés vers la ready-room
- reprise possible sans mémoire parfaite de l'opérateur

Ce document décrit le modèle `v6-rc` actuellement déployé.
Tant que le chantier worktree `work/ops` n'est pas effectivement livré, la vérité opératoire de ces conteneurs reste :
- `work/` local
- handoffs runtime
- export ready-room

Si la persistance bascule plus tard vers un worktree versionné, ce document devra être relu comme description du cycle logique, pas comme promesse du mécanisme de stockage final.

---

## Lire ensuite

- [#26_user-guide.md](#26)
- [#09_protocole-cheatsheet.md](#09)
