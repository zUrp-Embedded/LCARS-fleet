# Tiers, scopes et savoir — LCARS actuel

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : référence extensive
**Référencé par** : canon/README.md
**Dérivé de** : design-history/#2_roles-agents.md

> Dans LCARS, le nom d'un rôle ne suffit jamais. Ce qui compte réellement est la combinaison entre cycle de vie, périmètre autorisé et couches de savoir accessibles.

---

## 1. Tier, scope et savoir sont trois axes distincts

LCARS sépare :
- le **tier** : permanence et cycle de vie
- le **scope** : ce qui est autorisé
- le **savoir** : quelles couches peuvent être lues ou modifiées

Pourquoi :
- un même type de travail peut exister avec des cycles de vie différents
- un même agent peut connaître plus ou moins de choses sans changer de nom
- mélanger ces axes produit des rôles opaques

---

## 2. Le tier dit surtout comment l'instance vit

En pratique :
- certaines instances sont frontières
- d'autres sont permanentes
- d'autres sont jetables
- d'autres encore sont purement éphémères

Le tier ne dit pas “qui est intelligent”.
Il dit surtout :
- qui survit
- qui se reprovisionne
- qui garde de l'état
- qui peut disparaître sans casser une frontière

---

## 3. Le scope est une contrainte, pas une intention

Le scope ne décrit pas ce qu'un agent “aime faire”.
Il borne ce qu'il peut faire sans violer le contrat du système.

Exemples de familles de scope :
- code
- build
- test
- advisory
- analysis
- documentation
- physical

Pourquoi :
- un rôle lisible sans frontière réelle n'est qu'une étiquette

---

## 4. Le savoir n'a pas la même portée selon la couche

LCARS garde l'idée que tout savoir n'a pas le même statut :
- savoir de session
- savoir projet
- savoir métier
- savoir fleet
- savoir framework

La question utile n'est pas seulement “qui sait ?”.
La question est :
- qui peut écrire quoi
- à quelle portée
- avec quelle persistance

---

## 5. Les workers ne devraient pas voir toute la topologie

Un worker utile n'a pas besoin d'avoir une vue totale sur la fleet.

Pourquoi :
- moins de visibilité interne réduit les couplages inutiles
- moins de visibilité réduit aussi la surface de dérive
- la topologie détaillée appartient surtout aux couches de coordination et de frontière

---

## 6. L2 et L1 ne servent pas au même travail

Le savoir métier et le savoir projet sont distincts :
- le premier sert à réutiliser
- le second sert à produire dans un contexte particulier

Pourquoi :
- si tout finit dans le projet, rien ne se capitalise
- si tout remonte trop tôt dans le métier, on pollue la couche réutilisable avec du local

---

## 7. La combinaison compte plus que le nom

Deux agents nommés différemment mais ayant :
- le même tier
- le même scope
- le même accès au savoir

ne sont souvent que deux presets, pas deux natures distinctes.

Pourquoi :
- LCARS préfère des rôles structurels réels à un zoo de noms flatteurs

---

## 8. Pourquoi cette couche existe encore

LCARS garde cette modélisation parce que :
- elle permet de raisonner sur la boîte sans se raconter des histoires sur les personnalités d'agents
- elle rend les forks plus propres
- elle aide à voir ce qui est configuration, ce qui est structure, et ce qui est simple alias

---

## Lire ensuite

- [README.md](README.md)
- [#1_roles-et-frontieres.md](#1_roles-et-frontieres.md)
- [#6_glossaire-structurel.md](#6_glossaire-structurel.md)
- [../#02_knowledge-hierarchy.md](../#02_knowledge-hierarchy.md)
- [../design-history/#2_roles-agents.md](../design-history/#2_roles-agents.md)
