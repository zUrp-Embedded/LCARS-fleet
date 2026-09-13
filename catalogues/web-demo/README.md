# web-demo — le catalogue métier de démonstration

**Date** : 2026-08-16
**Statut** : actif — livré avec l'image, déposé sur la forge, **jamais installé par défaut**
**Référencé par** : `GUIDE.md` (même dossier), `catalogues/README.md`

## ⚠ CE DÉPÔT EST REPOSÉ PAR LE DÉPLOIEMENT — forke-le, ne l'édite pas ici

Le déploiement le repousse à chaque apply, en **projection** : un commit frais qui reflète
exactement l'arbre livré dans l'image. Toute modification faite directement dans ce dépôt
disparaît au passage suivant, **sans avertissement**.

Ce n'est pas un défaut : c'est ce qui garantit que la démonstration reste celle qu'on documente.
Mais ça se dit ici plutôt que de s'apprendre en perdant son travail.

**Pour en faire le vôtre** : clonez-le, renommez-le dans son `catalogue.yaml`, poussez-le dans
**votre** espace personnel sur la forge, et demandez à un admin de l'installer. C'est exactement
le geste que ce catalogue existe pour enseigner.

## Ce qu'il est

Un catalogue **complet et simple** : quatre rôles (`dev`, `writer`, `code-reviewer`,
`spec-reviewer`), trois cartes de pipeline, un modèle de projet, une politique d'escalade, et les
avatars des quatre rôles. Il passe les mêmes contrôles que le catalogue de référence — c'est un
autre métier, pas un exemple réduit.

Il s'appelle `web-demo` et non `web` pour une raison précise : `web` est le nom qu'un vrai
catalogue métier voudra prendre, et un dépôt de démonstration reposé à chaque apply entrerait en
collision avec lui. Le nom vous pousse au fork plutôt qu'à l'installation, ce qui est la bonne
direction.

## Où il vit

- **dans l'image**, à `/opt/lcars/catalogues/web-demo` — la graine ;
- **sur la forge**, dans l'espace personnel du compte master (`id = 1`) — le dépôt, donc
  `available` ;
- **nulle part ailleurs** tant que personne ne l'installe. `lcars catalogue list` le montre
  disponible ; `lcars catalogue install web-demo`, joué par un admin, lui crée son org et ses
  comptes.

Le compte master est choisi parce que c'est le **seul espace garanti présent que LCARS n'a pas
inventé** : Gitea le crée à son installation, avant nous. Tout le reste — le login de l'humain, les
comptes de rôle, l'org — est notre mobilier, donc renommable, donc un mauvais point d'ancrage.

## Le reste

`GUIDE.md`, à côté, explique le contenu fichier par fichier et comment le modifier.
