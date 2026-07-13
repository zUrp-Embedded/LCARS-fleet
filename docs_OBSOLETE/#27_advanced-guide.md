# Guide avancé — LCARS Fleet

**Date** : 2026-03-23
**Dernière révision** : 2026-03-30
**Statut** : v6.0-RC
**Référencé par** : #00_index.md
**Dérivé de** : —

> Ce guide couvre ce qui dépasse l'usage quotidien : rapports lourds, extension du système, profils, knowledge et hooks.

---

## Workflows de rapports lourds

Ces opérations produisent des rapports persistants. Elles sont plus coûteuses qu'une simple analyse inline.

| Mot-clé | Cible | Produit |
|---|---|---|
| `ponce` | repo externe | brief + insight |
| `reverse` | repo ou dossier local | specs + architecture |
| `audit` | codebase locale | rapports détaillés + bilan |

Propriétés communes :
- incrémental
- reprise possible sur rapport partiel
- `dry-...` disponible

À utiliser quand tu veux un artefact exploitable, pas juste une réponse de session.

---

## Couches de savoir

LCARS hiérarchise le savoir.

```text
L4 directives
L3 fleet
L2 métier
L1 projet
L0 session
```

Règles pratiques :
- L4 écrase L1 en cas de conflit
- L2 spécialise un agent sans changer son rôle
- L0 est éphémère : ce qui n'est pas écrit se perd

Pour le détail, voir [#02_knowledge-hierarchy.md](#02).

---

## Profils

Les profils changent la composition de la fleet. Ils ne définissent pas le métier.

| Profil | Usage |
|---|---|
| `fleet` | maintenance LCARS |
| `projects` | développement logiciel général |
| `embedded` | ajoute la chaîne hardware / firmware |

Le métier, lui, vit dans le L2.

Workflow :

```bash
fleet-build-yaml.sh <profile>
fleet-update.sh
```

---

## Skills

Un skill formalise un workflow réutilisable.

| Scope | Chemin |
|---|---|
| projet | `.claude/skills/<name>/SKILL.md` |
| personnel | `~/.claude/skills/<name>/SKILL.md` |

Usage :
- créer un workflow répétable
- éviter de re-raconter la même procédure
- encapsuler une opération non triviale

Pour dériver un skill depuis une session :

```text
/skill-from-session
```

---

## Hooks

Les hooks servent à automatiser des vérifications ou des routines autour des outils Claude Code.

Exemples :
- formatage après écriture
- détection de secrets
- tests automatiques
- harvest avant compact

LCARS déploie déjà des hooks runtime. Pour la cartographie réelle, voir [#18_runtime-catalog.md](#18).

---

## Multi-projet

La fleet est partagée. Les projets restent séparés.

Règles utiles :
- un projet a son propre `work/`
- l'ingénierie sérialise les écritures concurrentes
- LCARS lui-même est un projet spécial, pas un cas magique hors système

Pour changer de projet, le plus propre reste de l'annoncer explicitement à architect.

---

## Ce que ce guide n'est pas

Ce guide n'est pas :
- un manuel d'exploitation runtime
- un guide de dépannage
- une doc mainteneur complète de la boîte

Pour ça :
- exploitation : [ONBOARDING.md](ONBOARDING.md)
- reprise incident : [#19_troubleshooting.md](#19)
- maintenance de LCARS : [#20_working-on-lcars.md](#20), [#25_release-process.md](#25)

---

## Lire ensuite

- [#18_runtime-catalog.md](#18)
- [#20_working-on-lcars.md](#20)
- [#23_provisioning.md](#23)
