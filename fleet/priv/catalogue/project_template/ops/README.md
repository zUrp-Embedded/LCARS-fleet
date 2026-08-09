# ${REPO_NAME} — face `ops` : le registre de la fleet

**Date** : ${YEAR}-${MONTH}-${DAY}
**Dernière révision** : ${YEAR}-${MONTH}-${DAY}
**Statut** : actif — arbre écrit par le RUNTIME uniquement
**Référencé par** : `Fleet.Layout` (racine et branche de la face)

## Ce que cet arbre contient

Ce que le **système** manipule : ce qui a été demandé, ce qui a été jugé, ce qui a été prouvé.

| sous-arbre | écrit par | quand |
|---|---|---|
| `briefs/` | le runtime | au dispatch d'un producteur — l'ordre de mission figé |
| `gate-briefs/` | le runtime | au dispatch d'un juge |
| `verdicts/` | le runtime | quand un verdict dépasse le seuil d'inlining |
| `gate-verdicts/` | le runtime | à chaque décision de porte |
| `provenance/` | le runtime | à la complétion — le triplet vérifié au sceau |
| `conflicts/` | le runtime | quand le moteur de conflit explique ce qu'il a fait |

Les répertoires apparaissent au premier objet écrit. Un arbre vide est l'état normal d'un projet
neuf, pas un défaut.

## Ce qu'aucun agent n'y écrit — et pourquoi ce n'est pas une règle mais une impossibilité

Aucune carte de workflow ne peut déclarer `face: ops` : l'enum du schéma v2.5 n'accepte que `code`
et `doc`. Donc aucun producteur n'a jamais de workspace sur cette branche, et l'accès en lecture
seule n'a aucune exception à faire respecter — l'état contraire ne peut pas s'écrire.

La raison est simple : un acteur capable d'écrire ici pourrait réécrire, **après coup**, la trace
de ce qu'on lui a demandé et de ce qu'on a jugé de son travail. Une preuve que le prouvé peut
éditer n'est pas une preuve.

La documentation du produit ne vit donc **pas** ici : elle est sur la face `doc` (`workshop`), où
un producteur l'écrit et où l'architecte la relit.

## Qui lit

L'**architecte**, en lecture seule, pour suivre le travail et le rapporter à l'user. C'est le seul
pod qui monte cet arbre, et c'est sa fonction. Aucun autre rôle n'a de raison de voir le grand
livre.
