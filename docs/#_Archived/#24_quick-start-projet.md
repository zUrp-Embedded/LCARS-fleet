# Quick Start — Premier projet avec LCARS

**Date** : 2026-03-23
**Dernière révision** : 2026-03-30
**Statut** : v6.0-RC
**Référencé par** : #00_index.md, README.md
**Dérivé de** : —

> Tu as une fleet qui tourne. Ce guide t'amène du zéro au premier livrable.

Version interactive : `/onboarding` dans une session architect.

---

## Le modèle en 30 secondes

Tu parles à **architect**.

Architect :
- clarifie la demande
- propose un plan
- orchestre les agents internes
- te rend le résultat

Tu pilotes le projet. Tu ne pilotes pas chaque agent à la main.

```text
toi ←→ architect ←→ engineer / dev / qualifier / reviewer / builder...
```

---

## Cinq mots-clés de survie

| Mot-clé | Effet |
|---|---|
| `go` | exécute le plan discuté, avec arrêt si un point reste flou |
| `ok` | valide la proposition |
| `ok pour X` | valide seulement X |
| `nope` | rejette |
| `stop` | pause propre au prochain point d'arrêt |

`ESC` coupe le compute immédiatement. Réserver à l'urgence.

---

## Démarrer un projet

### Projet neuf

```text
nouveau projet : <description en 1-2 phrases>
```

Architect collecte le minimum utile, puis lance le workflow projet.

Résultat attendu :
- repo initialisé
- README
- `work/` prêt
- structure LCARS cohérente

### Projet existant

```text
adopte ce projet : https://github.com/user/repo
```

ou dépôt local dans `/home/projects/`.

Architect prépare l'adoption sans te demander de connaître la plomberie.

---

## Cycle de travail standard

### 1. Décrire le besoin

```text
ajoute un endpoint REST /api/status qui retourne version et uptime
```

Pas besoin de dicter l'implémentation si tu n'as pas une contrainte précise.

### 2. Valider le plan

Architect propose. Tu ajustes ou tu valides.

### 3. Laisser la fleet travailler

Les agents internes bossent. Tu peux :
- attendre le retour
- observer via `ready-room/fleet-live/`
- ouvrir les fenêtres tmux si tu veux voir le runtime

### 4. Relire le résultat

Architect te rend :
- état du chantier
- fichiers / commits / livrables
- tests ou qualification si pertinents

---

## Patterns utiles

| Ce que tu veux | Ce que tu dis |
|---|---|
| demander un avis | `avis` / `évalue` / `analyse` |
| déclencher maintenant | `now` ou `go` |
| remettre plus tard | `backlog` |
| rejeter | `nope` |
| noter un point | `note bien:` |
| idée plus tard | `TODO:` |
| mini-chantier à part | `side quest:` |

Le pilotage quotidien est dans [#26_user-guide.md](#26). Le résumé user des mots-clés actifs est dans [#09_protocole-cheatsheet.md](#09).

---

## Ready Room

`/home/ready-room/` sert d'interface fichier côté user.

| Dossier | Usage |
|---|---|
| `inbox/` | tu déposes quelque chose pour la fleet |
| `outbox/` | la fleet te laisse un livrable |
| `fleet-live/` | vue lecture seule du runtime et des projets |

---

## Quand ça bloque

Premier réflexe :

```bash
fleet-doctor.sh
```

Ensuite :
- guide court : [ONBOARDING.md](ONBOARDING.md)
- guide de reprise : [#19_troubleshooting.md](#19)

---

## Lire ensuite

- [#26_user-guide.md](#26) : usage quotidien
- [#21_new-project.md](#21) : création / adoption projet
- [ONBOARDING.md](ONBOARDING.md) : opérations runtime
