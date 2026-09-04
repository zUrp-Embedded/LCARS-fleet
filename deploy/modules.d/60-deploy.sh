#!/usr/bin/env bash
# SOURCE: deploy/modules.d/60-deploy.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — deploy du runtime : orchestre deploy/lib/deploy-release.sh (l'autorité build+pose) puis verrouille RO
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
# AFTER: 15-toolchain

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

RUNTIME_DIR="$(repo_root)/fleet"
MANIFEST="$RUNTIME_DIR/etc/release.manifest"
mf_entries() { # « <nom> <exec|noexec> <link:0|1> » par entrée, commentaires/vides sautés
  awk 'NF && $1 !~ /^#/ { print $1, $2, ($3 == "link" ? 1 : 0) }' "$MANIFEST"
}

release_present() { [[ -x "$PREFIX_REL/bin/lcars_fleet" ]]; }
PREFIX_REL="$PROV_PREFIX/rel/lcars_fleet"

build_sha() {
  local matches=("$PREFIX_REL"/lib/lcars_fleet-*/priv/api/build_info.txt)
  [[ -f "${matches[0]}" ]] || return 0
  sed -n 's/^sha=//p' "${matches[0]}" 2>/dev/null | head -1 || true
}

check() {
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_check; }

  # ⚠ « ABSENTE » SE DIT D'UN PREFIXE QU'ON PEUT TRAVERSER. `$PROV_PREFIX` est `0750 root:fleet` :
  # un compte hors du groupe — ou dont l'adhesion n'est pas encore effective dans SA session — lit
  # « absente » de tout ce qui s'y trouve, y compris d'une release parfaitement posee.
  #
  # MESURE DU 2026-09-01, banc 2007 : ce drift apparaissait SANS sudo et disparaissait AVEC, sur la
  # meme machine et a la meme seconde. Le banc 2001 ne le montrait pas — le groupe y etait deja
  # effectif. C'est la session FRAICHE qui est le cas juste, pas l'inverse.
  local _pfx; _pfx="$(prov_file_state "$PROV_PREFIX")"
  if release_present; then
    p_ok "release posée ($PROV_PREFIX, build $(build_sha))"
  elif [[ "$_pfx" != "present" && "$_pfx" != "absent" ]]; then
    p_warn "release NON MESURABLE — $PROV_PREFIX $(prov_state_why "$_pfx" "$PROV_PREFIX")"
    verdict_check
  else
    p_drift "release absente sous $PROV_PREFIX"
    verdict_check   # sans release, sonder perms/liens n'apporte que du bruit
  fi

  local cur
  cur="$(stat -c '%U:%G %a' "$PROV_PREFIX")"
  if [[ "$cur" == "root:$PROV_FLEET_GROUP 750" ]]; then
    p_ok "verrou RO du prefix ($cur)"
  else
    p_drift "prefix non verrouillé : $cur ≠ root:$PROV_FLEET_GROUP 750"
  fi

  local name mode is_link
  while read -r name mode is_link; do
    if [[ "$mode" == "exec" && ! -x "$PROV_PREFIX/bin/$name" ]]; then
      p_drift "bin/$name absent/non exécutable sous $PROV_PREFIX/bin"
    elif [[ "$mode" == "noexec" && ! -r "$PROV_PREFIX/bin/$name" ]]; then
      # ⚠ « absent/illisible » MELANGEAIT DEUX ETATS SOUS UNE BARRE OBLIQUE, et ils n'appellent pas
      # le meme verdict : l'apply POSE un binaire absent, il ne peut rien faire d'un binaire present
      # que ce compte n'a pas le droit d'ouvrir. Le prefixe est en 0750 root:fleet — un doctor lance
      # par un compte hors du groupe lit donc « absent » de tout ce qui est parfaitement la.
      case "$(prov_file_state "$PROV_PREFIX/bin/$name")" in
        absent) p_drift "bin/$name ABSENT sous $PROV_PREFIX/bin — l'apply le pose" ;;
        *)      p_warn  "bin/$name $(prov_state_why "$(prov_file_state "$PROV_PREFIX/bin/$name")" "$PROV_PREFIX/bin/$name")" ;;
      esac
    else
      p_ok "bin/$name"
    fi
    if [[ "$is_link" -eq 1 ]]; then
      if [[ "$(readlink "$PROV_LINK_DIR/$name" 2>/dev/null)" == "$PROV_PREFIX/bin/$name" ]]; then
        p_ok "symlink $PROV_LINK_DIR/$name"
      else
        p_drift "$PROV_LINK_DIR/$name ≠ symlink vers $PROV_PREFIX/bin/$name"
      fi
    else
      [[ -f "$PROV_LINK_DIR/$name" ]] && p_warn "copie morte $PROV_LINK_DIR/$name (invention D3, plus aucun lecteur) — nettoyage manuel : sudo rm $PROV_LINK_DIR/$name"
    fi
  done < <(mf_entries)
  verdict_check
}

apply() {
  # ─── LE REJEU DEPUIS LA COPIE N'A NI SOURCE NI RIEN A BATIR ───────────────────────────────────
  #
  # ⚠ ET CE N'EST PAS LA LIVRAISON QUI DECIDE ICI, C'EST L'EMPLACEMENT — les deux questions sont
  # distinctes, et confondre l'une avec l'autre a laisse ce module echouer sur les deux rails.
  # Le bloc `mix` ci-dessous lit la LIVRAISON ; celui-ci demande « suis-je dans l'arbre de travail,
  # ou dans la copie que le rail a lui-meme posee ? ».
  #
  # MESURE DU 2026-09-02, BANCS 2006 ET 2007 : un apply rejoue depuis
  # `/opt/lcars/deploy/provision` — LE GESTE NOMINAL DU CONVERGEUR — rend « FAIL 60-deploy:
  # source runtime introuvable: /opt/lcars/fleet ». Sur les DEUX, en livraison binaire comme en
  # livraison source. C'est vrai, et ce n'est pas un defaut : `62-runtime-helpers` embarque
  # `fleet/{deploy,etc,services,bin}`, jamais `mix.exs`. Il n'y a pas de source la, et il n'en faut
  # pas — la release est POSEE.
  #
  # La copie sert a REJOUER le rail, pas a le RECONSTRUIRE. Le module n'a donc rien a faire, et le
  # dire est son etat-cible : echouer ici faisait rater tout le rejeu sur une machine convergee.
  if prov_dans_la_copie && [[ ! -f "$RUNTIME_DIR/mix.exs" ]] && release_present; then
    p_ok "rejeu depuis la copie posée : release en place, aucune source ici ($RUNTIME_DIR) — rien à bâtir"
    verdict_apply
  fi
  [[ -f "$RUNTIME_DIR/mix.exs" ]] || { p_fail "source runtime introuvable: $RUNTIME_DIR"; verdict_apply; }
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_apply; }
  # ⚠ `mix` N'EST EXIGE QUE SI L'ON BATIT, et ce module ne bâtit pas toujours. En livraison BINAIRE
  # la release arrive faite : `deploy-release.sh` la voit et ne compile pas — c'est tout l'objet du
  # discriminant. Exiger `mix` avant de le lire renvoyait vers `15-toolchain`, dont l'etat-cible en
  # binaire est justement de ne rien poser : le rail s'envoyait une instruction impossible.
  #
  # MESURE DU 2026-09-01, premiere install binaire reelle (banc 2006) : `FAIL 60-deploy: mix absent
  # — lance d'abord 15-toolchain`, sur une machine ou la release etait deja dans le paquet.
  if ! prov_delivery_is_binary; then
    command -v mix >/dev/null || { p_fail "mix absent — lance d'abord 15-toolchain"; verdict_apply; }
  fi
  id "$PROV_HUMAN" >/dev/null 2>&1 || { p_fail "humain-bâtisseur inconnu: $PROV_HUMAN"; verdict_apply; }

  local src_sha deployed_sha
  # B2 : --short NU des deux côtés — le build embarque le short par défaut de git (abbrev auto,
  # 9 hex sur ce repo) ; un --short=8 côté module ne matchait jamais → rebuild à chaque apply.
  src_sha="$(git -C "$(repo_root)" rev-parse --short HEAD 2>/dev/null || true)"
  deployed_sha="$(build_sha)"
  if [[ -n "$src_sha" && "$src_sha" == "$deployed_sha" ]] \
      && git -C "$(repo_root)" diff --quiet HEAD -- fleet 2>/dev/null && release_present; then
    p_ok "build déployé $deployed_sha == HEAD source (fleet propre) — rien à bâtir"
    local name _mode is_link
    while read -r name _mode is_link; do
      [[ "$is_link" -eq 1 ]] || continue
      ensure_symlink "$PROV_LINK_DIR/$name" "$PROV_PREFIX/bin/$name" || verdict_apply
    done < <(mf_entries)
    verdict_apply
  fi

  if pgrep -f "$PREFIX_REL" >/dev/null 2>&1; then
    p_warn "une fleet tourne depuis $PROV_PREFIX — le swap est sûr, mais « fleet_v2 stop && fleet_v2 start » pour prendre le nouveau build"
  fi

  ensure_dir "$PROV_PREFIX" 0750 "$PROV_HUMAN:$PROV_FLEET_GROUP" || verdict_apply
  chown -R "$PROV_HUMAN:$PROV_FLEET_GROUP" "$PROV_PREFIX" || { p_fail "déverrouillage du prefix"; verdict_apply; }

  # ⚖ user 2026-09-04 (DI-07, defaut pris) : L'INSTALL NE RE-ATTESTE PAS LA SOURCE. `deploy-release.sh`
  # jouait `mix gate` avant de batir, et le gate exigeait sur la CIBLE toute une chaine d'outillage
  # de test — pytest, bats, procps, shellcheck, ruff, et le binaire vendor `claude` du siege pour
  # 67 temoins du spawner. Deux jours de banc perdus le 04/09 sur des outils absents d'un poste
  # neuf, pour attester une source que la CI et `pack.sh` attestent deja. Ce module COMPILE et
  # POSE ; l'attestation vient d'ailleurs, et `deploy-release.sh` le dit (« gate saute »).

  # ⚠ L'OUTILLAGE `mix` NE SERT QU'AU BUILD, et en livraison binaire il n'y a pas de build. Le
  # raisonnement est déjà écrit trois lignes plus haut pour les paquets du gate — « un besoin qui
  # n'existe qu'ici, à la minute du build » — et il vaut a fortiori pour `hex` et `rebar` : la
  # release est faite, `deploy-release.sh` la voit et ne compile pas.
  #
  # MESURE DU 2026-09-01, banc 2006 : `FAIL 60-deploy: commande en échec (rc=127) : … mix
  # local.hex` — `mix` n'existe pas sur une cible binaire, c'est le geste R5 qui le veut. Le module
  # mourait ici, donc `deploy-release.sh` n'était jamais appelé, donc la release du PAQUET n'était
  # jamais posée. Un paquet complet, refusé par un outil de compilation absent.
  #
  # ⚠ LES TROIS PAQUETS DU GATE RESTENT, eux. Le commentaire ci-dessus les dit « pas de runtime »,
  # mais il ajoute que « plusieurs sondes lisent `pgrep` (procps) » — deux affirmations qui ne
  # tiennent pas ensemble. Tant que la seconde n'est pas mesurée, les retirer serait parier sur la
  # première ; ils sont légers, et un doute non mesuré ne se tranche pas dans un geste de passage.
  if prov_delivery_is_binary; then
    p_ok "outillage mix non posé — livraison binaire, la release est déjà bâtie"
  else
    p_step "outillage mix (hex + rebar) pour $PROV_HUMAN"
    run_quiet as_human env -C "$RUNTIME_DIR" mix local.hex --force  || verdict_apply
    run_quiet as_human env -C "$RUNTIME_DIR" mix local.rebar --force || verdict_apply

  fi

  # Q3 (2026-09-04) : le script est de l'installeur, il vit a cote de la lib ; l'arbre source du
  # runtime lui est DONNE, il ne le devine plus a sa position.
  run_step --ok 3 "build de la release" -- \
    as_human env LCARS_INSTALL_PREFIX="$PROV_PREFIX" LCARS_INSTALL_LINK_DIR="$PROV_LINK_DIR" LCARS_RUNTIME_DIR="$RUNTIME_DIR" \
      LCARS_INSTALL_SKIP_GATE=1 bash "$(dirname "$PROVISION_LIB")/deploy-release.sh"
  local install_rc="$PROV_LAST_RC"
  if [[ "$install_rc" -ne 0 && "$install_rc" -ne 3 ]]; then
    p_fail "deploy-release.sh en échec (rc=$install_rc — verrou contracts rouge ? warnings-as-errors ?) — le prefix reste déverrouillé pour inspection"
    verdict_apply
  fi
  release_present || { p_fail "install.sh vert mais release absente ($PREFIX_REL) — incohérence, inspecte"; verdict_apply; }

  chown -R "root:$PROV_FLEET_GROUP" "$PROV_PREFIX" || { p_fail "re-verrouillage chown"; verdict_apply; }
  chmod -R u=rwX,g=rX,o= "$PROV_PREFIX"            || { p_fail "re-verrouillage chmod"; verdict_apply; }

  local name _mode is_link
  while read -r name _mode is_link; do
    [[ "$is_link" -eq 1 ]] || continue
    ensure_symlink "$PROV_LINK_DIR/$name" "$PROV_PREFIX/bin/$name" || verdict_apply
  done < <(mf_entries)

  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "runtime déployé : $PROV_PREFIX (build $(build_sha)) + /usr/local/bin câblé"
  verdict_apply
}

case "${1:?usage: 60-deploy.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
