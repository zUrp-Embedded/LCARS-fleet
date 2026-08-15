# catalogues/ — les catalogues métier

**Date** : 2026-08-10
**Statut** : actif
**Référencé par** : `fleet/deploy/docker/Dockerfile` (copie dans l'image)

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
| `web/` | Catalogue **dev web** — six rôles, trois pipelines. Écrit pour être lu et repris : chaque fichier explique ses choix. Point de départ pour se faire le sien. |

Le catalogue **de référence** de LCARS n'est pas ici : il vit dans `priv/catalogue/`, parce qu'il
est celui que le release embarque par défaut. Cette asymétrie est connue — où vivent et comment se
livrent les catalogues est une question ouverte, traitée séparément.

## Prendre celui-ci et en faire le sien

```bash
cp -r fleet/catalogues/web /chemin/vers/mon-catalogue
# éditez, puis :
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
