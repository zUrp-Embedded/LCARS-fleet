#!/usr/bin/env bash
# SOURCE: deploy/modules.d/15-toolchain.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — toolchain de BUILD : Erlang/OTP par apt, Elixir par le zip officiel ÉPINGLÉ ; deux planchers
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# (CHECK-ON sans docker — délibéré, et ce n'est PAS le « 10/15 CHECK-ON » du plan ADR §11 pris au
# mot : la toolchain vit dans le STAGE BUILD de l'image, pas dans le conteneur runtime. L'état-cible
# « toolchain posée » n'a pas à être vrai là où on ne buildera jamais ; la vérité docker de ce
# module, c'est la release présente — sondée par 60-deploy check.)
#
# ⚠ ELIXIR N'ENTRE PLUS PAR APT (2026-09-06, branche passe8/elixir-1.20) — ET C'EST LE CLIQUET
# INVERSE DE CELUI DU 2026-08-28. Ce module avait quitté le précompilé pour la paire apt parce que
# la cible servait 1.18.3, le plancher du moment. La cible est LTS seulement (26.04, puis 28.04) :
# sa distro servira 1.18 jusqu'en 2028, et Elixir ne corrige que sa dernière minor. Au-delà de
# 1.18, Elixir vient donc du zip précompilé OFFICIEL de la release (un par majeure OTP), épinglé par
# version et sha256 dans la lib (PROV_ELIXIR_PIN, PROV_ELIXIR_PIN_SHA256) — le même geste que
# 16-node, le même pin que le stage build de l'image. Erlang reste celui de la distro tant que la
# fenêtre OTP d'Elixir le contient (1.20 : OTP 27-29 ; 1.21 lâchera 27 — ce jour-là erlang suivra
# le même chemin). Ce que le module retire : les arbres `/opt/elixir-*` d'une AUTRE version que
# le pin, et les liens de PROV_LINK_DIR qui pointent ailleurs que sur le pin — jamais un lien de
# l'opérateur (c'est la CIBLE du lien qui décide), jamais un paquet apt.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

otp_release() { erl -noshell -eval 'io:format("~s",[erlang:system_info(otp_release)]),halt().' 2>/dev/null || echo 0; }
elixir_version() { elixir --short-version 2>/dev/null || echo absent; }

ELIXIR_BINS=(elixir elixirc mix iex)
: "${LCARS_ELIXIR_PREFIX:=/opt/elixir-}"
ELIXIR_HOME="${LCARS_ELIXIR_HOME:-${LCARS_ELIXIR_PREFIX}${PROV_ELIXIR_PIN}}"
ELIXIR_ZIP_URL="${LCARS_ELIXIR_ZIP_URL:-https://github.com/elixir-lang/elixir/releases/download/v${PROV_ELIXIR_PIN}/elixir-otp-${PROV_ELIXIR_OTP_MAJOR}.zip}"

# elixir_version_posee -> la version de l'arbre du pin, ou rien
elixir_version_posee() {
  [[ -x "$ELIXIR_HOME/bin/elixir" ]] || return 0
  "$ELIXIR_HOME/bin/elixir" --short-version 2>/dev/null
}

# elixir_links_ours -> les symlinks <link_dir>/* qui pointent sous NOTRE préfixe (toute version)
elixir_links_ours() {
  local b t
  for b in "${ELIXIR_BINS[@]}"; do
    [[ -L "$PROV_LINK_DIR/$b" ]] || continue
    t="$(readlink -m "$PROV_LINK_DIR/$b" 2>/dev/null || true)"
    [[ "$t" == "$LCARS_ELIXIR_PREFIX"*/* ]] && printf '%s\n' "$PROV_LINK_DIR/$b"
  done
  return 0
}

# elixir_links_stale -> ceux des nôtres qui ne pointent PAS sur l'arbre du pin (autre version, ou mort)
elixir_links_stale() {
  local l t
  while IFS= read -r l; do
    t="$(readlink -m "$l" 2>/dev/null || true)"
    [[ "$t" == "$ELIXIR_HOME"/* && -e "$t" ]] || printf '%s\n' "$l"
  done < <(elixir_links_ours)
  return 0
}

# elixir_trees -> les arbres <préfixe>* (toute version)
elixir_trees() {
  local d
  # ⚠ UN GLOB QUI NE MATCHE RIEN REND SON PROPRE MOTIF. Sans le test `-d`, la boucle itérerait
  # une fois sur la chaîne littérale `/opt/elixir-*` — et le `rm -rf` de l'appelant la recevrait.
  for d in "$LCARS_ELIXIR_PREFIX"*; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done
  return 0
}

# elixir_trees_other -> les arbres d'une AUTRE version que le pin
elixir_trees_other() {
  local d
  while IFS= read -r d; do [[ "$d" == "$ELIXIR_HOME" ]] || printf '%s\n' "$d"; done < <(elixir_trees)
  return 0
}

elixir_built_for() {
  elixir --version 2>/dev/null \
    | sed -n 's/.*compiled with Erlang\/OTP \([0-9]\+\).*/\1/p' | head -1
}

# `1.20.4` >= `1.20` — majeure PUIS mineure, en numérique. ⚠ PAS DE COMPARAISON DE CHAÎNES ICI :
# « 1.9 » > « 1.18 » en lexicographique. Le patch n'entre pas dans la comparaison.
elixir_meets_floor() { # elixir_meets_floor <version lue> <plancher M.m>
  local have="$1" floor="$2" h_maj h_min f_maj f_min
  h_maj="${have%%.*}"; h_min="${have#*.}"; h_min="${h_min%%.*}"
  f_maj="${floor%%.*}"; f_min="${floor#*.}"; f_min="${f_min%%.*}"
  [[ "$h_maj" =~ ^[0-9]+$ && "$h_min" =~ ^[0-9]+$ ]] || return 1
  (( h_maj > f_maj )) && return 0
  (( h_maj == f_maj && h_min >= f_min ))
}

# ⚠ UNE LIVRAISON BINAIRE N'A PAS BESOIN DE CE MODULE, ET LA RAISON EST DANS LA RELEASE : elle est
# self-contained, ERTS bundlé. `bin/lcars_fleet` tourne sans un Erlang système, et il n'y a rien à
# compiler puisque `pack.sh` a bâti la release ET la doc. Exiger la toolchain la poserait sur des
# machines qui ne bâtissent jamais.
#
# ⚠ CE QUI RESTE VRAI DANS LES DEUX FORMES : le NETTOYAGE des reliquats. Sur une machine qui ne
# bâtit pas, TOUT arbre `/opt/elixir-*` et tout lien vers lui est un reliquat ; sur une machine qui
# bâtit, ceux d'une autre version que le pin. C'est une convergence d'ABSENCE.
rien_a_batir() { prov_delivery_is_binary; }

reliquats_liens() { if rien_a_batir; then elixir_links_ours; else elixir_links_stale; fi; }
reliquats_arbres() { if rien_a_batir; then elixir_trees; else elixir_trees_other; fi; }

check_reliquats() {
  local -a old_links old_trees
  mapfile -t old_links < <(reliquats_liens)
  mapfile -t old_trees < <(reliquats_arbres)
  if [[ "${#old_links[@]}" -gt 0 ]]; then
    p_drift "lien(s) Elixir vers un arbre qui n'est pas le pin, DEVANT apt dans le PATH : ${old_links[*]} — c'est LUI qui compile"
  fi
  if [[ "${#old_trees[@]}" -gt 0 ]]; then
    # Le drift DIT ce que converger ferait : `apply` retire ces arbres (rm -rf) une fois le pin
    # debout. Sur une machine qui garde deux versions a dessein (un poste de dev qui doit encore
    # batir une branche d'avant le bump), la convergence n'est PAS le geste voulu — et l'operateur
    # ne peut le savoir que si le drift le nomme.
    p_drift "arbre(s) Elixir d'une autre version que le pin $PROV_ELIXIR_PIN : ${old_trees[*]} — « provision apply » les RETIRE (rm -rf) une fois le pin debout"
  fi
}

check() {
  if rien_a_batir; then
    p_ok "toolchain non requise — livraison binaire, la release est bâtie et embarque son ERTS"
    check_reliquats
    verdict_check
  fi

  # Garde d'instrument : un pin sous le plancher est une erreur de configuration, pas un état.
  elixir_meets_floor "$PROV_ELIXIR_PIN" "$PROV_ELIXIR_MIN" \
    || p_fail "pin Elixir $PROV_ELIXIR_PIN SOUS le plancher $PROV_ELIXIR_MIN — les deux vivent dans provision-lib.sh, accorde-les"

  if command -v erl >/dev/null; then
    local otp; otp="$(otp_release)"
    if [[ "$otp" -ge "$PROV_ELIXIR_OTP_MAJOR" ]]; then
      p_ok "Erlang/OTP $otp (plancher $PROV_ELIXIR_OTP_MAJOR, paquet apt erlang)"
    else
      p_drift "Erlang/OTP $otp < plancher $PROV_ELIXIR_OTP_MAJOR"
    fi
  else
    p_drift "erl absent (paquet apt erlang)"
  fi

  local posee; posee="$(elixir_version_posee)"
  local ev; ev="$(elixir_version)"
  if [[ "$posee" != "$PROV_ELIXIR_PIN" ]]; then
    p_drift "Elixir $PROV_ELIXIR_PIN non posé ($ELIXIR_HOME) — l'apply le télécharge (zip officiel, sha256 épinglé)"
  elif [[ "$ev" != "$PROV_ELIXIR_PIN" ]]; then
    # ⚠ DEUX CAUSES DISTINCTES, ET LE MESSAGE DOIT DIRE LAQUELLE. « un autre elixir devant nous dans
    # le PATH » et « NOTRE lien pointe sur un autre arbre » demandent deux gestes opposés : retirer
    # ce qui masque, ou refaire le lien. Dit au hasard, l'operateur cherche du cote ou il n'y a rien
    # (mesure du 2026-09-07 sur le poste : le lien pointait sur 1.18.4, le message accusait le PATH).
    local qui; qui="$(command -v elixir 2>/dev/null || true)"
    if [[ -n "$qui" && "$qui" == "$PROV_LINK_DIR"/* ]]; then
      p_drift "Elixir $PROV_ELIXIR_PIN est posé mais « elixir » répond ${ev} — c'est NOTRE lien $qui qui pointe sur un autre arbre ($(readlink -f "$qui" 2>/dev/null || echo '?')) ; l'apply le refait pointer sur le pin"
    else
      p_drift "Elixir $PROV_ELIXIR_PIN est posé mais « elixir » répond ${ev} (${qui:-introuvable}) — un autre elixir est devant $PROV_LINK_DIR dans le PATH ; c'est LUI qui compile"
    fi
  else
    local built otp; built="$(elixir_built_for)"; otp="$(otp_release)"
    if [[ "$built" == "$otp" ]]; then
      p_ok "Elixir $ev posé ($ELIXIR_HOME), variante OTP $built (= la VM qui répond)"
    elif [[ -z "$built" ]]; then
      p_drift "Elixir $ev : variante de build illisible (« elixir --version » n'annonce plus son OTP ?)"
    else
      p_drift "Elixir $ev compilé pour OTP $built, VM OTP $otp — le zip du pin n'est pas celui de cette majeure OTP"
    fi
  fi

  check_reliquats
  verdict_check
}

apply() {
  # ⚠ LES LIENS PÉRIMÉS D'ABORD, ET L'ORDRE EST TOUT. Tant que `/usr/local/bin/elixir` pointe vers
  # un autre arbre, `elixir_version` mesure CELUI-LÀ. On rend le PATH honnête, ensuite on regarde.
  local -a old_links old_trees; local o
  mapfile -t old_links < <(reliquats_liens)
  for o in "${old_links[@]}"; do
    if rm -f "$o"; then
      p_chg "retiré : $o (lien Elixir vers un arbre qui n'est pas le pin)"
    else
      p_fail "rm $o"; verdict_apply
    fi
  done

  # ⚠ LE NETTOYAGE CI-DESSUS EST PASSÉ DANS LES DEUX FORMES, LA POSE NON. Sur une livraison binaire
  # il n'y a rien à compiler : poser erlang et elixir y serait poser un outil de build sur une
  # machine qui ne bâtit pas.
  if rien_a_batir; then
    mapfile -t old_trees < <(reliquats_arbres)
    for o in "${old_trees[@]}"; do
      if rm -rf "$o"; then p_chg "retiré : $o (arbre Elixir sur une machine qui ne bâtit pas)"; else p_fail "rm -rf $o"; verdict_apply; fi
    done
    p_ok "erlang et elixir non posés — livraison binaire, rien à bâtir ici"
    p_ok "plancher OTP/Elixir non vérifié — la release embarque son ERTS, rien ne compile ici"
    verdict_apply
  fi

  elixir_meets_floor "$PROV_ELIXIR_PIN" "$PROV_ELIXIR_MIN" \
    || { p_fail "pin Elixir $PROV_ELIXIR_PIN SOUS le plancher $PROV_ELIXIR_MIN — les deux vivent dans provision-lib.sh, accorde-les"; verdict_apply; }

  # Erlang : la distro, tant que sa majeure est dans la fenêtre du pin.
  if ! command -v erl >/dev/null || [[ "$(otp_release)" -lt "$PROV_ELIXIR_OTP_MAJOR" ]]; then
    apt_ensure erlang || verdict_apply
  else
    # ⚠ LE CAS OÙ L'ON NE FAIT RIEN LAISSE QUAND MÊME UNE TRACE : trouvé, pas posé — le journal le distingue.
    prov_journal_note apt_already erlang
    p_ok "Erlang/OTP déjà au plancher — trouvé, pas posé"
  fi

  # Elixir : le zip officiel du pin, vérifié, sous /opt/elixir-<pin>, quatre liens dans PROV_LINK_DIR.
  if [[ "$(elixir_version_posee)" == "$PROV_ELIXIR_PIN" ]]; then
    p_ok "Elixir $PROV_ELIXIR_PIN déjà posé ($ELIXIR_HOME)"
  else
    # Le zip est posé à côté de l'arbre (le parent du préfixe : /opt), jamais dans /tmp — et c'est
    # ce parent que les témoins déplacent, avec LCARS_ELIXIR_PREFIX.
    local parent zip; parent="$(dirname "$ELIXIR_HOME")"; zip="$parent/.elixir-${PROV_ELIXIR_PIN}.zip"
    ensure_dir "$parent" 0755 root:root || verdict_apply
    fetch_verify "$ELIXIR_ZIP_URL" "$PROV_ELIXIR_PIN_SHA256" "$zip" 0644 || verdict_apply
    # Un crash au milieu ne laisse jamais un ELIXIR_HOME à moitié écrit qui répondrait à --short-version.
    rm -rf "${ELIXIR_HOME}.partial"
    prov_scaffold_dir "${ELIXIR_HOME}.partial" 0755 root:root || verdict_apply   # hors journal (M8)
    p_step "Elixir $PROV_ELIXIR_PIN — décompression du précompilé officiel (OTP $PROV_ELIXIR_OTP_MAJOR)"
    if ! run_quiet unzip -q "$zip" -d "${ELIXIR_HOME}.partial"; then
      rm -rf "${ELIXIR_HOME}.partial" "$zip"; p_fail "extraction du précompilé Elixir"; verdict_apply
    fi
    prov_promote_dir "${ELIXIR_HOME}.partial" "$ELIXIR_HOME" || verdict_apply   # journalise le nom FINAL
    rm -f "$zip"
  fi
  local b
  for b in "${ELIXIR_BINS[@]}"; do
    ensure_symlink "$PROV_LINK_DIR/$b" "$ELIXIR_HOME/bin/$b" || verdict_apply
  done

  # ⚠ LES AUTRES ARBRES APRÈS LE PIN, ET POUR LA RAISON INVERSE : on ne détruit l'ancien qu'une fois
  # le nouveau debout.
  mapfile -t old_trees < <(elixir_trees_other)
  for o in "${old_trees[@]}"; do
    if rm -rf "$o"; then
      p_chg "retiré : $o (arbre Elixir d'une autre version que le pin $PROV_ELIXIR_PIN)"
    else
      p_fail "rm -rf $o"; verdict_apply
    fi
  done

  local otp ev built; otp="$(otp_release)"; ev="$(elixir_version)"
  if [[ "$otp" -lt "$PROV_ELIXIR_OTP_MAJOR" ]]; then
    p_fail "Erlang/OTP « $otp » toujours sous le plancher $PROV_ELIXIR_OTP_MAJOR après apt (distro trop vieille ?)"
  elif [[ "$ev" != "$PROV_ELIXIR_PIN" ]]; then
    p_fail "« elixir » répond « $ev » après pose ≠ pin $PROV_ELIXIR_PIN (PATH parasite ? un elixir d'apt ou d'ailleurs devant $PROV_LINK_DIR : $(command -v elixir 2>/dev/null || echo 'introuvable'))"
  else
    built="$(elixir_built_for)"
    if [[ -n "$built" && "$built" != "$otp" ]]; then
      p_fail "Elixir $ev compilé pour OTP $built, VM OTP $otp — le zip du pin n'est pas celui de cette majeure OTP"
    else
      p_ok "Erlang/OTP $otp, Elixir $ev ($ELIXIR_HOME ; planchers $PROV_ELIXIR_OTP_MAJOR / $PROV_ELIXIR_MIN)"
    fi
  fi
  verdict_apply
}

case "${1:?usage: 15-toolchain.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
