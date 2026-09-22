# Branche `tool_request` — les demandes d'outillage

Cette branche est une **boîte aux lettres**, pas une branche de code : elle ne porte que des
manifestes d'outillage sous `ops/toolchains.d/`, et ce README.

## Ce que tu approuves en signant une PR ici

Le manifeste qui entre par cette PR sera appliqué **par root, sur le conteneur**, par
`runtime/bin/lcars-toolchain-converge`. Il n'est pas interprété : le convergeur lit des champs typés
et joue des gabarits de commande fixes, au SHA que tu viens d'approuver. Ce que tu lis dans le diff
est donc exactement ce qui sera fait — c'est la propriété que toute cette mécanique existe pour tenir.

Le champ `evidence` d'un manifeste est écrit **pour toi**. Le convergeur ne le regarde pas.

## Ce qui la protège

`required_approvals=1`, liste d'approbateurs (le siège), et `dismiss_stale_approvals` — un nouveau
push tue l'approbation. Si tu approuves puis que la branche bouge, il faut re-signer. La protection
est posée par la recette de la forge, avec la branche.
