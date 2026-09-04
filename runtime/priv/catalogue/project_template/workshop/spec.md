# ${REPO_NAME} — Spec de cadrage

**Date** : ${YEAR}-${MONTH}-${DAY}
**Dernière révision** : ${YEAR}-${MONTH}-${DAY}
**Statut** : actif — matière de cadrage, écrite par l'architecte avec son humain
**Référencé par** : `backlog.md`, et les briefs qui la pointent
**Dérivé de** : —

> ${REPO_DESCRIPTION}

## Pourquoi ce fichier est ICI et pas sur `main`

Il vivait dans `main/docs/`, vide, et **personne ne pouvait l'écrire** : l'architecte produit sur
cette face-ci, pas sur la face code, et un producteur n'écrit que ce qu'un brief lui demande — or
c'est ce fichier qui rend un brief écrivable. Mesuré le 2026-08-12 sur un projet réel : deux briefs
renvoyés par le scoper faute de contraintes, et la spec finalement écrite par l'engineer **à la
livraison** — après le brief qu'elle aurait dû fonder.

Ici, l'architecte l'écrit au terminal avec son humain dès le premier échange, la commite, et la
**pointe dans ses briefs**. Aucun transport : le producteur monte cette face en lecture seule, en
permanence.

⚠ C'est de la **matière**, pas un livrable. Rien ne pousse cette face toute seule, rien de ce qui
s'écrit ici n'entre dans le projet tel quel. Si le projet doit un jour porter une spec **livrée**
(revue, scellée, dans l'arbre du dépôt), c'est un ticket scribe ordinaire — pas une case de ce
squelette.

## Pitch

(à compléter — ce que le produit fait, pour qui, et ce qu'il ne fait pas)

## Contraintes

(à compléter — ce qui n'est pas négociable : plateforme, dépendances interdites, budget, format
d'entrée/sortie, ce que la fleet ne doit pas inventer à ta place)

## Critères de fin

(à compléter — comment on saura que c'est fait. Un critère qu'un juge ne peut pas vérifier n'en est
pas un.)
