#!/usr/bin/env bash
# SOURCE: runtime/services/lib/facts.sh
# AUTHOR: bob
# STARDATE: 2026-09-19
# STATUS: actif — LES FAITS DE LA MACHINE pour le shell : l'unique lecteur de `etc/facts.env`
#
# ⚖ Decision 3 du plan runtime (R6). Un fait — le groupe `fleet`, l'org systeme, le repertoire des
# jetons — s'ecrit une fois, dans `etc/facts.env`. Ce fichier-ci est le seul endroit du shell qui
# sait le lire : `module-protocol.sh` le source, et les scripts qui ne sont PAS des modules (la
# console, le CLI, le convergeur, la landing) le sourcent aussi, au lieu de reecrire un defaut.
#
# ⚠ SOURCE, JAMAIS EXECUTE. Aucun `set -e` ici : l'appelant a deja pose le sien.
#
# ⚠ UN FICHIER DE FAITS ILLISIBLE EST UNE MORT, PAS UN DEFAUT VIDE. Sans ce garde, un geste
# tournerait avec `LCARS_PRIVATE_DIR=""` et irait chercher ses jetons a la racine — le pire des
# comportements, silencieux et destructeur. Ce qu'on n'a pas pu lire ne se devine pas.
#
# ⚠ L'ENVIRONNEMENT GAGNE SUR LE FAIT. Un fait est un DEFAUT : ce que l'installeur transporte par
# `services.env`, ou ce qu'un operateur pose a la main, prime. Meme ordre que le lecteur Python
# (`lcars_facts.py`) et que l'Elixir (`Fleet.Facts`), sinon les rails liraient deux valeurs du meme nom.
#
# OU EST LE FICHIER. `../../etc/facts.env` depuis CE fichier : dans un checkout c'est
# `runtime/etc/`, sur une machine posee `services/lib/` est sous `/opt/lcars/`, donc `/opt/lcars/etc/`.
# Le meme chemin relatif resout les deux mondes. `LCARS_FACTS_FILE` passe devant, pour les temoins.

LCARS_FACTS_FILE="${LCARS_FACTS_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/etc/facts.env}"
if [[ -r "$LCARS_FACTS_FILE" ]]; then
  while IFS='=' read -r _cle _val; do
    [[ "$_cle" == LCARS_* ]] || continue
    [[ -n "${!_cle:-}" ]] || printf -v "$_cle" '%s' "$_val"
    export "${_cle?}"
  done < "$LCARS_FACTS_FILE"
  unset _cle _val
else
  echo "FATAL ${LCARS_MODULE_TAG:-${0##*/}}: fichier de faits illisible ($LCARS_FACTS_FILE) — les faits de la machine ne se devinent pas. Sur un poste, « deploy/workstation up » le pose ; dans un conteneur, l'image le porte." >&2
  exit 1
fi
