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
# ⚠ NE MONTE JAMAIS UN VOLUME SUR LA RACINE DU MAGASIN — SEULEMENT SUR SES ENFANTS. Cette racine a
# deja un locataire que ce lot n'a pas pose : `PROV_CATALOGUES_WORK` (defini dans
# `provision-lib.sh`) vit dessous, cree par `25-directories.sh`, et il est porte par la COUCHE
# CONTENEUR. Un volume monte a la racine le masquerait — l'etat tofu des catalogues disparaitrait
# derriere un point de montage vide, sans un message. Constate en verifiant le rejeu du 2026-08-19
# sur une machine reelle : le voisin etait la, a cote des quatre montages, et rien ne l'annoncait.
# Les volumes de ce fichier sont ses FRERES, jamais son parent.
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
# ⚠ ET C'EST POUR CA QUE LE NOM PORTE LE PROJET — la premiere version ne le portait pas, et le
# defaut etait GRAVE. `external: true` retire le volume du projet DANS LES DEUX SENS : compose ne le
# detruit pas, et il ne le prefixe pas non plus. Deux installations sur une machine tombaient donc
# sur les MEMES quatre volumes. C'est exactement le cas que docker existe pour servir — une prod et
# un test cote a cote — et jouer avec le test vidait la prod. Sur les bancs, le meme fait rendait
# faux le mot « jetable » : `bench-down` epargnait les quatre en dictant `docker volume rm` pour
# finir le menage, et cette ligne-la emportait le magasin de l'autre banc, en marche.
#
# Le motif qui avait ete ecrit pour justifier ce partage — « trois heures de toolchain se paient une
# fois » — ne tient sur aucun des deux terrains. Sur un banc, une toolchain se compile pour verifier
# que la mecanique marche, pas pour garder l'artefact. Sur une machine de prod, il n'y a qu'UNE
# instance du projet : le partage n'a personne avec qui partager. Le vrai service rendu par
# `external`, lui, reste entier et n'a jamais eu besoin du partage : survivre au `down -v` de SA
# PROPRE boite.
#
# Le prefixe est le NOM DU PROJET COMPOSE, qui est deja l'identite d'une installation : `box` le
# porte (`-p`, defaut `lcars`) et REFUSE de demarrer sur un projet qui n'est pas le sien. Deux
# installations ont donc des prefixes distincts par construction, sans qu'aucun operateur ait a y
# penser — et l'installation par defaut garde exactement les noms d'avant (`lcars-cache`).
#
# Pour `/home` la question ne se pose pas : ses humains sont ceux de CETTE boite, il reste dans le
# projet et meurt avec lui.
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
# separement », la seule question qui justifie de les separer plutot que d'en monter un seul.
#
# ⚠ CE SONT LES NATURES, PAS LES NOMS. Ce que cette liste enumere est stable et ne depend d'aucune
# installation : c'est aussi le nom du sous-repertoire sous `LCARS_STORE_ROOT`, et c'est la clef que
# `26-store.sh` met en regard de sa table de modes. Le NOM DU VOLUME, lui, porte le projet et se
# derive par `store_volume_name` — les deux ne se confondent pas.
LCARS_STORE_TREES=(
  cache        # npm, pip, cargo, hex — perdre coute de la BANDE PASSANTE. Purgeable de routine.
  toolchains   # crosstool-NG, SDK embarques — perdre coute des HEURES. Ne se purge pas a la legere.
  sysroots     # images disque amont extraites — perdre coute un telechargement de plusieurs Go.
  state        # env.d/ et egress.d/ — ETAT CONVERGE, pas un artefact. Petit, et sa perte est MUETTE.
)

# store_volume_name <nature> — le nom REEL du volume docker pour cette installation.
#
# ⚠ LE PREFIXE EST EXIGE, JAMAIS DEFAUTE ICI. Un defaut silencieux ferait retomber deux
# installations sur le meme nom — le defaut meme que ce prefixe existe pour tuer, ressuscite par
# commodite. L'appelant qui n'a pas de projet n'a pas d'installation : il doit s'arreter.
#
# ⚠ GARDE EXPLICITE, PAS `${VAR:?message}`, ET LES DEUX RAISONS SONT MESUREES (bash 5, 2026-08-20) :
#   1. bash tue le shell non-interactif et sort en 127 — le code de « commande introuvable ». Un
#      appelant qui lit ce code cherche un binaire manquant, jamais une variable non posee.
#   2. le mot du `:?` subit la suppression des quotes : les apostrophes du message DISPARAISSENT.
#      « l'identite de l'installation » sortait en « lidentite de linstallation ».
# Le `:?` reste juste pour un garde interne dont personne ne lit le texte ; celui-ci est
# operateur-facing.
store_volume_name() {
  if [[ -z "${LCARS_STORE_PREFIX:-}" ]]; then
    echo "store: LCARS_STORE_PREFIX absent — le nom du projet compose EST l'identite d'une installation ; sans lui, deux installations sur cette machine partageraient leur magasin" >&2
    return 1
  fi
  [[ -n "${1:-}" ]] || { echo "store_volume_name: nature attendue (cache|toolchains|sysroots|state)" >&2; return 1; }
  printf '%s-%s' "$LCARS_STORE_PREFIX" "$1"
}

# store_volume_names — les quatre noms reels, un par ligne. Rend non-zero si le prefixe manque, et
# n'ecrit RIEN dans ce cas : une liste partielle serait pire qu'une liste vide (l'appelant qui
# detruit en effacerait une partie et croirait avoir fini).
store_volume_names() {
  local nature name
  for nature in "${LCARS_STORE_TREES[@]}"; do
    name="$(store_volume_name "$nature")" || return 1
    printf '%s\n' "$name"
  done
}

# ⚠ CE QUI N'EST PAS ENCORE FAIT, ET QUI SE VOIT SUR UN BANC NEUF. Les quatre points de montage
# naissent `root:root 0755` — c'est docker qui les cree, pas nous. `01` §4.8 du rail toolchain exige
# `root:fleet 2775` (setgid) plus `umask 002` cote pod, sans quoi un humain de la boite ne peut ni
# ecrire dans le cache ni ecraser le fichier d'un autre. Mesure du 2026-08-19 sur .63 : montages
# corrects, modes non poses. C'est l'etape 2 du rail toolchain, pas ce lot — mais un magasin monte
# et non ouvert a l'air fini alors qu'il ne sert encore a personne, et ca se dit ici plutot que de
# se decouvrir au premier build qui echoue sur un « permission denied » dans un cache.

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
# ⚠ LES NOMS SE CAPTURENT AVANT LA BOUCLE, PAS EN SUBSTITUTION DE PROCESSUS. `while read … < <(f)`
# JETTE le code de retour de `f` : prefixe absent => zero ligne => la boucle ne tourne pas => `rc`
# reste 0 et le geste rend un SUCCES MUET, sur un magasin qui n'existe pas. La substitution de
# commande, elle, propage.
store_ensure_volumes() {
  local docker_bin="${1:-docker}" vol rc=0 names
  names="$(store_volume_names)" || return 1
  for vol in $names; do
    "$docker_bin" volume create "$vol" >/dev/null 2>&1 || {
      echo "store: impossible de creer le volume « $vol » — le up refusera de demarrer (external: true)" >&2
      rc=1
    }
  done
  return "$rc"
}

# store_destroy_volumes <docker-bin> — DETRUIT le magasin de CETTE installation.
#
# ⚠ N'EXISTE QUE PARCE QUE LES NOMS PORTENT LE PROJET. Sans prefixe, ce geste aurait emporte le
# magasin de toutes les installations de la machine — c'est pour ca qu'il n'existait pas, et que la
# destruction se dictait a l'operateur en toutes lettres (`docker volume rm lcars-cache …`), la seule
# forme possible etant alors « et tu regardes bien ce que tu tapes ». Une ligne dictee est un geste
# quand meme : celle-la vidait le banc d'a cote, en marche.
#
# `-f` : un volume absent n'est pas une erreur. Rejouer une destruction est normal.
# Meme piege que `store_ensure_volumes`, et il coute plus cher ici : un prefixe absent rendrait
# « magasin detruit » sans avoir touche un seul volume.
store_destroy_volumes() {
  local docker_bin="${1:-docker}" vol rc=0 names
  names="$(store_volume_names)" || return 1
  for vol in $names; do
    "$docker_bin" volume rm -f "$vol" >/dev/null 2>&1 || rc=1
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
#
# ⚠ RESTE JUSTE POUR `box reset`, ET SEULEMENT LA. Reinitialiser une boite n'est pas jeter une
# installation : le magasin lui survit, c'est son interet. Un banc, lui, est JETABLE — l'epargne y
# etait un mensonge sur le mot, et `bench-down` detruit desormais (`store_destroy_volumes`).
#
# La ligne dictee nomme maintenant les volumes DE CETTE INSTALLATION : quand ils n'etaient pas
# prefixes, la taper vidait aussi les voisines.
store_spared_line() {
  local names
  names="$(store_volume_names)" || return 1
  names="$(printf '%s' "$names" | tr '\n' ' ')"; names="${names% }"
  printf 'EPARGNES (magasin de « %s », hors projet compose) : %s — ils survivent a ce geste.\n' \
    "$LCARS_STORE_PREFIX" "$names"
  printf '  Pour les detruire VRAIMENT : docker volume rm %s\n' "$names"
}
