# LCARS-on-LCARS — la boîte comme premier projet

**Date** : 2026-03-05
**Dernière révision** : 2026-03-30
**Statut** : référence active
**Référencé par** : #00_index.md, #20_working-on-lcars.md

> LCARS n'est pas seulement un runtime pour projets externes. Le framework est aussi le premier projet développé à l'intérieur de sa propre boîte. Cette récursivité n'est pas un gimmick ; c'est une preuve d'usage réel, avec des frontières à tenir.

---

## Ce que cela implique

LCARS travaille sur LCARS dans le même cadre général que pour un projet normal :
- discussion
- plan
- exécution
- review
- redeploy

La différence est que, cette fois, la cible du travail est la boîte elle-même.

---

## Pourquoi cela ne s'effondre pas

La séparation clé est celle-ci :
- le runtime actif gouverne la session en cours
- le dépôt en cours de modification est un projet de niveau inférieur

Donc :
- modifier la source n'équivaut pas à modifier immédiatement la règle active
- le changement ne devient réel qu'après validation et redeploy

Cette distance est exactement ce qui rend la récursivité viable.

---

## Risque principal

Le risque majeur n'est pas “la récursivité” en soi.

Le vrai risque est :
- confusion entre source et runtime actif
- collision entre directives actives et modifications en cours
- perte de frontière entre usage du système et modification du système

Autrement dit :
- si la boîte oublie qu'elle travaille sur elle-même, elle se ment

---

## Discipline requise

Pour que LCARS-on-LCARS reste sain, il faut au minimum :
- garder la source de vérité claire
- ne pas confondre repo et runtime déployé
- faire passer les changements par review puis redeploy
- éviter le bruteforce de rôle
- fermer toute dérogation une fois le chantier terminé

Le cadre pratique de cette discipline est dans [#20_working-on-lcars.md](#20).

---

## Pourquoi c'est important

Cette propriété montre deux choses :
- LCARS est capable de produire et maintenir un vrai projet dans son propre cadre
- l'historique du repo est lui-même une preuve partielle des capacités de la boîte

Cela ne prouve ni perfection, ni sûreté absolue.
Cela prouve que le système a déjà servi à fabriquer un système réel : lui-même.

---

## Lire ensuite

- [#20_working-on-lcars.md](#20)
- [#25_release-process.md](#25)
- [#01_architecture-lcars.md](#01)
