<!--
  title: Workflow fleet — Comment on travaille
  directives_rev: 6.0-RC
  date: 2026-03-22
  last_updated: 2026-03-23
  status: audité 2026-03-23 — v6.0-RC — injection via build-sp.sh
  referenced_by: build-sp.sh
-->

## Édition de fichiers

Exceptions à la règle Read-avant-Write (core/#5_edition) :

**Write sur fichier existant** : si le fichier a été Read plus tôt dans la session ET aucun outil ne l'a modifié depuis, un re-Read n'est pas requis. Exception `.md` en réécriture complète → `bash cat <file> > /dev/null` pour confirmer l'existence, puis Write. Exception `scratchpad.md` : append `bash >>` uniquement. Exception `/home/commons/` : TOUJOURS re-Read (multi-writer, stale possible). `bash cat/head/tail` ne comptent PAS comme Read.

**Edit consécutifs** : pour des Edits consécutifs sans modification intervenante, le Read initial suffit.

**drvfs (9p)** : Edit tool vide silencieusement les fichiers sous drvfs (ready-room, mounts Windows). Workaround : `cp <file> /tmp/`, éditer, copier avec `dd`.

---

## En-tête GO-7 — format `.md`

Immédiatement après `# Titre` :

```
**Date** : YYYY-MM-DD
**Dernière révision** : YYYY-MM-DD
**Statut** : <one-liner>
**Référencé par** : <fichiers ou —>
**Dérivé de** : <fichier source ou —>   ← fichiers dérivés uniquement
```

Exceptions : formats sans commentaires natifs (`json`, binaires).

Un agent qui oublie l'en-tête a dévié. Le pre-commit hook bloque — aucun auto-fix. Un hook qui corrige les violations les dissimule. Exception : STARDATE et dates dans les headers `.sh` — bookkeeping mécanique, auto-corrigé par le hook.

---

## Structure docs/work par projet

Tout projet durable : `docs/` (stable refs, FR) + `docs/en/` (EN translations) + `docs/research/` (rapports `deepsearch`). Séparé : `work/` (gitignored, non versionné).

INTERDIT : fichiers à la racine d'un répertoire partagé.

### Structure work/

```
work/
├── index.md           ← sommaire vivant
├── backlog.md         ← file d'attente structurée
├── TODO/              ← plans spécifiés, non démarrés
├── doing/             ← 1-2 plans actifs max (WIP limit)
└── done/              ← plans closurés (validés)
```

### Cycle de vie des plans

`TODO → doing → done`. Transitions via `fleet-plan.sh` uniquement. Aucun `mv`/`cp` manuel.

`fleet-plan.sh done` dispatche un reviewer headless via `fleet-dispatch.sh`. PASS = promotion vers `done/`. FAIL = plan bloqué, items MISSING listés. Fallback si reviewer indisponible = FAIL (pas PASS silencieux).

Validation incrémentale : `fleet-plan.sh done <slug> --step N`.

### Pipeline scratchpad → backlog → plan

```
scratchpad → scrub → now (exécuter) | backlog
backlog    → scrub → now (exécuter) | plan (fleet-plan.sh new/append)
```

Scrubs via `fleet-scrub.sh`. Le reviewer headless trie chaque item. Scratchpad et backlog vidés complètement après scrub.

### Index (work/index.md)

Trace (10 dernières actions, rolling) + routage (sections thématiques). Maintenu automatiquement. Bootstrap : `fleet-scrub.sh init`.

### Persistence work/

Source de vérité : `work/` dans `/home/projects/<projet>/` (ext4). Visibilité user : via `ready-room/fleet-live` (symlink direct vers `/home/`). Backup dédié : v7.0.

### Matrice agent×commande

| Agent | new | start | done | check | list | append | audit | scrub |
|---|---|---|---|---|---|---|---|---|
| Architect | oui | — | — | oui | oui | — | — | — |
| Engineer | — | oui | — | oui | oui | — | — | oui |
| Dev | — | — | oui (step) | oui | oui | oui | — | — |
| StarFleet | oui | oui | oui | oui | oui | oui | oui | oui |
| Consultant | — | — | — | oui | oui | — | — | — |

---

## Langue

Conversation avec l'user : français.
Code et identifiants : anglais.
Plans, architecture docs, bug journals : français.
IPC, handoffs : anglais.

---

## Conventions de nommage

**Noms = fonction.** Tout répertoire et fichier structurant se nomme d'après sa fonction — sémantique et auto-descriptif. Un humain extérieur au projet comprend la fonction sans consulter une légende.

Préfixes numériques : `#0` = fondations (lire en premier), numéros croissants = spécificité croissante. Le numéro reflète la position dans la hiérarchie conceptuelle, pas la prochaine valeur disponible.

Aucun nom propre d'utilisateur dans les directives. TOUJOURS `user`.
Termes techniques universels (git, cmake, pytest, tmux) : JAMAIS remplacés par des équivalents Starfleet.

---

## Code — règles générales

Secrets JAMAIS dans les fichiers versionnés. Rappeler .env + .gitignore si pertinent.

Pas de commentaires inline sauf contraintes hardware/protocole non évidentes.

Code explicite > code compact. Lister les dépendances système requises.

Après édition : déclarer uniquement ce qui a changé et pourquoi. Pas de récapitulatif.

---

## Shell — compléments

**Reproductible** : toute séquence shell DOIT fonctionner identiquement sur un environnement frais.

**README OBLIGATOIRE avant push** : mettre à jour le README pour refléter les changements.

---

## Bug journal

Chaque repo avec `docs/` maintient `docs/#11_bug-journal.md`. Entrée OBLIGATOIRE quand un bug est fixé, avant fin de session.

---

## Scratchpad

`$FLEET_SCRATCHPAD` (volatile, hors worktree — `/home/fleet-state/scratchpad-<projet>.md`). Capture immédiate, zéro friction. Format : date + heure en tête de chaque entrée. Outil exclusif : `bash >> "$FLEET_SCRATCHPAD"` — guillemets obligatoires. Jamais Write, jamais Edit. Rédacteur par scope : projet → dev, LCARS → Starfleet. Déclenchement autonome : toute convergence de discussion (conclusion, décision, constat, arbitrage, rejet argumenté) est persistée immédiatement. Le critère est la nature de l'échange, pas l'importance perçue.
