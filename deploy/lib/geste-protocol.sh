#!/usr/bin/env bash
# SOURCE: deploy/lib/geste-protocol.sh
# AUTHOR: bob
# STARDATE: 2026-09-14
# STATUS: le protocole intermédiaire des gestes que prov_geste lance — celui du produit, dont chaque sortie de verdict se marque
#
# Un geste de runtime/services/forge.d source LCARS_MODULE_PROTOCOL : prov_geste lui donne ce fichier, qui
# source le protocole du produit (PROV_GESTE_PROTOCOLE) puis enveloppe verdict_check, verdict_apply et p_die.
# Chacun écrit la marque PROV_GESTE_RENDU avant de rendre la main à celui du produit ; une sortie sans marque
# est une mort avant verdict, que la garde du module rend en 3. Resourcé, le fichier repart des fonctions du
# produit : les enveloppes ne s'empilent pas.

# shellcheck source=../../runtime/services/lib/module-protocol.sh
. "${PROV_GESTE_PROTOCOLE:?PROV_GESTE_PROTOCOLE non posé — ce protocole se source par prov_geste}"

eval "_produit_$(declare -f verdict_check)"
eval "_produit_$(declare -f verdict_apply)"
eval "_produit_$(declare -f p_die)"
verdict_check() { echo rendu > "$PROV_GESTE_RENDU"; _produit_verdict_check "$@"; }
verdict_apply() { echo rendu > "$PROV_GESTE_RENDU"; _produit_verdict_apply "$@"; }
p_die()         { echo rendu > "$PROV_GESTE_RENDU"; _produit_p_die "$@"; }
