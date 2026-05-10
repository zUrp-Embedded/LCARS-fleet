# Topologie IPC — spool, dispatch, circulation

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : référence active
**Référencé par** : #00_index.md

Détail commandes : `fleet-send.sh --help`, `fleet-dispatch.sh --help`, `fleet-fetch.sh --help`.

---

## Modèle de transport

LCARS transporte ses messages via spool :

```text
/var/spool/fleet/inbox/<role>/
```

Le transport sert à :
- rendre les échanges inspectables
- survivre aux coupures courtes
- éviter de dépendre d'une conversation unique ou d'un bus opaque

---

## Principe de routage

Tout ne parle pas à tout.

Lecture pratique :
- les workers ne remontent pas directement au user
- le routage passe par les frontières prévues
- la topologie impose une discipline de circulation

Le document décrit le **transport** et la **circulation**, pas les responsabilités métier fines.

---

## Cycle de vie du message

```text
inbox/<role>/             en attente
inbox/<role>/.processing/ en cours
inbox/<role>/.consumed/   traité
```

Le cycle doit rester lisible à l'œil nu.

---

## Modes de dispatch

Le dispatch peut passer par :
- pane active, donc routage asynchrone vers un agent vivant
- mode headless si l'agent n'a pas de pane active

La mécanique de dispatch doit rester compatible avec :
- la topologie
- les permissions
- la séparation des rôles

---

## Canaux hors transport

Deux canaux importants ne sont pas du transport IPC pur :
- les handoffs
- la ready-room

Ils servent à :
- exposer l'état
- échanger avec l'humain
- garder des artefacts utiles hors de la session immédiate

Ils ne doivent pas être confondus avec le transport métier normal entre rôles.

---

## Critères de qualité

La topologie IPC est saine si :
- le chemin d'un message reste explicable
- l'état du message reste visible
- les raccourcis ne détruisent pas les frontières de rôle
- l'échec de routage reste détectable

---

## Lire ensuite

- [#01_architecture-lcars.md](#01)
- [#18_runtime-catalog.md](#18)
- [#19_troubleshooting.md](#19)
