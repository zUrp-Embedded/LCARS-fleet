# `_catalogues` — la source de chaque catalogue installé

Ce dépôt appartient au système LCARS. Il porte **une branche par catalogue installé**, nommée comme
le catalogue, et cette branche est la source que la fleet a installée : c'est elle qui SIGNE
l'installation. Une org de catalogue sans sa branche ici est une installation interrompue.

Personne ne pousse ici à la main. `lcars catalogue install <nom>`, joué dans le conteneur, résout la
source du catalogue, la vérifie, pose son org et ses comptes, puis projette cette source sur la
branche `<nom>` — un commit neuf à chaque fois, portant en pied la révision de la source dont il est
la projection (`Source-Commit:`). Les conteneurs de cette forge clonent cette branche pour servir le
catalogue.

Cette branche-ci (`main`) ne porte que ce fichier : elle n'est le magasin de personne.
