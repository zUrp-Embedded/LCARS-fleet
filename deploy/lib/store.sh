#!/usr/bin/env bash
# SOURCE: deploy/lib/store.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: les volumes du magasin d'une instance — ce qui coûte du temps à refabriquer, hors du projet compose

LCARS_STORE_TREES=(
  cache        # npm, pip, cargo, hex — perdre coute de la BANDE PASSANTE. Purgeable de routine.
  toolchains   # crosstool-NG, SDK embarques — perdre coute des HEURES. Ne se purge pas a la legere.
  sysroots     # images disque amont extraites — perdre coute un telechargement de plusieurs Go.
  state        # env.d/ et egress.d/ — ETAT CONVERGE, pas un artefact. Petit, et sa perte est MUETTE.
)

store_volume_names() { # store_volume_names → un volume par nature, au nom du projet compose
  if [[ -z "${LCARS_STORE_PREFIX:-}" ]]; then
    echo "store : LCARS_STORE_PREFIX absent — le nom du projet compose est l'identité d'une installation ; sans lui, deux installations sur cette machine partageraient leur magasin" >&2
    return 1
  fi
  local nature
  for nature in "${LCARS_STORE_TREES[@]}"; do
    printf '%s-%s\n' "$LCARS_STORE_PREFIX" "$nature"
  done
}

store_ensure_volumes() {
  local docker_bin="${1:-docker}" vol rc=0 names
  names="$(store_volume_names)" || return 1
  for vol in $names; do
    "$docker_bin" volume create "$vol" >/dev/null 2>&1 || {
      echo "store : impossible de créer le volume « $vol » — le up refusera de démarrer (external: true)" >&2
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
  printf 'ÉPARGNÉS (magasin de « %s », hors projet compose) : %s — ils survivent à ce geste.\n' \
    "$LCARS_STORE_PREFIX" "$names"
  printf '  Pour les détruire : docker volume rm %s\n' "$names"
}
