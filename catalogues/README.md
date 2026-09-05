# catalogues/ — les catalogues métier

**Date** : 2026-08-10
**Dernière révision** : 2026-08-16
**Statut** : actif
**Référencé par** : `deploy/docker/Dockerfile` (copie dans l'image)

## Ce que c'est

Un **catalogue** est le métier que la flotte exécute : les rôles, ce qu'ils ont le droit de faire,
les pipelines, qui juge quoi, et les prompts qui donnent à chaque rôle sa compétence. Le runtime
n'en connaît aucun : il exécute celui qu'on lui désigne.

```
LCARS_CATALOGUE_ROOT=/chemin/vers/un/catalogue
```

Une variable, un catalogue entier. Chaque arbre en dérive son sous-chemin.

## Ce qu'il y a ici

| Dossier | Ce que c'est |
|---|---|
| `web-demo/` | Catalogue **dev web** de démonstration — quatre rôles, trois pipelines, ses avatars. Écrit pour être lu et repris : chaque fichier explique ses choix. |

Il s'appelle `web-demo` et non `web` parce que le déploiement le **repose à chaque apply** dans
l'espace personnel du compte master, et que `web` est le nom qu'un vrai catalogue métier voudra
prendre. Un nom qui dit « démonstration » pousse au fork plutôt qu'à l'installation.

Le catalogue **de référence** de LCARS n'est pas ici : il vit dans `priv/catalogue/`, parce qu'il
est celui que le release embarque. C'est ce qui le rend insupprimable, et c'est un choix — garantir
qu'un catalogue valide existe toujours. Une garantie de disponibilité, pas une autorité : il reste
un pair, et un rôle ou une carte d'un autre catalogue ne s'y résout jamais.

## Ce dossier est une GRAINE, pas une installation

Ce que l'image transporte ici est déposé sur la forge à chaque apply et **installé par personne**.
Un catalogue devient installé quand un admin joue `lcars catalogue install <nom>` : le geste crée
son org et ses comptes de rôle, et pousse sa source dans `<nom>/catalogue`. **C'est ce dépôt-là qui
signe l'installation** — le matériel présent sur un conteneur n'en est qu'un cache, reconvergé à chaque
démarrage.

Un seul verbe : réinstaller, c'est mettre à jour. Et jamais de mise à jour automatique.

## Prendre celui-ci et en faire le sien

```bash
# depuis la RACINE du dépôt :
cp -r catalogues/web-demo /chemin/vers/mon-catalogue
# éditez, puis — depuis `fleet/`, la racine Mix :
mix lcars.catalogue.verify /chemin/vers/mon-catalogue
```

La commande rejoue **tous** les contrôles que le démarrage exécute, sans démarrer de flotte : le
manifeste, les images gelées, la preuve que chaque rôle peut être lancé, la cohérence des cartes et
des rôles structurels, les politiques d'escalade. Elle rend `0` ou `1`.

C'est le contrat de sortie : si elle passe, la flotte démarre dessus.

## Ce qui n'est PAS un catalogue

Sous `priv/`, deux arbres restent au runtime et ne se remplacent pas :

- `priv/*/schema/` — les contrats contre lesquels un catalogue est validé ;
- `priv/cap_profile/baseline/` — les planchers qu'un catalogue ne peut pas abaisser.

La règle est la même pour les deux : **ce qu'un opérateur ne doit pas pouvoir remplacer est un
contrat, et un contrat qu'on peut remplacer ne contraint rien.**
