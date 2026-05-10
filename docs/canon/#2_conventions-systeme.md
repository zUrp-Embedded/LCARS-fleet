# Conventions système — LCARS actuel

**Date** : 2026-03-30
**Dernière révision** : 2026-03-30
**Statut** : référence extensive
**Référencé par** : canon/README.md
**Dérivé de** : design-history/#3_system-conventions.md

> Les conventions système ne sont pas du folklore de repo. Elles existent pour garder la vérité durable distincte du runtime vivant, et pour rendre la flotte reconstruisible sans dépendre d'une mémoire tribale.

---

## 1. Une place par fonction

Dans LCARS, un chemin n'est pas neutre.

Chaque zone de travail a une fonction claire :
- repo source partagé
- runtime déployé
- IPC
- échange user↔fleet
- secrets
- espaces temporaires

Pourquoi :
- si tout se mélange, plus personne ne sait ce qui est durable, jetable, ou sensible

---

## 2. Source et runtime ne doivent pas se confondre

La working copy et le runtime n'ont pas le même rôle.

La source :
- est versionnée
- est modifiable
- porte la vérité durable

Le runtime :
- est déployé
- est consommé par les agents
- doit rester remplaçable

Pourquoi :
- développer dans la copie vivante du runtime détruit la frontière la plus utile du système

---

## 3. L'arborescence est un mécanisme de lisibilité

LCARS garde une structure de répertoires explicite non pour faire joli, mais pour réduire le coût de lecture :
- où vit l'IPC
- où vivent les projets
- où vivent les secrets
- où vit l'éphémère

Pourquoi :
- un mainteneur extérieur doit pouvoir reconstruire le modèle du système sans deviner les usages locaux

---

## 4. Les homes agents sont des enveloppes standardisées

Un home agent n'est pas un bureau personnel.

Il sert à porter :
- les directives déployées
- les hooks et skills
- les outils fleet
- les worktrees
- les liens vers le savoir utile

Pourquoi :
- l'instance doit rester identifiable et remplaçable
- tout ce qui devient irremplaçable dans un home agent est une fuite de design

---

## 5. Le Ready Room est une frontière, pas un dossier pratique

Le Ready Room matérialise l'interface fichiers entre user et fleet.

Il existe pour :
- rendre les échanges visibles
- séparer dépôt user et production fleet
- garder un point de persistance hors du runtime jetable

Pourquoi :
- un fichier déposé “directement au bon endroit” court-circuite la gouvernance du système

---

## 6. Les headers documentaires servent à l'audit

Les headers Markdown standardisés ne sont pas un tic éditorial.

Ils servent à :
- dater
- qualifier le statut
- rendre les dépendances entrantes visibles
- faciliter la lecture humaine et le grep mécanique

Pourquoi :
- une doc sans statut ni filiation devient vite un texte plausible mais non situable

---

## 7. Les conventions utiles doivent survivre au fork

Une convention LCARS n'est saine que si :
- elle reste compréhensible par un autre humain
- elle supporte un fork
- elle ne dépend pas d'un nom propre ou d'une machine unique

Pourquoi :
- LCARS vise un système transférable, pas une extension d'atelier personnelle impossible à reprendre

---

## 8. Le détail exact vit ailleurs

Cette doc ne remplace pas :
- [#01_architecture-lcars.md](../#01_architecture-lcars.md)
- [#18_runtime-catalog.md](../#18_runtime-catalog.md)
- [#23_provisioning.md](../#23_provisioning.md)
- les man-pages des scripts

Elle sert à garder le sens structurel des conventions, pas leur inventaire exhaustif.

---

## Lire ensuite

- [README.md](README.md)
- [#1_roles-et-frontieres.md](#1_roles-et-frontieres.md)
- [../#01_architecture-lcars.md](../#01_architecture-lcars.md)
- [../#23_provisioning.md](../#23_provisioning.md)
- [../design-history/#3_system-conventions.md](../design-history/#3_system-conventions.md)
