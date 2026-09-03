#!/usr/bin/env bash
# SOURCE: deploy/lib/store.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — les volumes du MAGASIN : ce qui coute du temps a refabriquer
# NE MONTE JAMAIS UN VOLUME SUR LA RACINE DU MAGASIN — SEULEMENT SUR SES ENFANTS. La racine a
# deja un locataire porte par la COUCHE CONTENEUR : `PROV_CATALOGUES_WORK`, cree par
# `25-directories.sh`. Un volume monte a la racine le masquerait — l'etat tofu des catalogues
# disparaitrait derriere un point de montage vide, sans un message. Les volumes de ce fichier sont
# ses FRERES, jamais son parent.
#
# `external: true` (pose par le compose, pas ici) les met hors projet, donc `compose down -v` ne peut
# pas les emporter. En echange ils doivent exister AVANT le `up`, sinon compose refuse de demarrer :
# c'est `store_ensure_volumes` qui les pose, et TOUT geste qui monte la boite doit l'appeler.

LCARS_STORE_TREES=(
  cache        # npm, pip, cargo, hex — perdre coute de la BANDE PASSANTE. Purgeable de routine.
  toolchains   # crosstool-NG, SDK embarques — perdre coute des HEURES. Ne se purge pas a la legere.
  sysroots     # images disque amont extraites — perdre coute un telechargement de plusieurs Go.
  state        # env.d/ et egress.d/ — ETAT CONVERGE, pas un artefact. Petit, et sa perte est MUETTE.
)

# store_volume_name <nature> — le nom REEL du volume docker pour cette installation.
#
# ⚠ GARDE EXPLICITE, PAS `${VAR:?message}` : (1) `:?` tue le SHELL ENTIER, il ne rend pas la main a
# l'appelant qui voudrait decider ; (2) le mot du `:?` subit la suppression des quotes, donc les
# apostrophes DISPARAISSENT du message affiche — « l'identite de l'installation » sort en
# « lidentite de linstallation ».
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

# store_ensure_volumes <docker-bin> — cree ce qui manque, ne touche a rien d'autre.
#
# `docker volume create` est IDEMPOTENT sur un volume existant (il rend son nom et sort 0) : rien a
# sonder avant, et rien qui puisse ecraser le contenu d'un volume deja la. On ne cree JAMAIS avec
# des options (labels, driver) : un volume deja present les ignore en silence, et deux bancs le
# creeraient differemment selon lequel a demarre le premier.
#
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
store_destroy_volumes() {
  local docker_bin="${1:-docker}" vol rc=0 names
  names="$(store_volume_names)" || return 1
  for vol in $names; do
    "$docker_bin" volume rm -f "$vol" >/dev/null 2>&1 || rc=1
  done
  return "$rc"
}

# store_spared_line — CE QUE LA DESTRUCTION EPARGNE, dit par celui qui sait.
# NE S'APPELLE QUE D'UN GESTE AUQUEL LE MAGASIN SURVIT — `box reset` reinitialise une boite, il ne
# jette pas l'installation. Un geste qui JETTE detruit (`store_destroy_volumes`) : y annoncer une
# epargne serait un mensonge sur le mot.
store_spared_line() {
  local names
  names="$(store_volume_names)" || return 1
  names="$(printf '%s' "$names" | tr '\n' ' ')"; names="${names% }"
  printf 'EPARGNES (magasin de « %s », hors projet compose) : %s — ils survivent a ce geste.\n' \
    "$LCARS_STORE_PREFIX" "$names"
  printf '  Pour les detruire VRAIMENT : docker volume rm %s\n' "$names"
}
