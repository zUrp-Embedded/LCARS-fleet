# Hiérarchie des savoirs — fleet, métier, projet

**Date** : 2026-03-05
**Dernière révision** : 2026-03-30
**Statut** : référence active
**Référencé par** : #00_index.md, #27_advanced-guide.md

> LCARS sépare ce qui appartient au système, au domaine métier, et au projet courant. Cette séparation sert à éviter les mélanges sales et les promotions prématurées.

---

## Trois niveaux

| Niveau | Portée | Fonction |
|---|---|---|
| Fleet | système entier | règles, topologie, runtime, conventions |
| Métier | domaine | savoir réutilisable par domaine |
| Projet | projet courant | décisions locales, travail, contexte spécifique |

---

## Ce qui va où

Questions simples :
- vrai pour tout LCARS ? → Fleet
- vrai pour une famille de projets ? → Métier
- vrai seulement ici ? → Projet

En cas de doute :
- commencer au niveau Projet
- promouvoir plus tard si le pattern se répète vraiment

---

## Le L2 spécialise, il ne redéfinit pas le rôle

Le L2 ne change pas le rôle d'un agent.

Il change :
- son bagage métier
- ses patterns connus
- son outillage de domaine

Donc :
- rôle = comportement attendu dans la fleet
- L2 = spécialisation technique du travail

---

## Promotion ascendante

La promotion ascendante doit rester rare.

Conditions :
- le pattern est reproductible
- il dépasse un projet unique
- il mérite d'être conservé à un niveau plus haut

Le danger à éviter :
- transformer trop vite un accident local en règle générale

---

## Pourquoi c'est utile

Cette hiérarchie sert à :
- éviter le bruit dans le cœur du système
- rendre le L2 réutilisable d'un projet à l'autre
- empêcher qu'un projet pollue la fleet entière

---

## Lire ensuite

- [#01_architecture-lcars.md](#01)
- [#23_provisioning.md](#23)
