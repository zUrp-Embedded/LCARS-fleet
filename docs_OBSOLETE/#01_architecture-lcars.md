# Architecture LCARS

**Date** : 2026-03-21
**Dernière révision** : 2026-03-30
**Statut** : référence active
**Référencé par** : #00_index.md

> LCARS est une boîte d'exécution jetable pour agents spécialisés. Le but n'est pas de rendre les agents purs, mais de rendre la machine autour d'eux plus lisible, plus bornée, et plus redéployable.

---

## Forme d'ensemble

LCARS assemble :
- un runtime déployable
- des agents à rôles distincts
- un transport IPC par spool
- un état partagé lisible par fichiers
- un cadre de release et de redeploy

Le système n'est pas une API centrale. C'est un ensemble de composants reliés par des artefacts explicites.

---

## Modèle de tiers

| Tier | Rôle |
|---|---|
| 0 | frontières : user / système |
| 1 | orchestration interne |
| 2 | workers spécialisés |

Lecture pratique :
- les frontières ne sont pas un simple confort narratif
- elles servent à éviter que tout parle à tout

La matrice exacte des rôles vit dans le runtime et les profils.

---

## Modèle d'état

L'état visible d'un agent vit surtout dans son handoff.

Le handoff sert à exposer :
- l'état courant
- ce qui est en cours
- ce qui a été fait
- ce qui bloque

LCARS préfère des fichiers lisibles à une couche opaque d'état interne.

---

## Modèle runtime

Le runtime vivant n'est pas la vérité durable.

La vérité durable vit dans :
- le repo
- les sources versionnées
- la configuration source
- les scripts de génération et de déploiement
- les artefacts explicitement persistés

Conséquence :
- on préfère le redeploy au patch artisanal sur instance vivante

---

## Pourquoi les fichiers comptent

Principes structurants :
- fichiers inspectables
- artefacts versionnables
- reprise possible après crash
- état relisible sans instrumentation complexe

LCARS choisit délibérément la lisibilité du système avant l'élégance “orchestrateur moderne”.

---

## Position de l'orchestrateur

L'orchestrateur n'est pas censé être un cerveau souverain.

Il doit :
- observer
- router
- exposer l'état
- ne pas devenir le point unique de vérité

Les workers doivent rester compréhensibles même si l'observabilité est dégradée.

---

## Exigences de design

Une évolution LCARS est saine si elle rend le système :
- plus borné
- plus explicite
- plus redéployable
- plus relisible pour un mainteneur extérieur

Elle est suspecte si elle :
- ajoute de la puissance sans clarifier la vérité
- remplace un artefact explicite par une convention implicite
- dépend davantage du contexte social que d'une contrainte mécanique

---

## Lire ensuite

- [#16_ipc-topology.md](#16)
- [#18_runtime-catalog.md](#18)
- [#23_provisioning.md](#23)
- [#20_working-on-lcars.md](#20)
