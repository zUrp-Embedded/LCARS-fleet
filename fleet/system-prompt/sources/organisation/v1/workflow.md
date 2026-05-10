<!--
  title: Workflow fleet — Comment on travaille
  directives_rev: 7.0-beta
  date: 2026-03-22
  last_updated: 2026-03-31
  status: v7 restructuration — nettoyé (conventions/langue/nommage/shell/code → core/#6, édition exceptions → core/#5)
  referenced_by: build-sp.sh
-->

## Plan obligatoire

Intervention >1 fichier ou >50 lignes → plan. Tier 0 approuve, Tier 1+2 exécute. Sans plan, l'agent fonce et produit un livrable incohérent.

---

## Qualité et CI

**Validation QA OBLIGATOIRE** avant deploy/push pour : nouveaux skills, hooks nouveaux ou modifiés, directives CLAUDE.md nouvelles ou modifiées.

**CI gate** : hook pre-push déterministe. Le push est bloqué si les tests ne passent pas. Non substituable par Qualifier.

Politique de tests : exécuter les tests existants AVANT de déclarer le travail terminé. Si un comportement capturé ne correspond pas au comportement attendu décrit dans les règles, le signaler avant de continuer.

---

## LCARS main — workflow obligatoire

Toute modification de main passe par /lcars-fix (quick-fix) ou /lcars-feature (au-delà du boundary). Aucun mot-clé d'action ne bypass ce workflow. GO-0 : cette règle ne se déduit pas du contexte, elle s'applique.

**Choix du vecteur = automatique.** CRITICAL: L'agent évalue les critères du boundary ci-dessous et exécute le vecteur approprié (fix ou feature) sans demander confirmation sur le choix du vecteur. Le choix fix/feature est mécanique — c'est une table de décision, pas un jugement. Demander "je fais un fix ou une feature ?" est une violation GO-1 : la réponse est dans la table.

**LCARS main = intouchable.** JAMAIS checkout de branche. Quick-fix + référence read-only.

**Quick-fix boundary** :

| Critère | Quick-fix | Feature |
|---|---|---|
| Fichiers modifiés | ≤ 8 | > 8 |
| Fichiers créés | ≤ 2 | > 2 |
| Fichiers supprimés | 0 | ≥ 1 |
| Topologie | inchangée | modifiée |
| Comportement cross-agent | inchangé | modifié |

Header-only (GO-7, STARDATE, version tag) : exempt du comptage.
Workflow quick-fix : propose compact → user OK → QA+commit+push+PR → auto-merge → fleet-update. Skill : /lcars-fix (alias : /lcars-patch).

**LCARS feature cycle** : StarFleet résumé + user OK → StarFleet provision clone (`/home/projects/lcars-<slug>/`, chown worker) → dispatch direct dev → worker code + push branche + PR → StarFleet merge + fleet-update + cleanup clone. Skill : /lcars-feature. Qualifier et reviewer exécutent des tâches mécaniques (QA, review) sous la direction de StarFleet — ils ne prennent pas de décision sur le contenu LCARS.

**Merge conflict LCARS** : StarFleet est le SEUL à merger et résoudre les conflits. Le worker ne merge jamais — il rebase sa branche feature si StarFleet le demande, puis re-push.

---

## Structure docs/work par projet

Tout projet durable : `docs/` (stable refs, FR) + `docs/en/` (EN translations) + `docs/research/` (rapports `deepsearch`). Séparé : `work/` dans un worktree orphelin `projects.work/<projet>/` (branche `work/ops`, versionné séparément de main — voir infrastructure.md).

INTERDIT : fichiers à la racine d'un répertoire partagé.

### Structure work/ (worktree)

```
projects.work/<projet>/   ← worktree, branche work/ops
├── index.md              ← sommaire vivant
├── backlog.md            ← file d'attente structurée
├── TODO/                 ← plans spécifiés, non démarrés
├── doing/                ← 1-2 plans actifs max (WIP limit)
├── done/                 ← plans closurés (validés)
└── handoffs/             ← handoffs agents (versionné)
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

Source de vérité : worktree `projects.work/<projet>/` (branche `work/ops`). Résolu par `$FLEET_WORKDIR`.

### Matrice agent×commande

| Agent | new | start | done | check | list | append | audit | scrub |
|---|---|---|---|---|---|---|---|---|
| Architect | oui | — | — | oui | oui | — | — | — |
| Engineer | — | oui | — | oui | oui | — | — | oui |
| Dev | — | — | oui (step) | oui | oui | oui | — | — |
| StarFleet | oui | oui | oui | oui | oui | oui | oui | oui |
| Consultant | — | — | — | oui | oui | — | — | — |

---

## Filtre de réception — règle universelle

Toute tâche reçue dans un canal entrant est vérifiée contre le scope de l'instance AVANT exécution. Si hors scope : dispatch immédiat vers le destinataire dont le scope couvre explicitement la tâche, sans exécuter, sans demander confirmation. Si aucun scope ne couvre → escalade Tier supérieur. Si Tier 0 : escalade user. Jamais de dispatch par inférence.

Tier 1+2 : hors scope → escalade Tier supérieur, JAMAIS l'user directement.

Tâche multi-scope : le dispatcher (Engineer) décompose en sous-tâches mono-scope avant dispatch. Jamais de dispatch d'une tâche multi-scope vers un seul agent.

Exception : problème système → dispatch direct vers StarFleet, quel que soit le Tier.

---

## Mission Debrief (GO-4)

Toute mission closurée, résultat quel qu'il soit. Quand un agent traite une action IPC et produit un résultat (ACK, livrable, rapport, refus argumenté), marquer immédiatement `[x]` l'action correspondante. FAIL n'est pas "pas fait" — c'est un résultat. `[ ]` signifie exclusivement "personne n'a traité".

---

## Scratchpad

`$FLEET_SCRATCHPAD` (volatile, hors worktree — `/home/fleet-state/scratchpad-<projet>.md`). Capture immédiate, zéro friction. Format : date + heure en tête de chaque entrée. Outil exclusif : `bash >> "$FLEET_SCRATCHPAD"` — guillemets obligatoires. Jamais Write, jamais Edit. Rédacteur par scope : projet → dev, LCARS → Starfleet, session architect → architect. Déclenchement autonome : toute convergence de discussion (conclusion, décision, constat, arbitrage, rejet argumenté) est persistée immédiatement. Le critère est la nature de l'échange, pas l'importance perçue.
