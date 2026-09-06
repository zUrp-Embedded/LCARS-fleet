#!/usr/bin/env bash
# SOURCE: deploy/modules.d/15-toolchain.sh
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

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

otp_release() { erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo 0; }
elixir_version() { elixir --short-version 2>/dev/null || echo absent; }

LEGACY_ELIXIR_BINS=(elixir elixirc mix iex)
: "${LCARS_LEGACY_ELIXIR_PREFIX:=/opt/elixir-}"

legacy_elixir_links() { # -> les symlinks <link_dir>/* qui pointent vers NOTRE ancien arbre
  local b t
  for b in "${LEGACY_ELIXIR_BINS[@]}"; do
    [[ -L "$PROV_LINK_DIR/$b" ]] || continue
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

# ⚠ UNE LIVRAISON BINAIRE N'A PAS BESOIN DE CE MODULE, ET LA RAISON EST DANS LA RELEASE : elle est
# self-contained, ERTS bundlé. `bin/lcars_fleet` tourne sans un Erlang systeme, et il n'y a rien a
# compiler puisque `pack.sh` a bati la release ET la doc. Exiger la toolchain la posait donc sur des
# machines qui ne bâtissent jamais — 400 Mo de compilateurs pour un conteneur de prod, et une surface
# d'attaque qui n'a aucune contrepartie.
#
# ⚠ CE QUI RESTE VRAI DANS LES DEUX FORMES : le NETTOYAGE des reliquats du precompile d'avant. Un
# `/usr/local/bin/elixir` qui masque apt est un dechet quelle que soit la livraison — c'est une
# convergence d'ABSENCE, elle ne depend pas de ce qu'on a a batir.
rien_a_batir() { prov_delivery_is_binary; }

check() {
  if rien_a_batir; then
    p_ok "toolchain non requise — livraison binaire, la release est bâtie et embarque son ERTS"
    check_reliquats
    verdict_check
  fi

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

  check_reliquats
  verdict_check
}

check_reliquats() {
  local -a old_links old_trees
  mapfile -t old_links < <(legacy_elixir_links)
  mapfile -t old_trees < <(legacy_elixir_trees)
  if [[ "${#old_links[@]}" -gt 0 ]]; then
    p_drift "precompile Elixir d'avant, TOUJOURS DEVANT apt dans le PATH : ${old_links[*]} — c'est LUI qui compile"
  fi
  if [[ "${#old_trees[@]}" -gt 0 ]]; then
    p_drift "arbre(s) du precompile Elixir d'avant, que plus rien ne nomme : ${old_trees[*]}"
  fi
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

  # ⚠ LE NETTOYAGE CI-DESSUS EST PASSE DANS LES DEUX FORMES, LA POSE NON. Sur une livraison binaire
  # il n'y a rien a compiler : poser erlang et elixir y serait poser un outil de build sur une
  # machine qui ne bâtit pas — la moitie d'une forme, exactement ce que la doctrine des deux
  # livraisons entieres interdit.
  if rien_a_batir; then
    p_ok "erlang et elixir non posés — livraison binaire, rien à bâtir ici"
  elif [[ "$(otp_release)" -lt "$PROV_ELIXIR_OTP_MAJOR" ]] \
     || ! elixir_meets_floor "$(elixir_version)" "$PROV_ELIXIR_MIN"; then
    apt_ensure erlang elixir || verdict_apply
  else
    # ⚠ LE CAS OU L'ON NE FAIT RIEN LAISSE QUAND MEME UNE TRACE. Machine deja au seuil : `apt_ensure`
    # n'est pas appelee, donc NI `apt_installed` NI `apt_already` n'entrent au journal — et rien ne
    # distingue plus « LCARS les a poses » de « ils etaient la avant nous ». C'est exactement la
    # question a laquelle le journal existe pour repondre, laissee sans reponse par la branche qui
    # n'agit pas. `apt_already` est le bon mot : trouves, donc jamais repris.
    prov_journal_note apt_already erlang elixir
    p_ok "Erlang/OTP et Elixir déjà au plancher — trouvés, donc jamais repris par « uninstall »"
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

  # ⚠ LA VERIFICATION DU PLANCHER SUIT LA POSE, ET ELLE N'A DE SENS QUE SI ON A POSE. En livraison
  # binaire on vient d'annoncer « erlang et elixir non poses, rien a batir ici » — puis ce bloc
  # exigeait OTP >= 27 et rendait `p_fail "Erlang/OTP « 0 » toujours sous le plancher"`. Le module
  # se contredisait en trois lignes, et l'apply mourait sur une machine dont l'etat etait
  # exactement celui qu'il venait de declarer correct.
  #
  # VU sur une premiere install binaire, sans erlang : `OK` puis
  # `FAIL` puis `ERREUR ... apply en echec (rc=1)`. La release embarque son ERTS : le plancher OTP
  # de la MACHINE ne decide de rien quand personne ne compile dessus.
  if rien_a_batir; then
    p_ok "plancher OTP/Elixir non vérifié — la release embarque son ERTS, rien ne compile ici"
    verdict_apply
  fi

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
