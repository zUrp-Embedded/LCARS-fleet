# ${REPO_NAME} — face `doc` : l'atelier

**Date** : ${YEAR}-${MONTH}-${DAY}
**Dernière révision** : ${YEAR}-${MONTH}-${DAY}
**Statut** : actif — arbre de travail, ne sort JAMAIS du projet
**Référencé par** : les pods qui produisent sur cette face (extraction sélective, voir plus bas)

## Ce que cet arbre contient

Le matériau à partir duquel le projet se construit, et qui **ne part pas avec lui** : backlog,
plans, brouillons de spec, notes de conception, scratchpad. Il vit sur une branche orpheline
(`work/doc`) et n'est jamais mergé dans le produit.

**La documentation qui SORT n'est pas ici.** Doc utilisateur, doc mainteneur, doc de fork : elles
vivent dans `docs/` sur la face code, sont écrites par un producteur qui travaille là-bas, et se
font juger comme n'importe quel autre livrable.

Le critère qui sépare les deux n'est pas la nature de l'artefact — de la prose reste de la prose —
c'est la **destination**.

## Ce fichier est lu par une machine, et voilà ce qu'elle emporte

À chaque spawn, la fleet lit le `CLAUDE.md` du worktree du pod et recopie dans le sien **sept
sections de niveau 2, et sept seulement** :

`## Stack` · `## Build` · `## Test` · `## Doc` · `## Conventions` · `## Commands` · `## Gotchas`

Tout le reste — y compris la section ci-dessus — est ignoré : un titre nommé autrement ne voyage
pas.

⚠ Le `CLAUDE.md` de la face code, lui, laisse ces titres FERMÉS exprès : un titre creux ferait
croire à la fleet qu'elle a du contexte et à l'agent qu'il a une commande. **Ici `## Conventions`
est rempli, et ce n'est pas la même situation** : ce qui y est écrit n'est pas du contexte
spécifique au projet qu'il faudrait deviner, c'est une propriété de la face, vraie pour tout projet
par construction. Les six autres titres restent fermés, pour la raison d'origine.

Et `## Doc` en particulier n'a rien à faire ici : il désigne la documentation qui **sort**, elle
vit dans `docs/` sur la face code, et cet arbre-ci ne livre rien.

## Conventions

Tu produis sur la face **atelier** de ce projet. Ce que tu écris ici ne sera **jamais livré** : ça
reste dans le dépôt de travail, ça ne part avec aucune release, aucun fork, aucun paquet.

Trois conséquences, et elles se tiennent :

1. **Aucun jury ne juge cette livraison.** Ce n'est pas une faveur ni un raccourci : un jury protège
   un lecteur ABSENT — un tiers, un fork, une session future. Ici le lecteur est celui qui a écrit
   la demande, il est présent, et c'est lui qui clôt.
2. **Aucun verdict opposable ne t'est demandé.** Si ton mandat est d'auditer un document qu'on te
   remet (« on a essayé d'écrire ça, vérifie »), dis ce que tu contestes et pourquoi, dans ton
   résultat. Rendre un document amélioré sans dire ce que tu as contesté n'est pas un audit : c'est
   une réécriture silencieuse, et personne ne pourra la relire comme telle.
3. **Si ce qu'on te demande est destiné à sortir, ce n'est pas ici que ça se fait.** Un guide
   utilisateur, une doc mainteneur, un README de fork — tout ce qui atterrit dans `docs/` — est un
   livrable : il s'écrit sur la face code et se fait juger. Si le ticket que tu tiens te demande ça,
   ÉCRIS-LE dans ton résultat plutôt que de le produire ici : le document serait correct et il
   serait posé au mauvais endroit, sur une branche que personne n'ouvrira jamais.
