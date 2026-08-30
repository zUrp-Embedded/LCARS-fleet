#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/15-toolchain.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — toolchain de BUILD : Erlang/OTP + Elixir, tous deux par apt, deux PLANCHERS
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# (CHECK-ON sans docker — délibéré, et ce n'est PAS le « 10/15 CHECK-ON » du plan ADR §11 pris au
# mot : la toolchain vit dans le STAGE BUILD de l'image, pas dans le conteneur runtime. L'état-cible
# « toolchain posée » n'a pas à être vrai là où on ne buildera jamais ; la vérité docker de ce
# module, c'est la release présente — sondée par 60-deploy check.)
# DEUX PLANCHERS, DEUX HORLOGES, UN SEUL MÉCANISME :
#   - Erlang/OTP : `>= PROV_ELIXIR_OTP_MAJOR`. On ne fige pas ce qu'on ne contrôle pas — le gate CI
#     verrouille la compatibilité réelle.
#   - Elixir     : `>= PROV_ELIXIR_MIN` (majeure.mineure). Le patch ne se compare pas : la distro
#     le bouge sous nous, et c'est exactement le service qu'on lui demande.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

otp_release() { erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo 0; }
elixir_version() { elixir --short-version 2>/dev/null || echo absent; }

# ⚠ RETIRER UNE LIGNE DE LA TABLE N'A JAMAIS RETIRE UN OBJET D'UNE MACHINE. `/opt/elixir-<version>`
# et ses quatre symlinks ont quitte `system.manifest` en meme temps que ce module a cesse de les
# poser — sur une machine NEUVE, c'est exact et complet. La ou l'ancien mecanisme a tourne, ils sont
# toujours la, et plus rien ne les nomme : `provision uninstall` ne les emporterait pas, et personne
# ne saurait dire d'ou ils viennent.
LEGACY_ELIXIR_BINS=(elixir elixirc mix iex)
# ⚠ LA COUTURE EST LE CHEMIN, PAS LA VALEUR — ET SANS ELLE CE GESTE SERAIT INTESTABLE. Un temoin ne
# peut pas monter un faux `/opt/elixir-1.18.4` sur la machine qui le joue ; sans surcharge il
# mesurerait le poste, et le seul geste DESTRUCTIF de ce module resterait sans mur. `PROV_LINK_DIR`
# existe deja dans la lib (c'est la meme SSoT que les symlinks PATH d'`install.sh`) ; le prefixe des
# arbres, lui, n'etait nomme nulle part — il l'est ici, et une seule fois.
: "${LCARS_LEGACY_ELIXIR_PREFIX:=/opt/elixir-}"

# ⚠ ON NE DETRUIT QUE CE QU'ON A POSE. Un `rm` sur `<link_dir>/elixir` sans regarder OU il pointe
# emporterait l'elixir qu'un operateur y a mis lui-meme — le geste exact que le rang 4 du chantier
# empreinte interdit. La CIBLE fait foi, pas le nom du lien : sous le prefixe, c'est le notre.
legacy_elixir_links() { # -> les symlinks <link_dir>/* qui pointent vers NOTRE ancien arbre
  local b t
  for b in "${LEGACY_ELIXIR_BINS[@]}"; do
    [[ -L "$PROV_LINK_DIR/$b" ]] || continue
    # ⚠ `readlink -f` RESOUT, donc il rend la chaine VIDE sur un lien casse — et un lien casse vers
    # notre arbre est precisement ce qu'un `rm -rf` interrompu laisse derriere. On lit d'abord la
    # cible BRUTE (`-m` ne touche pas au disque), et le lien mort reste reconnaissable.
    t="$(readlink -m "$PROV_LINK_DIR/$b" 2>/dev/null || true)"
    [[ "$t" == "$LCARS_LEGACY_ELIXIR_PREFIX"*/* ]] && printf '%s\n' "$PROV_LINK_DIR/$b"
  done
  return 0
}

legacy_elixir_trees() { # -> les arbres <prefixe>* poses par l'ancien mecanisme
  local d
  # ⚠ UN GLOB QUI NE MATCHE RIEN RENDS SON PROPRE MOTIF. Sans le test `-d`, la boucle itererait
  # une fois sur la chaine litterale `/opt/elixir-*` — et le `rm -rf` de l'appelant la recevrait.
  for d in "$LCARS_LEGACY_ELIXIR_PREFIX"*; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done
  return 0
}

# La VARIANTE de build, pas la version : `elixir --version` dit « Elixir 1.18.3 (compiled with
# Erlang/OTP 27) ». `--short-version` jette cette moitie-la, et c'est la moitie qui a manque le
# 2026-08-22 — un poste en OTP 27 portant la variante OTP 25, sonde au VERT parce que « 1.18.4 »
# == « 1.18.4 ». Le zip est parti ; la sonde reste, parce qu'un elixir d'AILLEURS devant `/usr/bin`
# dans le PATH rouvre exactement le meme ecart, et lui ne se retire pas par apt.
elixir_built_for() {
  elixir --version 2>/dev/null \
    | sed -n 's/.*compiled with Erlang\/OTP \([0-9]\+\).*/\1/p' | head -1
}

# `1.18.3` >= `1.18` — majeure PUIS mineure, en numerique. ⚠ PAS DE COMPARAISON DE CHAINES ICI :
# « 1.9 » > « 1.18 » en lexicographique, et ce plancher-la laisserait passer une distro d'avant le
# requirement de `mix.exs`. Le patch n'entre pas dans la comparaison — c'est la distro qui le tient.
elixir_meets_floor() { # elixir_meets_floor <version lue> <plancher M.m>
  local have="$1" floor="$2" h_maj h_min f_maj f_min
  h_maj="${have%%.*}"; h_min="${have#*.}"; h_min="${h_min%%.*}"
  f_maj="${floor%%.*}"; f_min="${floor#*.}"; f_min="${f_min%%.*}"
  [[ "$h_maj" =~ ^[0-9]+$ && "$h_min" =~ ^[0-9]+$ ]] || return 1
  (( h_maj > f_maj )) && return 0
  (( h_maj == f_maj && h_min >= f_min ))
}

check() {
  if command -v erl >/dev/null; then
    local otp; otp="$(otp_release)"
    if [[ "$otp" -ge "$PROV_ELIXIR_OTP_MAJOR" ]]; then
      p_ok "Erlang/OTP $otp (plancher $PROV_ELIXIR_OTP_MAJOR)"
    else
      p_drift "Erlang/OTP $otp < plancher $PROV_ELIXIR_OTP_MAJOR"
    fi
  else
    p_drift "erl absent (paquet apt erlang)"
  fi

  local ev; ev="$(elixir_version)"
  if [[ "$ev" == absent ]]; then
    p_drift "elixir absent (paquet apt elixir)"
  elif ! elixir_meets_floor "$ev" "$PROV_ELIXIR_MIN"; then
    p_drift "Elixir $ev < plancher $PROV_ELIXIR_MIN (distro trop vieille, ou binaire d'ailleurs devant apt)"
  else
    local built otp; built="$(elixir_built_for)"; otp="$(otp_release)"
    if [[ "$built" == "$otp" ]]; then
      p_ok "Elixir $ev, variante OTP $built (= la VM qui repond)"
    elif [[ -z "$built" ]]; then
      p_drift "Elixir $ev : variante de build illisible (« elixir --version » n'annonce plus son OTP ?)"
    else
      p_drift "Elixir $ev compile pour OTP $built, VM OTP $otp — un elixir d'ailleurs est devant apt dans le PATH ($(command -v elixir))"
    fi
  fi

  local -a old_links old_trees
  mapfile -t old_links < <(legacy_elixir_links)
  mapfile -t old_trees < <(legacy_elixir_trees)
  if [[ "${#old_links[@]}" -gt 0 ]]; then
    p_drift "precompile Elixir d'avant, TOUJOURS DEVANT apt dans le PATH : ${old_links[*]} — c'est LUI qui compile"
  fi
  if [[ "${#old_trees[@]}" -gt 0 ]]; then
    p_drift "arbre(s) du precompile Elixir d'avant, que plus rien ne nomme : ${old_trees[*]}"
  fi
  verdict_check
}

apply() {
  # ⚠ LES SYMLINKS D'ABORD, ET L'ORDRE EST TOUT. Tant que `/usr/local/bin/elixir` pointe vers
  # l'ancien precompile, `elixir_version` mesure CELUI-LA : le plancher serait declare tenu par un
  # binaire qu'on est en train de retirer, et la condition d'apt ci-dessous se prononcerait sur une
  # machine qui n'existe deja plus. On rend le PATH honnete, ensuite on regarde.
  local -a old_links old_trees; local o
  mapfile -t old_links < <(legacy_elixir_links)
  for o in "${old_links[@]}"; do
    if rm -f "$o"; then
      p_chg "retire : $o (symlink vers le precompile d'avant, il masquait apt)"
    else
      p_fail "rm $o"; verdict_apply
    fi
  done

  # UN SEUL GESTE POUR LES DEUX. Le meta-paquet `erlang` tire toutes les applications OTP dont
  # `mix release` a besoin ; `elixir` depend de lui et se compile contre le meme. Les demander
  # ensemble laisse apt resoudre la paire, au lieu de la composer nous-memes en deux passes.
  if [[ "$(otp_release)" -lt "$PROV_ELIXIR_OTP_MAJOR" ]] \
     || ! elixir_meets_floor "$(elixir_version)" "$PROV_ELIXIR_MIN"; then
    apt_ensure erlang elixir || verdict_apply
  fi

  # ⚠ L'ARBRE APRES LE PAQUET, ET POUR LA RAISON INVERSE. Retirer 6 148 fichiers avant de savoir si
  # apt sait servir la paire laisserait une machine SANS elixir du tout si le depot est ferme. On ne
  # detruit l'ancien qu'une fois le nouveau debout.
  if [[ "$(elixir_version)" != absent ]]; then
    mapfile -t old_trees < <(legacy_elixir_trees)
    for o in "${old_trees[@]}"; do
      if rm -rf "$o"; then
        p_chg "retire : $o (precompile d'avant, remplace par le paquet apt)"
      else
        p_fail "rm -rf $o"; verdict_apply
      fi
    done
  fi

  # LE VERDICT EST CE QUI REPOND, PAS CE QU'APT ANNONCE. Un plancher tenu par un paquet qu'un
  # binaire du PATH masque n'est pas tenu ; c'est la sonde qui tranche, apres la pose.
  local otp ev built; otp="$(otp_release)"; ev="$(elixir_version)"
  if [[ "$otp" -lt "$PROV_ELIXIR_OTP_MAJOR" ]]; then
    p_fail "Erlang/OTP « $otp » toujours sous le plancher $PROV_ELIXIR_OTP_MAJOR apres apt (distro trop vieille ?)"
  elif [[ "$ev" == absent ]]; then
    p_fail "elixir toujours absent apres apt"
  elif ! elixir_meets_floor "$ev" "$PROV_ELIXIR_MIN"; then
    p_fail "Elixir « $ev » toujours sous le plancher $PROV_ELIXIR_MIN apres apt (distro trop vieille ?)"
  else
    built="$(elixir_built_for)"
    if [[ -n "$built" && "$built" != "$otp" ]]; then
      p_fail "Elixir $ev compile pour OTP $built, VM OTP $otp — un elixir d'ailleurs est devant apt dans le PATH ($(command -v elixir))"
    else
      p_ok "Erlang/OTP $otp, Elixir $ev (planchers $PROV_ELIXIR_OTP_MAJOR / $PROV_ELIXIR_MIN)"
    fi
  fi
  verdict_apply
}

case "${1:?usage: 15-toolchain.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
