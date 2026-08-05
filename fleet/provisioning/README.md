# `fleet/provisioning/` — arbre v1, PLUS AUCUNE DEPENDANCE VIVANTE

**Date** : 2026-08-05
**Dernière révision** : 2026-08-05
**Statut** : archive — le provisioning courant est `fleet/provisioning_v2/`
**Référencé par** : rien de vivant (mesuré, cf. ci-dessous)

## Ce qui a changé le 2026-08-05

Cet arbre portait encore **une** jambe du provisioning courant : la recette OpenTofu de la forge,
sous `deps/`. Deux scripts de `provisioning_v2` la copiaient (`bench-up.sh`, `bench-forge-bootstrap.sh`)
et l'aide de `docker.sh` l'indiquait à l'opérateur. Un nettoyage de cet arbre — fait en le croyant
mort, ce qu'il paraissait — aurait cassé le déploiement.

`deps/` vit désormais en **`fleet/provisioning_v2/deps/`**, avec le provisioning qui s'en sert. Les
huit sites qui la nommaient suivent.

## Ce qui reste ici

Tout est v1 (`_archived/`, `deploy.d/`, `docker/`, `provision.d/`, `v1/`). Les seules références
restantes à `fleet/provisioning/` sont **internes à cet arbre** : des scripts v1 qui s'appellent
entre eux. Rien dans `provisioning_v2/`, dans `docker.sh`, dans le Dockerfile ni dans le runtime ne
pointe plus ici.

⚠ **Si tu as un état OpenTofu local** (`terraform.tfstate`, `.terraform/`) dans l'ancien
`deps/` : il est gitignoré, donc le déplacement ne l'a pas emporté. Déplace-le à la main vers
`provisioning_v2/deps/`, sinon le prochain `tofu apply` repart d'un état VIDE face à une forge où
l'org, les teams et les comptes existent déjà. (Aucun n'était présent sur la machine où le
déplacement a été fait — vérifié.)
