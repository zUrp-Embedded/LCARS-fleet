# Protocole — Cheatsheet

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : référence rapide — dérivé, ne pas éditer directement
**Référencé par** : #00_index.md
**Dérivé de** : `fleet/system-prompt/sources/user/protocole.md` (source active runtime)

---

En cas d'écart, la source active runtime fait foi. Ce cheatsheet n'est pas une seconde autorité.

## Session

| Mot-clé | Effet | Note |
|---|---|---|
| `yop` | Reprise — lit handoff, pas de recap ni questions | Personnalisable (protocole-user.md) |
| `SeeU` | Fermeture propre via /handoff (casse libre) | Personnalisable (protocole-user.md) |
| `quiet` | Une ligne par action pour la session | Reset fin de session |
| `verbose` | Raisonnement intermédiaire affiché | Reset fin de session |

Seuls `yop` et `SeeU` sont personnalisables. Tous les autres mots-clés sont figés.

---

## Modificateurs — s'appliquent à tout mot-clé

| Préfixe | Effet |
|---|---|
| `re-` | Rejoue l'action — output = **diff** vs précédent uniquement |
| `up-` | Doc modifié par l'user — nouvelle passe complète, pas un diff |
| `dry-` | Simule sans effet de bord (actions, rapport fichier) |
| `cross-` | Compare deux cibles : `cross-analyse A B` |

Tiret obligatoire. Le modificateur s'applique au mot-clé composé entier : `dry-update mineure` = simulation de `update mineure`.

---

## Analyse — lecture seule

### Évaluation
| Niv. | Mot-clé | Usage |
|---|---|---|
| ⚡ | `avis` | Opinion courte. `avis ?` fin de phrase = dernière phrase uniquement |
| 📋 | `évalue` | Assessment structuré d'un artefact (contenu/sémantique) |
| 🔭 | `analyse` | Exploration profonde — lit les sources par défaut |

### Clarification
| Niv. | Mot-clé | Usage |
|---|---|---|
| ⚡ | `précise` | Clarification directe d'un point |
| 📋 | `explicite` | Développe l'objet ciblé (position libre en phrase) |
| 🔭 | `explique [1/2/3]` | Pédagogique — 1=survol · 2=structuré · 3=deep dive |

### Recherche
| Niv. | Mot-clé | Usage |
|---|---|---|
| ⚡ | `résumé` | Condensé du contexte courant — pas de web |
| 📋 | `tldr` | Recherche web + brief condensé |
| 🔭 | `deepsearch` | Researcher headless → rapport `docs/research/<sujet-slug>.md` |

### Code
| Niv. | Mot-clé | Usage |
|---|---|---|
| ⚡ | `affiche` | Contenu brut sur terminal — zéro reformulation. >100 lignes → brut + résumé 2 lignes |
| 📋 | `review` | Analyse code : correctness · sécurité · performance · patterns · dette |

### Vérification
| Niv. | Mot-clé | Usage |
|---|---|---|
| ⚡ | `valide ?` | Confirme ou corrige une formulation — jamais d'action |
| 📋 | `controle` | Compare état actuel vs liste de corrections — ✅/❌/⚠️ par point |
| 🔭 | `inspecte` | Vérification exhaustive sans liste préétablie — conformité, cohérence |

### Audit externe
| Niv. | Mot-clé | Usage |
|---|---|---|
| 📋 | `qualifie` | Qualité formelle d'un document + verdict |

### Score seul
| Mot-clé | Usage |
|---|---|
| `x/10` | Score 0→10 + 2 lignes. 0=trivial · 10=critique |

### Clôture de routage (règle transversale)

Tout output d'analyse décisionnelle (`avis`, `évalue`, `qualifie`, `analyse`, `review`, `controle`, `inspecte`) se termine par : **score x/10 + une question de routing** parmi `backlog ?`, `now ?`, `nope ?`. Trois options exhaustives — l'agent propose, l'user route en un mot.

Exclusions : `résumé`, `précise`, `explicite`, `explique`, `tldr`, `x/10`, `ponce`, `reverse`, `audit`.

---

## Rapport fichier — effet de bord .md

Les **3 seuls mots-clés** qui produisent des fichiers persistants :

| Niv. | Mot-clé | Cible | Outputs |
|---|---|---|---|
| ⚡ | `ponce` | Repo externe (URL) | `<repo>-brief.md` + `<repo>-insight.md` + brief inline |
| 📋 | `reverse` | Repo/dossier local | `<repo>-specs.md` + `<repo>-architecture.md` + résumé ~10 lignes |
| 🔭 | `audit` | Dossier code | `audit-report/*.md` (détaillé + dérives + bilan) + bilan inline |

Propriétés : progress tracker (`_progress.md`), batch ≤3 fichiers/cycle, sub-agents au-delà. `dry-` applicable.

---

## Validation / exécution

| Mot-clé | Effet |
|---|---|
| `ok` | Valide l'ensemble de la proposal |
| `ok pour X` | Valide X uniquement — reste ouvert |
| `go` | Exécute — peut s'interrompre si point non couvert par une règle (GO-0) |
| `GO` | Exécution immédiate, zéro interruption |
| `fais X` | Exécute X explicitement, scope strict |
| `scope?` | Liste fichiers/fonctions touchés sans agir |

---

## Modification

| Mot-clé | Effet |
|---|---|
| `update` | Applique tout ce qui a été discuté |
| `update mineure` | Une correction ciblée uniquement — pas d'extension |
| `applique` | Applique les instructions du doc cible. Requiert une référence (`applique fichier.md`) ou le modifier `up-`. |
| `corrige` | Agent applique ses propres corrections (depuis `qualifie`/`évalue`) |
| `fix` / `fix 1, 3` | Correction immédiate, scope strict aux points cités |
| `draft` | Brouillon sans écriture fichier — cycle : draft → review → `go` |
| `diff` | Affiche ce qui a changé depuis le dernier état stable |

Fallback : mot-clé d'action sans contexte préalable → agent signale + demande confirmation.

---

## Méta-conversation

| Mot-clé | Effet |
|---|---|
| `idée` | Évalue l'idée dans le contexte — pas d'action |
| `question` | Répond — pas d'action sauf `go`/`ok` explicite après |
| `raccord` / `raccord ?` | Valide ta compréhension → déclenche l'exécution si correct. **Exception** : seul mot-clé qui déclenche une exécution sans `go`/`ok` explicite. Si incorrect : l'agent corrige, ne plie pas. |
| `correct ?` | Vérifie ta compréhension — pas d'action |
| `valide ?` | Confirme une formulation — jamais d'action |
| `nope` | Rejette — agent propose alternative |
| `reroll` | Rejoue pour output statistiquement différent |

---

## Observations et digressions

| Niv. | Préfixe | Effet |
|---|---|---|
| ⚡ | `note:` | Avis agent ≤2 lignes, continue immédiatement. Pas de persistence. |
| 📋 | `aparté:` | Observation actionnable — fix immédiat ou backlog explicite |
| 🔭 | `side quest:` | Crée `work/doing/<slug>.md` + avis — pas d'exécution immédiate |

`note:` ≠ `note bien:` — `note:` = réagir inline · `note bien:` = persister en mémoire.

MAJUSCULES mid-phrase = contrainte non négociable, traité comme `aparté:` intégré.

---

## Mémoire / persistance

| Mot-clé | Effet |
|---|---|
| `note bien:` | Append dans `work/scratchpad.md` (date + heure) |
| `TODO:` | Dépose dans le backlog — pas d'exécution |
| `TODO_now:` | Traite immédiatement |
| `backlog:` | Référence `work/backlog.md` — aucune action déclenchée |

---

## Contenu entrant

| Mot-clé | Effet |
|---|---|
| `FYI` | Intègre/traite le contenu — confirmation en une ligne |
| `append` | Ajoute en fin de fichier. `append : FICHIER / ...` = section ciblée |
| `+xxx` | Ajoute dans la section/doc nommé `xxx` (routing par concept) |
| `inbox` | User a déposé dans `/home/ready-room/inbox/` — fetch + traite |
| `outbox` | Fleet a déposé dans `/home/ready-room/outbox/` — signale verbalement |

---

## Contrôle de flux

| Signal | Nature | Effet |
|---|---|---|
| `stop` | Breakpoint coopératif | Agent s'arrête proprement au prochain prompt |
| ESC | Arrêt d'urgence externe | Interrompt le compute instantanément |

`stop` = l'agent choisit de s'arrêter. ESC = l'user coupe. Indépendants.

---

## Notations inline

| Notation | Usage |
|---|---|
| `<=` | Contexte / nuance / correction sur ce qui précède |
| `=>` | Conséquence / implication / action résultante |
| `===` | Séparateur de blocs indépendants dans un message |

`=>` + keyword digression = le comportement complet du keyword s'applique (ex: `=> side quest:` = même effet que `side quest:` standalone).

---

## Règles de résolution

1. **Plusieurs mots-clés** : séquentiels dans l'ordre d'apparition. Conflit sur même cible → le dernier l'emporte.
2. **`===`** : blocs indépendants, aucun effet de bord croisé.
3. **Modificateur sur composé** : `dry-update mineure` = simule `update mineure` entier.
4. **Backticks** : `` `go` `` = référence au mot-clé, pas une commande active.
5. **Guillemets** `"..."` : parsing ambigu → agent signale + demande confirmation.
6. **`:` terminal** : préfixe (`TODO: texte`). Sans `:` = s'applique au contexte courant.
7. **Fallback hors-contexte** : mot-clé d'action sans contexte requis → agent signale + demande confirmation.
