#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/console-humans.sh
# AUTHOR: consultant
# STARDATE: 2026-07-31
# STATUS: enumeration des humains eligibles a un bloc de ports — source UNIQUE de la regle
#
# POURQUOI UN FICHIER A LUI SEUL : deux consommateurs (console.sh --all et console-landing.sh) ont
# besoin de la meme liste. Recopier la regle dans les deux, c'est garantir qu'une des deux copies
# derive le jour ou on la corrige — et une garde qui derive est pire qu'une garde absente, parce
# qu'on croit l'avoir.
#
# ─── LA GARDE ANTI-SYSTEME, ET POURQUOI ELLE N'EST PAS UN TEST DE MODULO ────────────────────────
# Le bloc de ports vaut `21000 + (uid % 500) * 10`. Consequence brute : **uid 0 (root) et uid 1000
# tombent sur le MEME bloc 21000**, parce que 0 % 500 == 0 et 1000 % 500 == 0. Deux identites, un
# seul bloc : la console de root ecraserait celle du premier humain, ou refuserait de binder.
# (Trou releve par l'audit `ring0-substrat`, jamais instruit jusqu'ici.)
#
# La garde correcte n'est PAS « rejeter uid % 500 == 0 » — ca rejetterait uid 1000, l'humain
# nominal. C'est un PLANCHER D'UID : les comptes systeme n'ont pas de console, point. Convention
# Debian : < 1000 = systeme. Et 65534 (`nobody`) est au-dessus mais n'est pas un humain non plus,
# d'ou le plafond.
#
# USAGE  : console-humans.sh            → une ligne par humain : « login uid base »
#          console-humans.sh --verbose  → + les rejets sur stderr, avec leur motif
# EXIT   : 0 toujours (une liste vide est un resultat, pas une erreur)

set -uo pipefail

VERBOSE=0
[[ "${1:-}" == "--verbose" ]] && VERBOSE=1

UID_MIN="${LCARS_CONSOLE_UID_MIN:-1000}"
UID_MAX="${LCARS_CONSOLE_UID_MAX:-59999}"

# Deux classes de rejet, et elles ne meritent PAS le meme bruit :
#   - hors plage d'uid (root, daemon, www-data, nobody…) : ATTENDU a chaque boot. Detailler 19
#     lignes de comptes systeme, c'est apprendre a l'humain a ne plus lire ses logs. → un compte.
#   - dans la plage mais inapte (pas de home, shell nologin) : SURPRENANT. C'est un humain qui
#     aurait du avoir une console et ne l'a pas. → detaille, nominativement.
system_n=0
reject_system() { system_n=$(( system_n + 1 )); }
reject_odd()    { [[ "$VERBOSE" -eq 1 ]] && echo "[humans] rejete $1 : $2" >&2; return 0; }

while IFS=: read -r login _ uid _ _ home shell; do
  [[ -n "$login" ]] || continue

  if [[ "$uid" -lt "$UID_MIN" ]]; then
    # Le cas qui compte : root (uid 0) partagerait le bloc 21000 avec uid 1000.
    reject_system
    continue
  fi
  if [[ "$uid" -gt "$UID_MAX" ]]; then
    reject_system
    continue
  fi
  if [[ ! -d "$home" ]]; then
    reject_odd "$login" "home absent ($home) — une console sans home s'ouvre sur / et ment"
    continue
  fi
  case "$shell" in
    */nologin|*/false|"")
      reject_odd "$login" "shell $shell — le compte n'est pas fait pour ouvrir un shell"
      continue ;;
  esac

  printf '%s %s %s\n' "$login" "$uid" "$(( 21000 + (uid % 500) * 10 ))"
done < <(getent passwd)

# Une ligne, pas dix-neuf : le compte des rejets attendus prouve que la garde a tourne, sans
# noyer le seul rejet qui meriterait qu'on le lise.
[[ "$VERBOSE" -eq 1 && "$system_n" -gt 0 ]] && \
  echo "[humans] $system_n comptes systeme ecartes (uid hors [$UID_MIN..$UID_MAX] — dont root, qui partagerait le bloc 21000 avec l'uid 1000)" >&2

exit 0
