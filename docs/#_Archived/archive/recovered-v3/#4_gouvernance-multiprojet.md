# LCARS v3 — Gouvernance multi-projet et couche 3

**Date** : 2026-03-05
**Dernière révision** : 2026-03-08
**Statut** : spécification v3
**Référencé par** : —

---

## 1. La question centrale

LCARS est mono-projet : les agents ont du contexte cDs + rpi-embedded. Il n'y a pas de mécanisme
de gestion multi-projet, pas d'isolation entre bases de connaissance, pas de couche de gouvernance
formelle au-dessus de l'orchestration.

Trois options en présence :

| Option | Description | Verdict |
|---|---|---|
| **Paperclip tel quel** | PostgreSQL + TypeScript + React. Couche gouvernance externe. | NO-GO |
| **TeammateTool (Anthropic)** | Remplacement de notre couche 2 (orchestration) quand activé. | NO-GO couche 2 |
| **Couche 3 custom** | Cherry-pick des mécanismes Paperclip, implémenté dans fleet en bash/Python. | GO |

---

## 2. Pourquoi PAS Paperclip tel quel

Paperclip est bien conçu. Ses mécanismes sont corrects. Mais :

- **Postgres requis** : dépendance non triviale, overhead opérationnel pour notre échelle
- **Zéro retex production** : open-sourcé il y a 48h — aucun feedback sous charge réelle
- **Fonctions non voulues** : budget management, org chart, Clipmart, approval workflows, React UI — soit
  inutiles à notre échelle, soit à risque (Clipmart = même pattern OpenClaw/Cisco)
- **API-médié uniquement** : les agents accèdent via HTTP, pas directement aux fichiers. Incompatible avec
  le modèle actuel où les agents lisent leurs fichiers nativement avec Read tool

Le concept est extrapolable. L'outil n'est pas adopté tel quel.

---

## 3. Pourquoi PAS TeammateTool comme remplacement couche 2

TeammateTool (Anthropic, feature-flagged off dans le binaire Claude Code) sera l'orchestrateur natif.
Quand il sera activé :

- **Modèle forcé** : toutes les analyses disponibles indiquent un mode Opus par défaut (crédité à Gas Town,
  dont l'architecture est reprise). qualifier et builder fonctionnent à Haiku chez nous. Migrer vers Opus = **10x
  de coût** pour des tâches déterministes.
- **Pas de contrôle** : limitation commerciale, roadmap Anthropic, pas de prise sur les paramètres modèle
  par rôle
- **Notre couche 2 est fonctionnelle** : orchestration à la main, moins performante théoriquement, mais
  model-agnostic, full-control, extensible

**Décision** : conserver la couche 2 LCARS. La robustifier (fixes documentés : atomic write broker,
paste-buffer wake). TeammateTool sera évalué uniquement si notre couche 2 montre des limites concrètes
non résolvables.

La hiérarchie Fleet/Métier/Projet n'existera jamais dans TeammateTool (trop spécifique par domaine) — c'est
précisément notre valeur ajoutée, non remplaçable.

---

## 4. La stack 3 couches — définitive

```
Couche 3 — Gouvernance / multi-projet (LCARS custom, cherry-pick Paperclip)
    Qui fait quoi, sur quel projet, avec quelle base de connaissance
    Injection de contexte à la demande (fleet-init-project.sh)
    Isolation des bases de connaissance par projet
         │
Couche 2 — Orchestration agents (LCARS custom, couche actuelle robustifiée)
    IPC handoffs, StarFleet, wake/notify, fleet-broker
    NDI beads, CI gate, escalade BÉTON
    Model-agnostic : Haiku/Sonnet/Opus par rôle
         │
Couche 1 — Runtime agents (Claude Code par instance)
    Isolation Linux per-user (OS-level, inviolable)
    Sessions persistantes, mémoire per-agent
```

TeammateTool appartient à la couche 2. S'il devient utile un jour, il remplace notre couche 2
sans toucher aux couches 1 et 3.

---

## 5. Multi-projet : architecture cible

### 5.1 Problème actuel

Les agents ont le contexte suivant mélangé dans leurs homes :
- `memory/` : notes cDs + notes LCARS + rpi-embedded
- Aucune isolation : un agent qui travaille sur cDs "sait" des choses sur LCARS et vice-versa
- Pas de mécanisme de switch : si demain on démarre un projet Django, les agents doivent être
  re-briefés manuellement

### 5.2 Modèle cible

```
Bases de connaissance :
  /local/<project>/             → projet actif (code + docs)
  /home/commons/knowledge/
    lcars-fleet/                → LCARS-fleet lui-même (toolkit, directives)
    cDs/                        → cDs archivée (domain rpi-embedded inclus)
    rpi-embedded/               → domaine transverse (partagé entre projets embarqués)
    <nouveau-projet>/           → créé par fleet-init-project.sh

Agent homes :
  ~/life/                       → PARA memory (knowledge graph)
  ~/life/projects/<project>/    → contexte projet actif
  ~/life/areas/rpi-embedded/    → domaine courant (injecté par fleet-init-project.sh)
  ~/session-startup.md          → briefing projet du jour (éphémère, regénéré)
```

### 5.3 Switching de projet

Lordzurp : "aujourd'hui on bosse sur Django"

1. architect : `fleet-init-project.sh --project django-api --domain python-web`
   - Génère `session-startup.md` pour chaque agent actif
   - Injecte `~/life/projects/django-api/` avec contexte projet
   - Injecte domain `python-web` dans `~/life/areas/`
   - Crée `--add-dir` tmpdir avec les skills projet
2. Agents réveillés lisent leur `session-startup.md` → contexte complet sans re-briefing
3. Base cDs reste intacte dans `/home/commons/knowledge/cDs/` — accessible si besoin

---

## 6. Migration via la fleet — procédure

### Pourquoi pas architect seul

La migration PARA est une quasi-réécriture de la mémoire de chaque agent. Risques si fait seul :
- Perte silencieuse de faits (architect ne connaît pas tous les détails de la mémoire builder)
- Long (plusieurs agents, structures différentes)
- Non validé (pas de qualifier sur la migration elle-même)

### Procédure recommandée : fleet fait sa propre migration

**Prérequis** : v2 multi-user fonctionnel (Phase 0 lordzurp).

**Étape 1 — Archive cDs**

```bash
# Archiver le projet cDs avec son état courant
mkdir -p /home/commons/knowledge/cDs/
cp -r /local/cDs/docs_and_plans/ /home/commons/knowledge/cDs/docs_and_plans/
# Chaque agent archive sa mémoire cDs dans ~/life/archives/cDs/
```

**Étape 2 — Expurger les homes agents**

Les agents n'ont quasiment jamais touché LCARS-fleet. Leurs `memory/*.md` sont pollués cDs.
Nettoyer vers état PARA vide + single seed file :

```bash
# Pour chaque agent (dev, qualifier, builder, starfleet, engineer)
# Vider memory/ vers archives/
# Créer structure PARA vide : ~/life/{projects,areas,resources,archives}/
# Créer ~/life/summary.md avec identité agent uniquement
```

**Étape 3 — Refonder sur LCARS**

fleet-init-project.sh --project lcars-fleet → injecte dans chaque agent home :
- `~/life/areas/lcars-fleet/` : architecture, directives, patterns
- `~/session-startup.md` : "tu travailles sur LCARS v3. Contexte : ..."

**Étape 4 — Fleet implémente LCARS v3**

LCARS-fleet devient le premier projet géré proprement dans le nouveau système.
Dev code, qualifier valide, engineer conçoit, starfleet coordonne.
La migration PARA elle-même est une tâche du projet LCARS-fleet.

### Rôles pendant la migration

| Rôle | Responsabilité migration |
|---|---|
| architect | Plan + supervision lordzurp |
| engineer | Concevoir skill PARA + méthode migration, valider la structure |
| dev | Coder le skill PARA (adaptation du skill Paperclip MIT) |
| qualifier | Valider la structure PARA de chaque agent (summary.md charge ? items.yaml parseable ?) |
| starfleet | Coordonner, débloquer les conflits, fix triviaux |

---

## 7. Cherry-pick Paperclip — liste finale

### GO (à implémenter)

| Mécanisme | Où | Phase |
|---|---|---|
| **Atomic bead checkout** (flock + atomic write) | fleet-broker.py, bead write | 1 |
| **Goal ancestry** dans session-startup.md | fleet-init-project.sh | 5 |
| **Skill injection via --add-dir** | fleet-init-project.sh + agent spawn | 3/5 |
| **Heartbeat dedup précis** : "skip si aucun nouveau contexte depuis dernier engagement" | CLAUDE.md agents + directives escalade | 2 |
| **PARA memory structure** : summary.md + items.yaml, jamais supprimer seulement superseder | deploy.sh + skill PARA | 4 |

### NO-GO explicite

| Mécanisme | Raison |
|---|---|
| Budget enforcement (`spentMonthlyCents >= budgetMonthlyCents`) | Hors besoin — lordzurp: "osef du budget limit" |
| Org chart (`reportsTo`) | Linux user isolation = org chart plus robuste |
| Approval workflows | StarFleet gère conversationnellement |
| PostgreSQL / Drizzle ORM | Overhead non justifié, dépendance non triviale |
| React UI | fleet-monitor.py TUI suffit |
| Clipmart marketplace | Risque sécurité documenté (OpenClaw/Cisco pattern) |
| Heartbeat poll architecture | On est event-driven (fleet-fetch.timer) — pas de poll |

---

## 8. PARA memory — détail implémentation

Le skill Paperclip est MIT, lisible dans `/tmp/paperclip/skills/para-memory-files/`.

### Structure cible LCARS

```
~/life/
  summary.md          → charge rapide au démarrage (<500 tokens) — résumé identité + projets actifs
  index.md            → index complet des entités connues

  projects/           → knowledge graph projets
    lcars-fleet/
      summary.md
      items.yaml      → faits atomiques : { id, statement, status, created, superseded_by }
    cDs/
      summary.md
      items.yaml

  areas/              → domaines de compétence
    rpi-embedded/
      summary.md
      items.yaml
    lcars-fleet/      → architecture LCARS, conventions, patterns

  resources/          → références externes (datasheets, libs, tools)
  archives/           → projets terminés / faits obsolètes

~/daily/
  2026-03-05.md       → journal quotidien (actions, bugs rencontrés, décisions)

~/tacit/
  lordzurp-prefs.md   → préférences implicites détectées (style de code, communication)
```

### Règle absolue

Un fait dans `items.yaml` n'est jamais supprimé. Il est supersedé :

```yaml
- id: lcars-broker-atomicity-001
  statement: "fleet-broker.py utilise write_text direct — non atomique"
  status: superseded
  superseded_by: lcars-broker-atomicity-002
  created: 2026-03-05

- id: lcars-broker-atomicity-002
  statement: "fleet-broker.py utilise tmpfile + os.replace() — atomique"
  status: active
  created: 2026-03-05
```

L'historique est complet. Aucune connaissance ne se perd silencieusement entre sessions.

---

## 9. Intégration au plan v3 — phases supplémentaires

Ces décisions s'ajoutent au plan existant (`v3-specs-plan.md`) :

### Phase 0 enrichie (prérequis migration)

- [ ] Archive cDs : `/home/commons/knowledge/cDs/` avec docs + memory agents
- [ ] Structure PARA vide dans chaque home agent (post-install-user.sh)
- [ ] fleet-init-project.sh minimal : génère session-startup.md avec goal ancestry

### Phase 4 enrichie (PARA + migration)

- [ ] Copier/adapter skill PARA depuis /tmp/paperclip/skills/para-memory-files/ (MIT)
- [ ] Migration memory/*.md → items.yaml pour chaque agent
- [ ] Validation qualifier : summary.md < 500 tokens, items.yaml parseable YAML
- [ ] deploy.sh : créer structure ~/life/ dans post-install-user.sh

### Phase 5 enrichie (multi-projet opérationnel)

- [ ] fleet-init-project.sh complet avec --add-dir, goal ancestry, PARA injection
- [ ] Procédure switching projet : guide opérateur (30s, pas de re-briefing)
- [ ] Test end-to-end : switch cDs → lcars-fleet → cDs sans perte de contexte

---

## 10. TODO — Formalisation des niveaux de documentation

**Constat** : les docs actuels mélangent des natures différentes sans convention explicite :
- `insights-*.md` : analyses ponctuelles de projets externes
- `v3-*.md` : specs et plans d'implémentation v3
- `architecture-lcars.md`, `knowledge-hierarchy.md` : références stables
- `work/doing/*.md` : plans de travail en cours (gitignored)

**À formaliser** : une convention claire `guides_FR/` sur les types de docs, leur cycle de vie, et
qui en est l'auteur-type. À traiter comme première tâche fleet sur LCARS-fleet (dog-fooding).

Proposition de niveaux :

| Type | Prefix | Cycle de vie | Auteur | Description |
|---|---|---|---|---|
| **Insight** | `insights-` | Ponctuel, archivé | architect/fleet | Analyse d'un projet externe. Snapshot. |
| **Spec** | `v<N>-` | Vivant jusqu'à implémentation, puis archivé | architect/fleet | Spécification d'une feature ou d'un système. |
| **Guide** | (pas de prefix) | Stable, mis à jour | engineer | Référence opérationnelle permanente. |
| **Plan** | `work/doing/` | Éphémère, gitignored | tout agent | Plan de travail en cours. Ne survit pas au milestone. |

---

## 11. Isolation de contexte — modèle explicite

Ce point est contre-intuitif et doit être explicitement documenté.

### Qui sait quoi

| Agent | Mode | Connaît | Ne connaît PAS |
|---|---|---|---|
| dev, qualifier, builder | projet | Projet actif + domaine (rpi-embedded) | LCARS internals |
| arch-fleet | projet | Projet actif (tête dans le guidon) | LCARS internals (dormant) |
| arch-fleet | LCARS | Toolkit LCARS complet | Projet actif |
| arch-lead | toujours | Toolkit LCARS + interface lordzurp | — |
| starfleet | toujours | Métadonnées projet (project.yaml) | LCARS internals, code projet |

arch-fleet a une connaissance LCARS mais elle est **dormante** quand il travaille sur un projet.
Il ne l'utilise pas, ne la mentionne pas, ne pollue pas les agents projet avec.

### Le problème du bug env

Un agent projet (dev cDs) rencontre un problème. Il ne peut pas savoir si c'est :
- Un bug dans son code cDs
- Un bug dans l'environnement LCARS (broker, wake, IPC, hooks)

Il escalade normalement vers starfleet via `to-starfleet.md`.

### Rôle filtre de starfleet

StarFleet reçoit l'escalade et applique un filtre déterministe basé sur les **chemins de fichiers** :

```
Escalade reçue de [agent] sur [projet]
        │
        ├─ Fichiers mentionnés dans /local/<projet>/ ou /home/commons/[domaine] ?
        │   → Bug projet → traiter ou dispatcher vers arch-fleet selon complexité
        │
        ├─ Fichiers mentionnés dans /local/LCARS-fleet/ ou /home/commons/fleet/ ?
        │   → Bug env → transférer à arch-lead, NE PAS traiter
        │
        └─ Ambiguïté (même technologie des deux côtés, path unclear) ?
            → Escalade immédiate à lordzurp, attente humain
            → NE PAS deviner
```

Le filtre est **lexical sur les paths**, pas un jugement LLM. Si le path discrimine → route.
Si le path ne discrimine pas → l'humain est juge de paix.

_Note 2026-03-08 : ce filtre s'applique aux escalades INFRA reçues par StarFleet. Les escalades projet (spec ambiguë, décision archi, bead bloquée) vont directement à Lead — StarFleet ne les reçoit pas. Cf. `#3_v3-directive-levels-escalade.md` §3.2._

**Pourquoi starfleet et pas arch-fleet** : arch-fleet est tête dans le guidon sur son projet.
Lui rajouter un rôle de filtre inter-contexte c'est ajouter des tokens inutiles ET risquer la pollution
de sa mémoire projet. StarFleet est léger par design — c'est son rôle de "ranger les choses au bon endroit".

**TODO** : ajouter ce filtre dans les directives starfleet, avec la liste des paths LCARS connus.

---

## 12. LCARS-fleet comme projet — le cas récursif

### LCARS est un projet comme les autres

LCARS-fleet n'est pas un cas spécial. C'est un projet dans le système qu'il implémente lui-même.
Il a son `project.yaml`, sa base de connaissance dans `/home/commons/knowledge/lcars-fleet/`,
ses beads, son CI gate, ses agents dédiés.

```
lordzurp veut travailler sur LCARS aujourd'hui
    │
arch-lead : fleet-init-project.sh --project lcars-fleet
    │
    └─── fleet LCARS (éphémère, spinée pour la tâche)
             ├─ starfleet   : coordination, filtre env/projet
             ├─ dev          : code toolkit, connaît LCARS-fleet
             ├─ qualifier           : teste les composants fleet
             └─ (builder)    : deploy.sh, si besoin
```

La fleet arrive avec le contexte LCARS complet injecté par fleet-init-project.sh.
Elle fait le job. Elle écrit ses notes dans la base de connaissance lcars-fleet/.
Elle est killée. Seul arch-lead persiste.

### Le cas d'école parfait — onboarding

LCARS livre avec lui-même comme premier projet à étudier. Un nouvel utilisateur peut
apprendre comment fonctionne le système en travaillant dessus — pas sur un projet fictif.

**Reset pour évaluation / apprentissage** :

```bash
# Violent mais chirurgical en phase eval
git -C /local/LCARS-fleet fetch --all
git -C /local/LCARS-fleet reset --hard origin/main
# Les projets hors LCARS (cDs, etc.) sont dans des repos séparés → non affectés
```

**TODO** : vérifier formellement qu'un projet "standard" (cDs) survit à un reset dur de LCARS-fleet.
C'est le test d'intégration de l'isolation : si cDs perd des données suite à un reset LCARS, l'isolation
est cassée. Si cDs est intacte, l'isolation est prouvée.

### Le point méta

LCARS gère ses propres évolutions via les outils qu'il est en train de construire. La fleet qui
implémente LCARS v3 est elle-même une instance de LCARS. C'est fonctionnellement récursif — et c'est
précisément ce qui valide l'architecture par dog-food continu.

---

## 13. IPC et return-address — faux problème

### Pourquoi c'est pré-adressé

Le friction documenté (arch-lead → qualifier, réponse interceptée par arch-fleet) vient du fait que les
deux architectes partagent `to-architect.md`. Ce problème disparaît avec l'isolation multi-projet :

- Chaque fleet instanciée pour un projet a son propre espace IPC
- La fleet LCARS et la fleet cDs ne partagent pas leurs canaux
- arch-lead dans une session LCARS et arch-fleet dans une session cDs opèrent sur des fichiers distincts

La couche 3 (fleet-init-project.sh) isole les espaces IPC par projet. Le return-address n'est plus ambigu
puisqu'une fleet ne peut pas recevoir les messages d'une autre fleet.

### La solution immédiate si besoin avant couche 3

Splitter les fichiers : `to-arch-lead.md` et `to-arch-fleet.md`. Chacun lit uniquement son canal.
Zéro code broker, zéro metadata, compatible avec le système actuel. C'est suffisant.

Les broker IDs (`from/to/reply-to`) restent utiles pour l'observabilité et l'audit trail — pas pour
résoudre ce friction précis.

---

## 14. TODO — Nommage des agents (finalisation)

**Constat** : "architect" et "engineer" sont longs à taper (3 syllabes de plus que nécessaire).
Convention cible : noms courts, 2 segments max, lisibles dans les logs et les handoffs.

### Proposition nommage court

| Nom court | Tier | Linux user | Persistant | Rôle |
|---|---|---|---|---|
| starfleet | 0 | starfleet | Oui | Routing, dispatch, filtre env/projet. N'agit sur rien. |
| arch-lead | 1 | lordzurp | Oui — non-wakeable | Interface lordzurp, contexte LCARS, spawn fleet LCARS |
| arch-fleet | 1 | engineer | Oui — wakeable | Toolkit LCARS, fleet autonome |
| dev | 2a | dev | Oui — mémoire inter-session | Code + commits projet actif |
| qualifier | 2a | qualifier | Oui — mémoire inter-session | Tests uniquement |
| builder | 2a | builder | Oui — mémoire inter-session | Build/deploy |
| doc | 2b | doc-writer | Non — éphémère | Documentation |
| sec | 2b | sec-auditor | Non — éphémère | Review sécurité |
| search | 2b | search-agent | Non — éphémère | Recherche doc externe |

**Tier 0** : starfleet est au-dessus de la hiérarchie Tier 1/2, non parce qu'il a plus de pouvoir,
mais parce qu'il est le prérequis de coordination. Sans lui les fleets fonctionnent mais ne se coordonnent
plus. Il n'agit jamais directement sur le code ou l'infra — il oriente.

*Les deux architectes sont de skill et rôle équivalents. Le scope seul diffère.*

**TODO** : valider cette liste avant Phase 3. À formaliser dans `home_claude_CLAUDE.md` (section Instance scope).

---

## 15. StarFleet Tier 0 — modèle interrupt-driven

### Ce qu'il est

StarFleet est le prérequis de coordination de la fleet. Il ne surveille rien en continu.
Il ne poll aucun canal. Par défaut, il dort.

Il a deux et seulement deux modes de réveil :

1. **Escalade entrante** : un agent écrit dans `to-starfleet.md` → fleet-broker notifie → starfleet wake
2. **Maintenance planifiée** : tâches autonomes schedulées (beads IN_PROGRESS périmées, canaux trop anciens,
   état fleet incohérent)

### Pourquoi c'est critique

Un starfleet qui "surveille" activement consomme des tokens en permanence, proportionnellement au nombre
d'agents actifs — indépendamment du fait qu'il y ait quelque chose à faire.

Un starfleet interrupt-driven consomme des tokens **proportionnellement aux problèmes**.
Un projet qui tourne bien → starfleet quasi muet. C'est le bon signal : le coût opérationnel reflète
la santé du système.

### Le SPOF passif

StarFleet est SPOF — s'il est indisponible, la coordination est suspendue. Mais :

- **SPOF passif** : son indisponibilité ne cause pas d'action incorrecte. Les fleets continuent leur
  travail en cours. Les escalades s'accumulent dans `to-starfleet.md` et attendent.
- **SPOF actif** (ce qu'il n'est pas) : son indisponibilité causerait des actions erronées ou une
  corruption d'état.

L'attente est récupérable. L'action incorrecte peut ne pas l'être.

### Auto-protection des fleets

Si starfleet ne répond plus, les fleets ne s'emballent pas. Elles appliquent le circuit breaker :
escalade sans réponse → stop work → écriture des beads IN_PROGRESS → attente humain.
Le NDI (bead + acceptance criteria) garantit la reprise propre sans starfleet.

### StarFleet n'agit sur rien

StarFleet route, filtre, dispatch. Il n'écrit pas de code, ne compile pas, ne commit pas,
ne modifie pas l'infra. Si une action est nécessaire, il désigne l'agent qui va l'exécuter.

C'est cette passivité qui rend le SPOF tolérable.

---

*Analyse produite par arch-lead — session 2026-03-05*
