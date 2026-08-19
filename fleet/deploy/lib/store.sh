#!/usr/bin/env bash
# SOURCE: fleet/deploy/lib/store.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — les volumes du MAGASIN : ce qui coute du temps a refabriquer
#
# CE FICHIER NE POSSEDE QUE LES NOMS DES VOLUMES. Le CHEMIN ou ils se montent appartient au
# compose, et lui seul l'ecrit — deux fois dans un meme fichier, jamais dans deux fichiers. Tout ce
# qui vit DANS la boite (entrypoint, convergeur, BEAM) le recoit par `LCARS_STORE_ROOT`, pose par
# le compose. Un chemin recopie ici en serait une seconde verite, et c'est toujours celle qu'on ne
# lit pas qui gagne.
#
# POURQUOI DES VOLUMES EXTERNES, ET CE QUE CA ACHETE : `external: true` les met HORS PROJET, donc
# `compose down -v` ne peut pas les emporter. Ce n'est pas de la discipline, c'est le contrat de
# docker. Mesure du 2026-08-18 : `docker compose -p vtest down -v` detruit `vtest_projet-home` et
# laisse `toolchain-arm64` intact.
#
# LE PRIX, ET IL EST LA BONNE PROPRIETE : un volume externe doit exister AVANT le `up`, sinon
# compose refuse de demarrer. Sa creation devient donc un geste delibere — ce qu'on veut d'un objet
# qui coute trois heures de CPU. C'est `store_ensure_volumes` qui le pose, et c'est pour ca qu'elle
# est appelee par le script d'ENTREE : aucun autre endroit ne s'execute avant le `up`.
#
# Effet de bord voulu : un volume externe n'est pas prefixe par le projet, donc il est PARTAGE
# entre les bancs de la machine. Pour un cache c'est exactement le but — trois heures une fois,
# pas une par banc. Pour `/home` ce serait faux : ses humains sont ceux de CE banc, il reste dans
# le projet.
#
# ⚠ CE QUI N'EST PAS ICI, ET N'A RIEN A Y FAIRE : la toolchain BATIE (crosstool-NG, GCC+glibc
# construits a la main). Elle est la seule des quatre natures d'artefact SANS recette amont, donc
# la seule qui doive porter un digest et une recette declaree — c'est une image DOCKER, jumelle de
# `lcars-build:2`, pas une arborescence. Elle herite en echange de la faiblesse du magasin
# d'images : `docker system prune -a` moissonne ce que `down -v` epargne. Cf.
# work/beyond_#6/chantier-identite-admiral-2026-08-18/03-reconciliation_poste-et-toolchain.md §2.

# ⚠ CETTE LISTE EN COMPTAIT DEUX, ET TROIS DES CINQ CHEMINS DECLARES N'AVAIENT PAS DE VOLUME.
# Releve par l'agent du chantier toolchain le 2026-08-19, et il avait raison sur les trois :
#   - le volume s'appelait `lcars-toolchain` et le chemin declare est `toolchains/` — UN caractere,
#     et l'artefact a trois heures atterrit A COTE de son propre volume, sur la couche conteneur ;
#   - `sysroots/` n'avait aucun volume ;
#   - `env.d/` et `egress.d/` non plus, et c'est le plus vicieux : les perdre ne coute RIEN DE
#     VISIBLE. La toolchain reste intacte, le pod cesse simplement de la voir, et l'install sort
#     verte pendant que la compilation echoue sans que rien ne relie les deux symptomes.
#
# Quatre volumes, un par DUREE DE VIE — c'est-a-dire par « qu'est-ce qu'on accepterait de purger
# separement », la seule question qui justifie de les separer plutot que d'en monter un seul :
LCARS_STORE_VOLUMES=(
  lcars-cache        # npm, pip, cargo, hex — perdre coute de la BANDE PASSANTE. Purgeable de routine.
  lcars-toolchains   # crosstool-NG, SDK embarques — perdre coute des HEURES. Ne se purge pas a la legere.
  lcars-sysroots     # images disque amont extraites — perdre coute un telechargement de plusieurs Go.
  lcars-state        # env.d/ et egress.d/ — ETAT CONVERGE, pas un artefact. Petit, et sa perte est MUETTE.
)

# store_ensure_volumes <docker-bin> — cree ce qui manque, ne touche a rien d'autre.
#
# ⚠ UN BINAIRE, PAS UNE LIGNE DE COMMANDE. `store_ensure_volumes "sudo -E docker"` cherche un
# executable dont le NOM contient des espaces et echoue en annoncant que le volume n'a pas pu etre
# cree — un diagnostic qui accuse docker alors que c'est l'appel qui est mal forme. Teste ici meme
# en ecrivant cette fonction. Si un appelant a besoin d'une escalade, il la met dans un shim et
# passe le chemin du shim, comme le rail le fait deja ailleurs.
#
# `docker volume create` est IDEMPOTENT sur un volume existant (il rend son nom et sort 0) : il n'y
# a donc rien a sonder avant, et surtout rien qui puisse ecraser le contenu d'un volume deja la.
# On ne cree JAMAIS avec des options (labels, driver) : un volume qui existe deja les ignorerait en
# silence, et deux bancs le creeraient differemment selon lequel a demarre le premier.
store_ensure_volumes() {
  local docker_bin="${1:-docker}" vol rc=0
  for vol in "${LCARS_STORE_VOLUMES[@]}"; do
    "$docker_bin" volume create "$vol" >/dev/null 2>&1 || {
      echo "store: impossible de creer le volume « $vol » — le up refusera de demarrer (external: true)" >&2
      rc=1
    }
  done
  return "$rc"
}

# store_spared_line — CE QUE LA DESTRUCTION EPARGNE, dit par celui qui sait.
#
# ⚠ CONTREPARTIE NON NEGOCIABLE DES VOLUMES EXTERNES. Un geste de destruction qui dit « ceci efface
# les volumes » comme un bloc, alors qu'il en epargne deux, fabrique la croyance « la machine est
# propre ». Des heures de toolchain dorment alors invisibles jusqu'au jour ou quelqu'un purge un
# cache et se demande ce qu'il vient de perdre. Un effacement silencieux sur ce qu'il LAISSE est un
# mensonge par omission, et il ne se decouvre qu'au pire moment.
store_spared_line() {
  printf 'EPARGNES (volumes externes, hors projet) : %s — ils survivent a ce geste.\n' \
    "${LCARS_STORE_VOLUMES[*]}"
  printf '  Pour les detruire VRAIMENT : docker volume rm %s\n' "${LCARS_STORE_VOLUMES[*]}"
}
