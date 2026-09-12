#!/usr/bin/env bash
# SOURCE: deploy/lib/store.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — les volumes du MAGASIN : ce qui coute du temps a refabriquer

LCARS_STORE_TREES=(
  cache        # npm, pip, cargo, hex — perdre coute de la BANDE PASSANTE. Purgeable de routine.
  toolchains   # crosstool-NG, SDK embarques — perdre coute des HEURES. Ne se purge pas a la legere.
  sysroots     # images disque amont extraites — perdre coute un telechargement de plusieurs Go.
  state        # env.d/ et egress.d/ — ETAT CONVERGE, pas un artefact. Petit, et sa perte est MUETTE.
)

store_volume_name() {
  if [[ -z "${LCARS_STORE_PREFIX:-}" ]]; then
    echo "store: LCARS_STORE_PREFIX absent — le nom du projet compose EST l'identite d'une installation ; sans lui, deux installations sur cette machine partageraient leur magasin" >&2
    return 1
  fi
  [[ -n "${1:-}" ]] || { echo "store_volume_name: nature attendue (cache|toolchains|sysroots|state)" >&2; return 1; }
  printf '%s-%s' "$LCARS_STORE_PREFIX" "$1"
}

store_volume_names() {
  local nature name
  for nature in "${LCARS_STORE_TREES[@]}"; do
    name="$(store_volume_name "$nature")" || return 1
    printf '%s\n' "$name"
  done
}

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

store_destroy_volumes() {
  local docker_bin="${1:-docker}" vol rc=0 names
  names="$(store_volume_names)" || return 1
  for vol in $names; do
    "$docker_bin" volume rm -f "$vol" >/dev/null 2>&1 || rc=1
  done
  return "$rc"
}

store_spared_line() {
  local names
  names="$(store_volume_names)" || return 1
  names="$(printf '%s' "$names" | tr '\n' ' ')"; names="${names% }"
  printf 'EPARGNES (magasin de « %s », hors projet compose) : %s — ils survivent a ce geste.\n' \
    "$LCARS_STORE_PREFIX" "$names"
  printf '  Pour les detruire VRAIMENT : docker volume rm %s\n' "$names"
}
