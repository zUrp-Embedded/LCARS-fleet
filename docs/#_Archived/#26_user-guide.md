# Guide utilisateur — LCARS Fleet

**Date** : 2026-03-23
**Dernière révision** : 2026-03-30
**Statut** : v6.0-RC
**Référencé par** : #00_index.md
**Dérivé de** : —

> Guide de pilotage quotidien. Tu l'utilises pour parler à architect, lancer du travail, trier les résultats, et garder le flux propre.

---

## Modèle d'interaction

Cycle normal :

```text
discussion → proposition → validation → exécution → retour
```

Architect propose. Tu décides.

---

## Demander la bonne profondeur

| Besoin | Mot-clé | Résultat attendu |
|---|---|---|
| avis court | `avis` | opinion courte et argumentée |
| évaluation structurée | `évalue` | points forts, manques, corrections |
| exploration profonde | `analyse` | rapport détaillé |
| revue de code | `review` | bugs, risques, dette, tests |
| vérification simple | `valide ?` | confirme ou corrige |

Pour afficher sans commenter :
- `affiche`

Pour deux cibles :
- `cross-analyse`

---

## Fermer les décisions proprement

Les analyses décisionnelles se ferment avec :

```text
score/10 — [résumé bref]. backlog ? / now ? / nope ?
```

Réponses :
- `now` : on traite tout de suite
- `backlog` : on garde pour plus tard
- `nope` : on laisse tomber

Ce mécanisme évite les fins de conversation molles.

---

## Déclencher les changements

| Mot-clé | Effet |
|---|---|
| `go` | exécute le plan validé, avec arrêt si ambiguïté restante |
| `GO` | exécution d'une traite, sans checkpoint intermédiaire |
| `ok` | valide l'ensemble |
| `ok pour X` | valide X seulement |
| `fais X` | limite l'action à X |
| `scope?` | liste ce qui sera touché avant action |
| `update` | applique ce qui a été discuté |
| `update mineure` | correction ciblée seulement |
| `diff` | montre ce qui a changé |

Règle :
- `go` par défaut
- `GO` seulement quand le plan est complètement borné

---

## Capturer le travail sans le perdre

| Ce que tu veux | Mot-clé | Destination |
|---|---|---|
| noter un point important | `note bien:` | `work/scratchpad.md` |
| idée pour plus tard | `TODO:` | `work/backlog.md` |
| action immédiate | `TODO_now:` | exécution immédiate |
| chantier parallèle | `side quest:` | plan dédié |

Pour les plans :

```bash
/plan new <slug>
/plan list
/plan check <slug>
```

Le détail du cycle `scratchpad / backlog / plans` est dans [#17_work-lifecycle.md](#17).

---

## Utiliser les interruptions délibérément

| Préfixe | Usage |
|---|---|
| `note:` | observation mineure |
| `aparté:` | point actionnable sans changer de sujet principal |
| `side quest:` | vrai chantier séparé |

Un mot en majuscules au milieu d'une phrase agit comme contrainte forte.

---

## Régler le mode

| Mot-clé | Effet |
|---|---|
| `quiet` | retour minimal |
| `verbose` | plus de détail intermédiaire |
| `dry-...` | simule sans écrire |
| `re-...` | rejoue l'action |
| `up-...` | re-traite un document modifié |

---

## Anti-patterns

| Mauvaise habitude | Pourquoi | Fais plutôt |
|---|---|---|
| détailler toi-même toute la solution | tu remplaces architect | décris le besoin et les contraintes |
| valider sans lire | les erreurs passent | lis la clôture et le scope |
| mettre `GO` partout | tu supprimes les garde-fous | utilise `go` |
| oublier de capturer les idées | elles se perdent | `TODO:` immédiatement |
| micro-manager les agents | tu ralentis la fleet | fixe l'objectif, pas chaque geste |

---

## Lire ensuite

- [#09_protocole-cheatsheet.md](#09) : résumé user du protocole actif
- [#17_work-lifecycle.md](#17) : backlog, scratchpad, plans
- [#27_advanced-guide.md](#27) : opérations avancées et extension
