# Principes structurants — LCARS actuel

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : référence extensive
**Référencé par** : canon/README.md
**Dérivé de** : design-history/#0_principes-fondateurs.md

> Ce document ne raconte pas comment les principes sont apparus. Il expose les principes qui structurent LCARS aujourd'hui, et pourquoi ils existent encore dans sa forme actuelle.

---

## 1. Rien d'implicite

Une règle qui n'est pas écrite n'existe pas.

Conséquences :
- pas de comportement supposé “évident”
- pas de convention vivante uniquement dans la tête de l'opérateur
- pas de confiance dans l'inférence spontanée d'un agent quand une règle manque

Pourquoi :
- LCARS travaille avec des composants probabilistes
- l'implicite y devient rapidement une source de dérive

---

## 2. La vérité durable est versionnée

Le repo distant est la seule vérité canonique durable.

Conséquences :
- ce qui n'est pas commité est réputé volatil
- le runtime vivant n'est pas la vérité
- un hotfix non versionné est une dette, pas une solution

Pourquoi :
- LCARS préfère la reconstruction propre à la réparation sentimentale

---

## 3. Le runtime est jetable

Le runtime LCARS est un artefact de déploiement, pas un objet précieux.

Conséquences :
- on redéploie plus volontiers qu'on ne répare à la main
- on protège ce qui doit survivre hors de l'instance
- l'instance entière est pensée comme reconstructible

Pourquoi :
- les agents internes peuvent être puissants, libres, voire destructeurs
- le confinement utile consiste à choisir où la casse est acceptable

---

## 4. La sûreté doit tendre vers la mécanique

Une règle qui dépend seulement de la discipline humaine reste incomplète.

Conséquences :
- les frontières utiles doivent devenir mécaniques quand c'est possible
- une convention sociale ne suffit pas pour un invariant important
- une erreur silencieuse vaut souvent plus cher qu'un échec explicite

Pourquoi :
- LCARS vise un système qui reste utilisable quand plus personne n'a envie de le réparer

---

## 5. Les agents ne sont pas la vérité

Les agents sont des moteurs utiles, pas des autorités de confiance.

Conséquences :
- leur liberté utile est conservée
- leur zone d'impact doit rester bornée
- leur output doit vivre dans un cadre plus déterministe qu'eux

Pourquoi :
- LCARS ne cherche pas à rendre un LLM déterministe
- il cherche à construire un système plus borné autour de composants non déterministes

---

## 6. L'auditabilité n'est pas un supplément

Une règle ou un comportement important doit pouvoir être relu, tracé et vérifié.

Conséquences :
- la doc canonique compte
- les artefacts lisibles comptent
- les chaînes de dérivation entre source, runtime et comportement doivent rester compréhensibles

Pourquoi :
- sans auditabilité, la gouvernance des agents redevient du récit

---

## 7. Pas de directives masquées

Ce qui gouverne en continu un agent doit vivre dans :
- les directives actives
- ou un mécanisme runtime

Pas dans :
- une doc oubliée
- un guide lu par hasard
- une coutume implicite

Pourquoi :
- sinon la doc devient une seconde couche normative non déclarée
- et la séparation entre vérité active et commentaire disparaît

---

## 8. La récursivité est un fait à borner

LCARS sert aussi à travailler sur LCARS.

Conséquences :
- il faut séparer clairement runtime actif et source en cours de modification
- il faut fermer les dérogations explicitement
- il faut garder la frontière entre usage de la boîte et modification de la boîte

Pourquoi :
- la récursivité est une force seulement si elle garde ses points fixes

---

## Lire ensuite

- [README.md](README.md)
- [#01_architecture-lcars.md](../#01_architecture-lcars.md)
- [#20_working-on-lcars.md](../#20_working-on-lcars.md)
- [../design-history/#0_principes-fondateurs.md](../design-history/#0_principes-fondateurs.md)
