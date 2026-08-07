# Provisioning — profils, déploiement, persistance

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : référence active
**Référencé par** : #00_index.md

> Cette doc décrit comment LCARS est installé, composé, déployé et restauré. Elle sert au mainteneur, pas à l'utilisateur quotidien.

Détail commandes : `<script> --help`.

---

## Profils fleet

Les profils définissent la composition de la fleet.

| Profil | Étend | Usage |
|---|---|---|
| `fleet` | — | maintenance LCARS |
| `projects` | `fleet` | développement logiciel général |
| `embedded` | `projects` | chaîne hardware / firmware |

Règles :
- le profil choisit les rôles disponibles
- le métier ne passe pas par le profil mais par le L2
- un changement de profil exige rebuild + redeploy

---

## Chaîne de provisioning

```text
bootstrap instance
→ provisioning système
→ provisioning users / homes / permissions
→ deploy runtime
→ cycle normal via fleet-update.sh
```

Lecture pratique :
- installation fraîche : provisioning complet
- vie normale : `fleet-update.sh`

---

## Modèle de déploiement

Le deploy distribue dans les homes agents :
- scripts runtime
- directives et `CLAUDE.md`
- hooks, skills, settings
- symlink `L2` si un domaine métier est assigné

Principe clé :
- la source de vérité n'est pas le runtime vivant
- le runtime est un artefact jetable
- la voie normale passe par le redeploy

---

## Authentification et remote

Chemin principal :
- auth GitHub via `gh`

Fallback :
- clé SSH dédiée

But :
- permettre push / pull / création de repo sans bricolage manuel permanent

Les secrets et tokens restent des artefacts de l'environnement, pas de la doc canonique.

---

## Persistance et survie

| Événement | Survit | Perdu |
|---|---|---|
| fermeture session | handoffs, work synchronisé, dépôts git | contexte de session |
| terminate WSL | ready-room, git distant | état volatile local |
| unregister WSL | remote + ready-room persistant | instance entière |

Lecture :
- la session ne doit pas être la vérité
- la ready-room et le repo portent la continuité utile
- la reconstruction doit rester possible

---

## fleet-system.yaml vs fleet.yaml

| Fichier | Rôle |
|---|---|
| `fleet-system.yaml` | configuration source éditable |
| `fleet/profiles/*.yaml` | composition par profil |
| `fleet/fleet.yaml` | artefact généré |

Règle :
- on n'édite pas l'artefact généré à la main

---

## Lire ensuite

- [#18_runtime-catalog.md](#18)
- [#25_release-process.md](#25)
- [#20_working-on-lcars.md](#20)
