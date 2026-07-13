# Protocole utilisateur — mots-clés

**Date** : 2026-03-07
**Dernière révision** : 2026-03-11
**Statut** : référence active — source de vérité, read-only sauf bug-fix documenté
**Référencé par** : .claude/CLAUDE.md

## Règles du protocole — lire avant tout

**Ce fichier est une source de vérité primaire.** Il ne dérive d'aucun autre fichier. Fichier compagnon : `#4-1_protocole-user.md` (personnalisation des mots-clés de session).

**Rien n'est implicite.** Chaque mot-clé, chaque comportement, chaque nuance est documenté explicitement. Un comportement non documenté n'existe pas — il n'est pas "évident", il est absent. L'agent n'infère pas, il applique.

**Canal exclusif** : tout mot-clé destiné à l'interaction user→agent DOIT être défini dans ce fichier. Définir un mot-clé ailleurs (CLAUDE.md, glossaire, autre directive) sans l'inscrire ici est une violation GO-0.

**Non personnalisable.** Aucun mot-clé défini ici ne peut être modifié, renommé, ou substitué. La seule personnalisation autorisée concerne deux mots-clés de contrôle de session dans `#4-1_protocole-user.md`. Ce fichier est le contrat d'interaction, pas un template.

**Read-only.** Les directives canoniques ne se modifient pas en session. Toute modification est un bug-fix documenté (date + motif) ou une décision architecturale versionnée. Un agent ne modifie jamais une directive de sa propre initiative.

**Règle d'exécution** : si l'agent a exprimé une préférence claire et que l'user la confirme sans restriction, l'agent exécute immédiatement sans redemander.

**Règle de non-interprétation** : un mot-clé entre backticks `` `go` `` n'est pas actif — c'est une référence au mot-clé, pas une commande. Guillemets `"..."` : comportement non défini, non garanti.

**Règle du `:` terminal** : un mot-clé suffixé `:` est un **préfixe** — ce qui suit est le contenu rattaché (`TODO: écrire le registre IPC`). Un mot-clé sans `:` s'applique au contexte courant ou à la cible nommée après lui (`évalue ce fichier`). Le `:` n'est jamais optionnel : `note:` et `note` seraient deux mots-clés distincts.

**Résolution de conflits** : plusieurs mots-clés actifs dans un même message sont traités séquentiellement dans l'ordre d'apparition. Si deux mots-clés produisent des effets contradictoires sur la même cible, le dernier l'emporte. Séparés par `===` : blocs indépendants, traités en entier l'un après l'autre — aucun effet de bord croisé entre blocs.

**Modificateurs sur mots-clés composés** : un modificateur s'applique au mot-clé composé entier. `dry-update mineure` = simulation de `update mineure` (scope réduit + sans side effect). Le modificateur attache au premier token, le composé est parsé comme une unité.

**Erreur protocolaire** : si l'agent détecte une incohérence (mots-clés contradictoires sur le même token, comportement non documenté demandé) : signale en une ligne, demande disambiguation avant d'agir. Ne résout pas de sa propre initiative.

---

## Contrôle de session

Les deux premiers mots-clés sont personnalisables (voir `#4-1_protocole-user.md` pour les valeurs actives). Les autres sont figés.

| Mot-clé | Comportement | Personnalisable |
|---|---|---|
| *(reprise de session)* | Lire le handoff, reprendre sans recap ni questions | oui — voir `#4-1_protocole-user.md` |
| *(fermeture de session)* | Clôture propre via skill /handoff. Casse insensible. | oui — voir `#4-1_protocole-user.md` |
| `quiet` | Réduit l'output à une ligne par action pour la session. Reset en fin de session. | non |
| `verbose` | Affiche le raisonnement intermédiaire pour chaque action. Reset en fin de session. | non |

---

## Mots-clés d'analyse — lecture seule

Colonne `niv.` — granularité de l'output : ⚡ = court/inline · 📋 = structuré · 🔭 = exploration large · — = non scalable.
Grammaire : chaque domaine thématique forme un triplet ⚡ · 📋 · 🔭 ou un singleton quand la granularité variable n'a pas de sens. Les renvois entre groupes évitent la duplication.

### Évaluation

| niv. | Mot-clé | Contexte | Comportement | Nuance | Output attendu |
|---|---|---|---|---|---|
| ⚡ | `avis` | Décision design ou archi | Opinion courte + justification | `avis ?` fin de phrase → dernière phrase uniquement · `évalue` → prompt entier | Texte court inline |
| 📋 | `évalue` | Artefact ou input | Assessment structuré : points forts · manques · corrections | Cible sémantique/contenu · pas de cross-check sources · `qualifie` = forme | Sections structurées |
| 🔭 | `analyse` | Fichier ou sujet à explorer | Exploration profonde : implications · gaps · dépendances | Lit les sources par défaut · sans lecture = valeur nulle · exception si l'objet est explicitement le texte du doc | Rapport long |

### Clarification

| niv. | Mot-clé | Contexte | Comportement | Nuance | Output attendu |
|---|---|---|---|---|---|
| ⚡ | `précise` | Point à clarifier | Clarifie directement — pas une action | Un point dans le fil courant · `explicite` = développé · `explique` = objet entier | Réponse directe inline |
| 📋 | `explicite` | Proposition ou point ciblé | Développe et détaille l'objet ciblé | Position libre — début ou fin de phrase · `précise` = clarification courte · `explique` = objet entier | Réponse développée inline |
| 🔭 | `explique` | Module, archi, concept, code | Transmission pédagogique à profondeur variable | 1 = survol · 2 = structuré + exemples · 3 = deep dive · `précise` = un point · `explicite` = développé | Texte structuré |

### Recherche

| niv. | Mot-clé | Contexte | Comportement | Nuance | Output attendu |
|---|---|---|---|---|---|
| ⚡ | `résumé` | Contexte courant ou document fourni | Condensé en quelques lignes — sans recherche web | Depuis le contexte uniquement · `tldr` = recherche web | Résumé inline |
| 📋 | `tldr` | Sujet ou question à rechercher | Recherche web + brief condensé inline | Interroge le web, pas le contexte courant · `analyse` = exploration interne | Brief inline + sources |
| 🔭 | *(Claude web)* | Recherche profonde | Hors protocole — délégué à Claude web | Pas de mot-clé protocole à ce niveau | — |

### Code

| niv. | Mot-clé | Contexte | Comportement | Nuance | Output attendu |
|---|---|---|---|---|---|
| 📋 | `review` | Code source (fichier, fonction, module) | Analyse code : correctness · sécurité · performance · patterns · dette | Code exécutable uniquement · lit le code par défaut · `évalue` = artefact textuel · `audit` = systématique fichier par fichier (§ Rapport fichier) | Sections structurées |

### Vérification

| niv. | Mot-clé | Contexte | Comportement | Nuance | Output attendu |
|---|---|---|---|---|---|
| ⚡ | `valide ?` | Formulation ou proposition | Confirme ou corrige — jamais d'action déclenchée | Checkpoint pur · `correct ?` = compréhension concept · `raccord ?` = compréhension + exécution | Confirmation inline |
| 📋 | `controle` | Fichier(s) + liste de corrections | Compare état actuel vs liste · valide chaque point | Vérification binaire · `évalue` = explore contenu · `analyse` = explore implications | Statut par point (✅ / ❌ / ⚠️) |
| 🔭 | `inspecte` | Système, dossier ou ensemble de fichiers | Vérification exhaustive et méthodique — conformité, cohérence, références | `controle` = liste connue · `inspecte` = exploration sans liste préétablie · `audit` = code spécifiquement | Rapport exhaustif structuré |

### Audit externe

| niv. | Mot-clé | Contexte | Comportement | Nuance | Output attendu |
|---|---|---|---|---|---|
| 📋 | `qualifie` | Document ou fichier | Qualité formelle + verdict explicite | Cible forme/qualité · pas de cross-check sources · `évalue` = contenu · `ponce` = repo entier (§ Rapport fichier) | Sections structurées + verdict |

### Standalone

| niv. | Mot-clé | Contexte | Comportement | Nuance | Output attendu |
|---|---|---|---|---|---|
| — | `x/10` | Proposition ou feature | Score 0→10 + 2 lignes d'explication | 0 = trivial · 10 = critique · priorisation rapide, pas une analyse | Score + 2 lignes inline |

### Closing gate — règle transversale

Tout output d'analyse décisionnelle inline (`avis`, `évalue`, `qualifie`, `analyse`, `review`, `controle`, `inspecte`) se termine par : **score x/10 + une question de routing** (`backlog ?`, `now ?`, `nope ?`, ou variante contextuelle). L'agent propose, l'user route en un mot.

**Exclusions closing gate** : `résumé`, `précise`, `explicite`, `explique`, `tldr`, `x/10` — outputs purement informatifs, pas de point de décision. `ponce`, `reverse`, `audit` — le score est dans le bilan fichier, l'opération est autonome (pas de routing post-livraison).

### Modificateurs — `re-`, `up-`, `dry-`, `cross-`

Quatre préfixes applicables à tout mot-clé. Le tiret est obligatoire.

| Modificateur | Effet | Exemple |
|---|---|---|
| `re-` | Rejoue l'action précédente du même mot-clé. Output : **diff** vs l'output précédent — ce qui a changé, disparu, apparu. Pas de répétition de l'identique. | `re-analyse`, `re-évalue` |
| `up-` | L'user a modifié le document cible. Re-traite avec les yeux neufs — pas un diff, une nouvelle passe. Le contenu des edits (annotations, corrections, instructions) est interprété à la lecture. Remplace `commenté`. | `up-évalue`, `up-applique` |
| `dry-` | Simule l'action sans effet de bord. S'applique à tout mot-clé ayant un side effect fichier : actions (`update`, `applique`, `fix`, `append`, `+xxx`…) et rapport fichier (`ponce`, `reverse`, `audit`). Affiche ce qui serait fait/écrit. Sans effet sur les mots-clés purement inline. | `dry-update`, `dry-audit`, `dry-reverse` |
| `cross-` | Compare deux cibles explicites. Change le mode d'exécution : l'agent lit les deux cibles et produit une analyse comparative. S'étend à tout mot-clé d'analyse. | `cross-analyse A B`, `cross-évalue A B` |

### Rapport fichier — `ponce` · `reverse` · `audit`

Triplet unifié : les **3 seuls mots-clés à effet de bord fichier** du protocole. Tous les autres produisent du output inline uniquement.

| niv. | Mot-clé | Cible | Angle | Outputs fichier | Output inline |
|---|---|---|---|---|---|
| ⚡ | `ponce` | Repo externe (URL) | Réputation + pertinence | `<repo>-brief.md` + `<repo>-insight.md` | Brief condensé |
| 📋 | `reverse` | Repo/dossier (local ou cloné) | Architecture + comportement | `<repo>-specs.md` + `<repo>-architecture.md` | Résumé archi ~10 lignes |
| 🔭 | `audit` | Dossier code | Conformité + dette | `audit-report/*.md` (3 fichiers) | Bilan synthétique |

Propriétés partagées :

1. Génèrent des `.md` persistants — unique dans le protocole
2. Affichage inline condensé + rapports détaillés en fichier
3. Lisent du code (ponce en surface, reverse et audit en profondeur)
4. Progress tracker pour reprise après coupure (`_progress.md`)
5. Contrainte batch : ≤3 fichiers par cycle Read→Write. Au-delà, sub-agents (Agent tool)
6. **Pré-requis** : avant toute action, relire la définition complète du mot-clé dans le protocole. Opérations rares et coûteuses — une erreur de cadrage se paie sur toute la durée

---

### Rapport fichier — `ponce`

Cible : repo externe (URL fournie ou recherche GitHub — 98% des sources ; GitLab privé = URL fournie par user). Scope : le repo entier — métriques + code.

Séquence obligatoire :

1. Clone si absent
2. Collecter les métriques de réputation (API GitHub/GitLab)
3. Scan structure : arborescence, entry points, dépendances, build system
4. Lecture ciblée du code : méthodes clés, patterns, qualité générale
5. **Écrire** brief puis insight — chaque Write est un checkpoint

Le rapport est incrémental : si la session coupe, le brief partiel est exploitable.

Progress tracker : écrire dans `<repo>-ponce/_progress.md` l'état d'avancement (métriques collectées, fichiers lus, rapports écrits).

Métriques de réputation évaluées :

1. Ancienneté du repo
2. Date de dernière activité
3. Nombre de stars
4. Nombre de forks
5. Nombre de commits
6. Nombre de PRs
7. Réactivité du owner sur les issues
8. Nombre de contributors actifs
9. License
10. Dépendances transitives (si library)

Les deux outputs sont toujours produits (si un seul est demandé, c'est un `analyse`, pas un `ponce`) :

1. **brief** — rapport de crédibilité, specs fonctionnelles, pertinence projet en cours, méthodes intéressantes à extraire, avis global → sauvé en `<repo>-brief.md`
2. **insight** — rapport d'analyse long, code des méthodes clés → sauvé en `<repo>-insight.md`

Affichage : brief condensé affiché directement pour retour immédiat ("repo toxique", "bonne source", avec justification courte).

---

### Rapport fichier — `reverse`

Cible : repo ou dossier de code (local ou cloné via `ponce`). Scope : **TOUS** les fichiers source — aucun skip, aucun raccourci. Reconstruit les specs fonctionnelles et l'architecture à partir du code — le code est la source de vérité.

Séquence obligatoire :

1. Scan structure : arborescence, entry points, build system, dépendances
2. Lecture systématique des fichiers sources (batch ≤3 par cycle)
3. Pour chaque module/composant : extraire responsabilité, API publique, dépendances, flux de données
4. **Écrire** les findings dans le rapport (append) — AVANT de Read le bloc suivant
5. Consolidation : architecture globale, patterns, flux inter-composants
6. Écriture du rapport final

Le rapport est incrémental : chaque Write est un checkpoint. Si la session coupe, le rapport partiel est exploitable.

Progress tracker : à chaque cycle, écrire dans `<repo>-reverse/_progress.md` les fichiers traités et restants. Vérifier avant chaque Read si le fichier est déjà traité — si oui, skip.

Points d'analyse par module :

1. Architecture globale (modules, couches, patterns)
2. Entry points et flux d'exécution principaux
3. API publiques (signatures, contrats, types)
4. Dépendances internes (qui appelle qui)
5. Dépendances externes (libs, services)
6. Gestion d'état (storage, caches, config)
7. Protocoles et formats (wire protocols, fichiers, IPC)
8. Contraintes implicites (timing, ordering, limites)

Les deux outputs sont toujours produits (si un seul est demandé, c'est un `analyse`, pas un `reverse`) :

1. **specs** — specs fonctionnelles reconstruites, structurées par module/composant : responsabilité, API, flux, dépendances, contraintes → sauvé en `<repo>-specs.md`
2. **architecture** — vue d'ensemble : diagramme textuel de l'archi, patterns identifiés, décisions de design inférées, zones grises et dette documentaire → sauvé en `<repo>-architecture.md`

Affichage : résumé archi inline (~10 lignes) — entry points, stack, pattern dominant, taille estimée du projet.

---

### Rapport fichier — `audit`

Cible : dossier complet ou ensemble de fichiers de code. Scope par défaut : **TOUS** les fichiers du dossier cible — aucun skip, aucun raccourci.

Séquence obligatoire par bloc structurel :

1. Read fichiers du bloc N (≤3 par cycle)
2. Analyser : conformité, méthodes, procédures, liens inter-fichiers
3. Auditer : bugs, patterns, dette technique, sécurité, références cassées, erreurs triviales
4. **Écrire** les findings dans le rapport du bloc (append) — AVANT de Read le bloc N+1
5. Proposer corrections si applicable

Le rapport est incrémental : chaque Write est un checkpoint. Si la session coupe, le rapport partiel est exploitable.

Progress tracker : à chaque checkpoint, écrire dans `audit-report/_progress.md` la liste des fichiers traités et restants. Avant chaque Read, vérifier dans `_progress.md` s'il est déjà traité — si oui, skip.

Points d'analyse évalués par fichier :

1. Conformité (headers, conventions, style)
2. Méthodes et procédures implémentées
3. Liens et dépendances inter-fichiers
4. Bugs et erreurs triviales
5. Patterns et anti-patterns
6. Dette technique
7. Sécurité (injections, permissions, secrets)
8. Références cassées (imports, paths, variables)

Les trois outputs sont toujours produits (si un seul est demandé, c'est un `analyse`, pas un `audit`) :

1. **rapport détaillé** — un fichier `.md` par bloc structurel du dossier audité (ex : `01-core-audit.md`, `02-ipc-helpers-audit.md`…), analyse exhaustive structurée sur les 8 points ci-dessus → sauvé dans `audit-report/NN-<bloc>-audit.md`
2. **rapport dérives** — consolidation de TOUTES les dérives, références cassées, erreurs triviales découvertes sur l'ensemble du dossier → sauvé dans `audit-report/dérives.md`
3. **bilan synthétique** — résumé de ce qui a été fait et découvert, métriques observées (fichiers lus, dérives détectées, erreurs critiques vs mineures), conclusion ~5 lignes, score x/10 de l'audit → sauvé dans `audit-report/bilan.md`

Affichage : le bilan synthétique est présenté en fin d'audit pour retour immédiat. Les rapports détaillés restent dans `audit-report/` — l'user consulte à la demande.

---

## Validation / exécution

| Mot-clé | Contexte | Comportement |
|---|---|---|
| `ok` | Proposal en attente | Valide + proceed |
| `ok pour X` | Proposal partielle | Valide X uniquement. Le reste reste ouvert |
| `go` | Action planifiée | Exécute. Peut interrompre si ambiguïté ≥ 6/10 |
| `GO` | Idem, plus fort | Exécution immédiate, zéro interruption même en cas d'ambiguïté mineure |
| `fais X` | Étape nommée | Exécute X explicitement. Scope limité à X, pas d'extension implicite |
| `scope?` | Avant exécution d'une action large | Liste les fichiers, fonctions et modules qui seront touchés — sans agir. Transparence pré-action. Ne remplace pas `raccord` (compréhension) — cible le périmètre concret. |

### Nuances go / GO / fais X

1. **`go`** — exécute le plan tel que discuté. Peut signaler un bloqueur ou demander si ambiguïté ≥ 6/10.
2. **`GO`** — aucune interruption. Réserver aux séquences validées à 100%.
3. **`fais X`** — désigne une étape nommée précisément. Pas de débordement de scope.

### Nuances ok / ok pour X

1. **`ok`** — valide l'ensemble de la proposal en attente.
2. **`ok pour X`** — valide X uniquement. Après exécution : représenter les points restants + bilan de l'action.

---

## Modification

| Mot-clé | Contexte | Comportement |
|---|---|---|
| `update` | Après discussion | Applique les modifications discutées |
| `update mineure` | Idem, scope réduit | Périmètre limité à la correction discutée uniquement. Pas d'extension |
| `applique` | Doc cible explicite ou modifier `up-` | Applique les instructions trouvées dans le document. Requiert une référence (`applique fichier.md`) ou le modifier `up-` |
| `corrige` | Après qualifie / évalue | Applique les corrections identifiées par l'agent dans sa propre analyse. Demande précision si le choix est purement stylistique |
| `fix` | Point(s) identifié(s) à corriger | Applique immédiatement la correction sur le(s) point(s) cité(s). `fix 1, 3` = points 1 et 3 uniquement. Scope strict — pas d'extension implicite |
| `draft` | Contenu à produire (doc, spec, texte) | Produit un brouillon sans side effect définitif — pas d'écriture de fichier. Cycle attendu : `draft` → review user → `update` ou `go` pour finaliser. L'agent signale explicitement que l'output est un draft. |
| `diff` | État courant vs dernier état stable | Affiche tout ce qui a changé depuis le dernier `update` ou état stable. Pas une simulation — un constat. |

`update` seul = après discussion. Pas d'ambiguïté avec "update" suivi d'un doc (contexte différent — sinon demander).

**Fallback hors-contexte** : si un mot-clé d'action est utilisé sans contexte préalable requis (`fix` sans analyse identifiée, `corrige` sans `qualifie`/`évalue` préalable) : l'agent signale le contexte manquant en une ligne et demande de confirmer ou de fournir le contexte avant d'agir.

### Nuances update / update mineure / corrige

1. **`update`** — applique tout ce qui a été discuté depuis le dernier état stable.
2. **`update mineure`** — une seule correction ciblée. Ne pas profiter du passage pour nettoyer ou étendre.
3. **`corrige`** — l'agent applique ses propres corrections issues d'un `qualifie` ou `évalue` précédent. Demande confirmation uniquement si le choix est purement stylistique (pas de bonne réponse objective).

### Nuance TUI vs fichier

- **Mode fichier** (éditeur ouvert) : une ligne de confirmation suffit — l'auto-refresh de l'éditeur montre le diff. Format : `nom-fichier.md — nature du changement`.
- **Mode TUI** (pas d'éditeur) : représenter le bloc modifié dans la réponse.

---

## Meta-conversation

| Mot-clé | Contexte | Comportement |
|---|---|---|
| `idée` | Proposition à évaluer | L'user lance une idée dans le contexte du moment. Avis court : pertinent maintenant ? conflit avec l'approche en cours ? bon timing ? Pas d'action |
| `question` | Demande de réponse | L'user pose une question. L'agent répond, n'exécute pas. Pas d'action déclenchée sauf si suivie d'un `go` ou `ok` |
| `raccord` / `raccord ?` | Validation de compréhension pré-exécution | L'user soumet sa compréhension d'une proposition agent. Si correct : l'agent exécute. Si non : l'agent montre l'erreur de compréhension et corrige — l'agent ne plie PAS sa proposition pour se conformer à une compréhension erronée. **Exception au modèle général** : seul mot-clé qui déclenche une exécution sans `go`/`ok` explicite. |
| `correct ?` | Vérification de compréhension | L'user vérifie sa compréhension d'un concept ou mécanisme · l'agent confirme ou réexplique · pas d'action déclenchée — `raccord ?` si une action doit suivre |
| `valide ?` | Confirmation d'une formulation | Voir § Vérification — checkpoint pur, jamais d'action déclenchée |
| `nope` | Rejection | Rejette. Proposer une alternative, ne pas insister |
| `reroll` | Réponse incohérente ou question ouverte | Rejoue la même séquence pour obtenir un output statistiquement différent. Utile quand le premier token a mal orienté la génération, ou sur des questions ouvertes sans bonne réponse unique |

---

## Observations et digressions

Famille de préfixes **interrupt** : l'user signale un point orthogonal à la tâche en cours. Syntaxe : préfixe en début de phrase (comme `TODO:`, `note bien:`). Niveaux ⚡→📋→🔭.

| niv. | Préfixe | Contexte | Comportement |
|---|---|---|---|
| ⚡ | `note:` | Point mineur relevé en vol | Avis agent ≤2 lignes. Continue immédiatement. Pas d'action, pas de persistence. |
| 📋 | `aparté:` | Observation actionnable, orthogonale | Traiter immédiatement (fix ou backlog explicite). Réponse ≤1 section, puis reprend la tâche. |
| 🔭 | `side quest:` | Mini-projet multi-session | Crée `work/doing/<slug>.md` + avis court sur timing. Pas d'exécution immédiate. |

**Distinction `note:` vs `aparté:`** : `note:` = avis inline, pas d'action requise · `aparté:` = demande une action (fix immédiat ou backlog explicite). Critère : actionabilité, pas longueur.
**Distinction** : `note:` ≠ `note bien:` — `note:` = réagir inline maintenant · `note bien:` = persister en mémoire.
**MAJUSCULES mid-phrase** : signal impératif — le mot en MAJUSCULES est une contrainte non négociable. Traité comme un `aparté:` intégré sans préfixe explicite.

---

## Contrôle de flux — STOP / ESC

| Signal | Nature | Comportement |
|---|---|---|
| `stop` (prompt) | Breakpoint agent-géré | L'agent s'arrête proprement à la prochaine lecture du prompt. Usage : debug, pause explicite, point de contrôle. Informé à l'user via output. |
| ESC | Arret d'urgence externe | Interrompt le compute instantanément, indépendamment de l'état de l'agent. By design : la chaîne de sécurité est externe au système (logique traditionnelle). |

**Distinction** : `stop` = l'agent choisit de s'arrêter (coopératif) · ESC = l'user coupe (indépendant). Un arret d'urgence ne dépend pas de l'opérabilité du système — sinon c'est une faille de conception.

---

## Persistance / mémoire

| Mot-clé | Contexte | Comportement |
|---|---|---|
| `note bien:` | Info à conserver | Persiste dans handoff ou ACTIONS. Ne pas juste acknowledger |
| `TODO:` | Idée ou action à réflexion | Dépose dans le backlog. Pas d'exécution immédiate — c'est une idée, pas une commande |
| `TODO_now:` | Action immédiate | Traite immédiatement — la session peut se couper à tout moment |
| `backlog:` | Référence canonique | Liste de tâches : `/home/commons/backlog.md` — référence only, aucune action déclenchée |

---

## Contenu entrant / manipulation

| Mot-clé | Contexte | Comportement |
|---|---|---|
| `FYI` | Matériel entrant | Intègre/traite ce contenu. Confirmer réception en une ligne |
| `append` | Ajout ciblé | Sans référence : ajoute à la fin du fichier en cours. Avec référence (`append : FICHIER / ...`) : localise et ajoute/modifie la section concernée. Si la section n'existe pas : la créer à la fin du fichier, puis y ajouter le contenu. Reformule si nécessaire |
| `+xxx` | Ajout par catégorie | Ajoute le contenu qui suit dans la section ou le document nommé `xxx` — routing par nom de concept, pas par path. Ex : `+bonne pratique` → ajoute dans la section/doc "bonnes pratiques". Distinct de `append` (qui est path-based). |
| `inbox` | Fichier déposé par l'user | L'user a déposé un fichier dans `/home/ready-room/inbox/`. Architect fetch, traite ou dispatche selon le contexte conversationnel. Fleet consomme et vide après traitement. |
| `outbox` | Fichier déposé par la fleet | La fleet a déposé un fichier dans `/home/ready-room/outbox/`. L'agent le signale verbalement dans la session. L'user récupère et vide. Pas de suppression par la fleet après dépôt. |

---

## Notations inline — `<=` et `=>`

Annotations dans un message ou document, sans interrompre le fil principal.

| Notation | Direction | Usage |
|---|---|---|
| `<=` | Passé → présent | Contexte, nuance, correction sur ce qui précède |
| `=>` | Présent → futur | Conséquence, renommage, action résultante, implication |

**Comportement** : métadonnée enrichissante, pas d'action propre — sauf si un mot-clé actif (`TODO:`, `idée`, etc.) est encapsulé dedans.

**Composition `=>` + keyword digression** : quand `=>` pointe vers un keyword de `## Observations et digressions` (`note:`, `aparté:`, `side quest:`), le comportement complet de ce keyword s'applique. `=>` porte la causalité ("ce qui précède génère"), le keyword porte le traitement. Forme lazy : évite d'interrompre le fil pour reformuler ce qui vient d'être dit. Ex : `=> side quest:` = "la discussion précédente implique un side quest" — même comportement que `side quest:` standalone.

Dans un document traité via `up-` : les notations `<=` et `=>` sont traitées comme annotations de révision, pas comme directives de session.

## Séparateur de bloc — `===`

Contexte : terminal WSL sans support multi-ligne — impossible de faire un vrai saut de paragraphe.

`===` sépare deux blocs distincts dans un même message. L'agent traite chaque bloc comme un point indépendant, dans l'ordre.

```
premier point === deuxième point === troisième point
```

**Règle de non-collision** : si `===` apparaît dans du code ou du contenu technique cité, le contexte (backticks, indentation) prime — ce n'est pas un séparateur de bloc.

---

## Notes — companion narratif

# Notes — #4_protocole.md

**Date** : 2026-03-10
**Statut** : companion narratif du fichier canonique
**Fichier canonique** : `#4_protocole.md` (seul fichier faisant foi)

> Ce fichier est une version narrative et explicative. Il n'est pas injecté, pas dérivé, pas normatif.
> Toute règle ou contrainte doit vivre dans le fichier canonique. Ce fichier documente le *pourquoi*,
> stocke le changelog, et capture les discussions de refonte.

---

## Changelog version canonique

| Date | Nature | Détail |
|------|--------|--------|
| 2026-03-07 | Création | Grammaire triplet, keywords complets |
| 2026-03-08 | Révision | Restructuration, nuances complètes |
| 2026-03-10 | Audit v2 | 4 sections "à venir", closing-gate `explicite` absent, path backlog non vérifié |
| 2026-03-11 | Nettoyage v2 passe 1 | Retrait VALIDÉ, réfs MR obsolètes, sections "à venir", exemples → notes. Ajout `explicite` aux exclusions closing-gate |
| 2026-03-11 | Nettoyage v2 passe 2 | append-only → read-only. `avis` dédup (renvoi §Évaluation). `valide ?` canonical dans Vérification, renvoi dans Meta. Titre modif "4 préfixes". Séparateurs `---` ajoutés. Path backlog corrigé. `<=:` retiré. Section Navigation retirée (doublon #3). "agent interactif (architect)" → "architect" |

---

## Contenu retiré du canonique

### Callout VALIDÉ (l.8 original)

> [!NOTE] **VALIDÉ 07/03 — grammaire ⚡/📋/🔭 restructurée, mots-clés dev ajoutés, nuances complètes.** Document vivant par définition (append-only) — sauf ajout structurel, aucune passe globale requise.

### Chaîne de dérivation (obsolète)

Chaîne : `#5_protocole-standard.md` (template EN, onboarding) → ce fichier (source de vérité, langue user) + `#4-1_protocole-user.md` (personnalisation) → `home_claude_CLAUDE-protocol.md` (dérivé EN token-efficient, injection agent).

**Canal exclusif pour les mots-clés user** : tout mot-clé destiné à l'interaction user→agent DOIT être défini dans ce fichier (HR) ET dans `protocole-user_MR.md` (MR injecté). Définir un mot-clé ailleurs sans l'inscrire ici est une violation GO-0.

**Dérivation HR → MR** : voir `#3_system-conventions.md § dérivation HR → MR`.

**Règle MR** : voir `#3_system-conventions.md § dérivation HR → MR`.

> Modèle obsolète en v2. Les directives HR sont injectées directement, pas de MR séparé pour le protocole.

### Sections "à venir" (retirées)

- § Évaluation — `analyse` : *(Section dédiée à venir — comportement actuel défini dans le tableau du triplet.)*
- § Clarification — `explique` : *(Section dédiée à venir)*
- § Vérification — `inspecte` : *(Section dédiée à venir)*

### Section Exemples (narrative)

_Section narrative — illustrations des mots-clés._

**Évaluation** :
- `avis ?` en fin de phrase : "on pourrait passer le buffer à 512 octets, avis ?" → porte sur cette proposition uniquement
- `évalue ce spec` → assessment structuré du document fourni
- `analyse src/scheduler.c` → lit le fichier avant de produire le rapport

**Clarification** :
- `précise le scope de controle ici` → clarification directe, pas d'action
- `ces conventions sont ambiguës, explicite` → en fin de ligne, développe ce qui précède
- `explicite option 2` → en début de ligne, développe l'option 2
- `explique le mécanisme de déduplication MR` — niveau sur demande : [1] survol · [2] structuré · [3] deep dive

**Recherche** :
- `résumé` seul → condensé du contexte courant
- `tldr cmsis-dap` → recherche web, brief inline + sources

**Code** :
- `review src/parser.c` → lit le code, analyse correctness / sécurité / patterns
- `avis` sur un choix d'archi code → identique groupe Évaluation

**Vérification** :
- `valide ? "append-only sauf bug-fix documenté"` → confirmation ou correction, sans action
- `controle main.c` (avec liste de corrections en contexte) → statut ✅/❌/⚠️ par point

**Audit externe** :
- `qualifie ce rapport` → qualité formelle + verdict explicite
- `ponce https://github.com/foo/bar` → brief.md + insight.md

**Standalone** :
- `x/10 — ajouter un cache Redis devant l'API` → score + 2 lignes

L'agent résout le shorthand par `ls` si nécessaire.

### `<=:` — notation d'ajout de terme à la volée (retirée)

Le terme juste avant `<=:` est un mot-clé à documenter — le texte après `:` est l'entrée associée. Terme = mot seul ou composé atomique (ex : `update mineure`). Comportement agent : `append` immédiat dans le protocole ou le glossaire selon la nature du terme. Si la destination est ambiguë, demander avant d'écrire. Priorité : `<=:` est traité en parallèle de tout mot-clé d'action sur le même token — jamais avalé par lui. Un `controle (<=: ...)` déclenche l'append ET l'action.

> Retiré en v2 : fonctionnel mais le protocole est read-only post-refonte. Plus d'append de directives à la volée.

### Section Navigation — shorthand `#N` (retirée)

Les arborescences LCARS suivent la convention `#N_nom` (voir `system-conventions.md`). Dans la conversation, `#N` seul désigne le répertoire portant ce numéro au niveau concerné.

`commons/#1/#2/` = `commons/#1_docs/#2_directives/` — non ambigu, résolu localement.

> Retiré : doublon avec `#3_system-conventions.md § shorthand`.

---

## Personnalisation user (#4-1)

# Protocole utilisateur — personnalisation

**Date** : 2026-03-10
**Dernière révision** : 2026-03-10
**Statut** : actif — seul fichier de personnalisation du protocole
**Référencé par** : #4_protocole-FR.md

## Principe

Le protocole (`#4_protocole-FR.md`) est **figé**. Aucun mot-clé du protocole n'est modifiable, remplaçable ou substituable — même si un autre terme semble "plus naturel". Le protocole définit le contrat d'interaction ; ce fichier définit les **seules** exceptions personnalisables.

Seuls les mots-clés de contrôle de session ci-dessous sont personnalisables, une seule fois, à l'onboarding. Ils sont fonctionnellement interchangeables avec n'importe quel token arbitraire choisi par l'utilisateur.

## Mots-clés personnalisés — user

| Mot-clé | Rôle | Défaut standard |
|---|---|---|
| `yop` | Reprise de session — lire le handoff, reprendre sans recap ni questions | `resume` |
| `SeeU` | Clôture de session — exécute /handoff. Casse insensible (`seeu`, `SEEU`, etc.) | `end-session` |

Ces deux mots-clés sont les **seuls** tokens personnalisés de l'ensemble du protocole. Tout autre mot-clé est identique au protocole standard.

---

## Notes personnalisation (#4-1)

# Notes — #4-1_protocole-user.md

**Date** : 2026-03-10
**Statut** : companion narratif du fichier canonique
**Fichier canonique** : `#4-1_protocole-user.md` (seul fichier faisant foi)

> Ce fichier est une version narrative et explicative. Il n'est pas injecté, pas dérivé, pas normatif.
> Toute règle ou contrainte doit vivre dans le fichier canonique. Ce fichier documente le *pourquoi*,
> stocke le changelog, et capture les discussions de refonte.

---

## Changelog version canonique

| Date | Nature | Détail |
|------|--------|--------|
| 2026-03-10 | Création | yop / SeeU personnalisés |
| 2026-03-10 | Audit v2 | RAS — fichier propre |

---

## Notes d'analyse (session v2)

*(à compléter lors de la revue fichier par fichier)*
