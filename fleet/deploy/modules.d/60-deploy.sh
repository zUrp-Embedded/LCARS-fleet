#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/60-deploy.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — deploy du runtime : orchestre etc/install.sh (l'autorité build+pose) puis verrouille RO
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
# (CHECK-ON any : en docker le déploiement est fait par le stage build de l'image, mais le verrou
# RO, la release présente et le câblage bin sont l'état-cible PARTOUT — le doctor conteneur qui ne
# les sondait pas était muet sur les faits les plus pertinents du substrat.)
#
# Ce module N'INVENTE PAS le déploiement : fleet/etc/install.sh est l'autorité (modèle
# 3 zones SOURCE→INSTALL→STATE, release self-contained, idempotent). Ici, on mécanise la carte de
# déploiement AUTOUR de lui — les gestes qui étaient à la main :
#   1. dévérouiller $PREFIX pour l'humain-bâtisseur (install.sh tourne SANS sudo, la carte l'exige :
#      un build root polluerait le _build du checkout de l'humain) ;
#   2. hex/rebar locaux de l'humain (mix release en a besoin, le gate CI fait pareil) ;
#   3. etc/install.sh (build + pose + template env) — LONG (mix release) ;
#   4. re-VERROUILLER : root:fleet, u=rwX,g=rX,o= (personne ne modifie un runtime déployé) ;
#   5. câbler /usr/local/bin : les 2 symlinks-pointeurs fleet_v2+lcars, RIEN d'autre (D3 : la
#      copie des 3 launchers pod était une invention — fleet_v2 pose LCARS_*_LAUNCH_PATH sur
#      $PREFIX/bin (fleet_v2:137-139), le sandbox les voit par le mount système RO de
#      $PREFIX/bin ; la copie était une seconde vérité qui faisait mentir le doctor).
# En Docker, tout ceci est un LAYER du stage runtime (docker/Dockerfile) — même install.sh,
# même verrouillage, vérifié par le même doctor sur place (CHECK-ON: any).

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

RUNTIME_DIR="$(repo_root)/fleet"
# Le manifeste qu'install.sh consomme — le doctor est aussi aveugle au contenu que l'installeur :
# ajouter/retirer un fichier livré se fait DANS etc/install.manifest, jamais ici.
MANIFEST="$RUNTIME_DIR/etc/install.manifest"
mf_entries() { # « <nom> <exec|noexec> <link:0|1> » par entrée, commentaires/vides sautés
  awk 'NF && $1 !~ /^#/ { print $1, $2, ($3 == "link" ? 1 : 0) }' "$MANIFEST"
}

release_present() { [[ -x "$PREFIX_REL/bin/lcars_fleet" ]]; }
PREFIX_REL="$PROV_PREFIX/rel/lcars_fleet"

# B2 : le vrai chemin est DANS la release (idiome fleet_v2:316 — lib/lcars_fleet-*/priv/api/),
# et machine vierge = réponse VIDE, jamais un abort (le sed nu sur fichier absent tuait l'apply
# sous set -euo pipefail AVANT le build, sans un mot).
build_sha() {
  local matches=("$PREFIX_REL"/lib/lcars_fleet-*/priv/api/build_info.txt)
  [[ -f "${matches[0]}" ]] || return 0
  sed -n 's/^sha=//p' "${matches[0]}" 2>/dev/null | head -1 || true
}

check() {
  # PAS de garde mix.exs ici : le SOURCE est un besoin de l'apply (build), pas de l'état-cible.
  # En conteneur, l'image n'embarque que etc/ (manifest compris) — exiger le checkout complet
  # faisait échouer la sonde là où elle est la plus utile (défaut révélé au premier boot réel).
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_check; }

  if release_present; then
    p_ok "release posée ($PROV_PREFIX, build $(build_sha))"
  else
    p_drift "release absente sous $PROV_PREFIX"
    verdict_check   # sans release, sonder perms/liens n'apporte que du bruit
  fi

  # Verrou RO : le prefix appartient à root:fleet, groupe sans écriture, autres sans rien.
  local cur
  cur="$(stat -c '%U:%G %a' "$PROV_PREFIX")"
  if [[ "$cur" == "root:$PROV_FLEET_GROUP 750" ]]; then
    p_ok "verrou RO du prefix ($cur)"
  else
    p_drift "prefix non verrouillé : $cur ≠ root:$PROV_FLEET_GROUP 750"
  fi

  # D3 : les fichiers livrés vivent UNIQUEMENT dans $PREFIX/bin (là où install.sh les pose et
  # où fleet_v2 les lit) ; /usr/local/bin ne porte que les symlinks des entrées « link ».
  # L'ancienne sonde exigeait des copies et driftait sur un système SAIN.
  local name mode is_link
  while read -r name mode is_link; do
    if [[ "$mode" == "exec" && ! -x "$PROV_PREFIX/bin/$name" ]]; then
      p_drift "bin/$name absent/non exécutable sous $PROV_PREFIX/bin"
    elif [[ "$mode" == "noexec" && ! -r "$PROV_PREFIX/bin/$name" ]]; then
      p_drift "bin/$name absent/illisible sous $PROV_PREFIX/bin"
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
  [[ -f "$RUNTIME_DIR/mix.exs" ]] || { p_fail "source runtime introuvable: $RUNTIME_DIR"; verdict_apply; }
  [[ -f "$MANIFEST" ]] || { p_fail "manifest introuvable: $MANIFEST (checkout incomplet)"; verdict_apply; }
  command -v mix >/dev/null || { p_fail "mix absent — lance d'abord 15-toolchain"; verdict_apply; }
  id "$PROV_HUMAN" >/dev/null 2>&1 || { p_fail "humain-bâtisseur inconnu: $PROV_HUMAN"; verdict_apply; }

  # Idempotence RÉELLE du deploy : si le build déployé EST le HEAD source (propre), il n'y a
  # rien à bâtir — on ne re-mixe pas 3 minutes pour rien, et surtout on ne déverrouille pas le
  # prefix sans raison. (Le sha embarqué build_info.txt est l'empreinte du build, 8 hex.)
  local src_sha deployed_sha
  # B2 : --short NU des deux côtés — le build embarque le short par défaut de git (abbrev auto,
  # 9 hex sur ce repo) ; un --short=8 côté module ne matchait jamais → rebuild à chaque apply.
  src_sha="$(git -C "$(repo_root)" rev-parse --short HEAD 2>/dev/null || true)"
  deployed_sha="$(build_sha)"
  if [[ -n "$src_sha" && "$src_sha" == "$deployed_sha" ]] \
      && git -C "$(repo_root)" diff --quiet HEAD -- fleet 2>/dev/null && release_present; then
    p_ok "build déployé $deployed_sha == HEAD source (fleet propre) — rien à bâtir"
    # Le câblage /usr/local/bin peut quand même avoir dérivé : on le re-converge, c'est gratuit.
    local name _mode is_link
    while read -r name _mode is_link; do
      [[ "$is_link" -eq 1 ]] || continue
      ensure_symlink "$PROV_LINK_DIR/$name" "$PROV_PREFIX/bin/$name" || verdict_apply
    done < <(mf_entries)
    verdict_apply
  fi

  # Une fleet qui TOURNE depuis ce prefix survit au swap (inodes ouverts) mais ne prendra le
  # nouveau build qu'à son restart — on le DIT, on ne tue rien (jamais tuer une fleet vivante).
  if pgrep -f "$PREFIX_REL" >/dev/null 2>&1; then
    p_warn "une fleet tourne depuis $PROV_PREFIX — le swap est sûr, mais « fleet_v2 stop && fleet_v2 start » pour prendre le nouveau build"
  fi

  # 1. Prefix à l'humain-bâtisseur, le temps de l'install (la carte : « sudo mkdir + chown avant
  #    etc/install.sh »). Re-verrouillé root:fleet en 4 — la fenêtre est ce module, pas un état durable.
  ensure_dir "$PROV_PREFIX" 0750 "$PROV_HUMAN:$PROV_FLEET_GROUP" || verdict_apply
  chown -R "$PROV_HUMAN:$PROV_FLEET_GROUP" "$PROV_PREFIX" || { p_fail "déverrouillage du prefix"; verdict_apply; }

  # 2. hex/rebar de l'humain (idempotent, silencieux en succès).
  p_step "outillage mix (hex + rebar) pour $PROV_HUMAN"
  run_quiet as_human env -C "$RUNTIME_DIR" mix local.hex --force  || verdict_apply
  run_quiet as_human env -C "$RUNTIME_DIR" mix local.rebar --force || verdict_apply

  # 3. L'autorité : build + pose (LONG — mix release ; sortie dumpée seulement en échec).
  # ⚠ LE CODE 3 EST ATTENDU ICI, ET C'EST LE CAS NOMINAL. `install.sh` tourne EN TANT QU'HUMAIN
  # (la carte l'exige : un build root polluerait le _build du checkout), et il pose ses symlinks
  # dans `$PROV_LINK_DIR` — typiquement `/usr/local/bin`, où l'humain n'écrit pas. Depuis 6-110
  # l'installeur REFUSE de dire « OK » sur des liens ratés et rend 3 ; c'est un FAIT (« release
  # posée, câblage incomplet »), pas un verdict, et c'est l'étape 5 ci-dessous qui pose ces liens
  # en root. Traiter 3 comme un échec casserait la provision sur toute machine normale.
  # L'ETAPE LA PLUS LONGUE DE TOUT LE PROVISIONNEMENT, et la seule qui soit muette plusieurs
  # minutes : gate complet (format, compile strict, 3000+ tests, bats, topologie, dialyzer) puis
  # `mix release`. Sans cette ligne, l'ecran est fige et rien ne distingue « ca travaille » de
  # « c'est plante ». `--verbose` donne le detail a qui le demande.
  run_step "build de la release" -- \
    as_human env LCARS_INSTALL_PREFIX="$PROV_PREFIX" LCARS_INSTALL_LINK_DIR="$PROV_LINK_DIR" bash "$RUNTIME_DIR/etc/install.sh"
  local install_rc=$?
  if [[ "$install_rc" -ne 0 && "$install_rc" -ne 3 ]]; then
    p_fail "etc/install.sh en échec (rc=$install_rc — verrou contracts rouge ? warnings-as-errors ?) — le prefix reste déverrouillé pour inspection"
    verdict_apply
  fi
  release_present || { p_fail "install.sh vert mais release absente ($PREFIX_REL) — incohérence, inspecte"; verdict_apply; }

  # 4. Verrou RO (owner root = personne ne remplace un runtime déployé ; groupe fleet lit/traverse).
  chown -R "root:$PROV_FLEET_GROUP" "$PROV_PREFIX" || { p_fail "re-verrouillage chown"; verdict_apply; }
  chmod -R u=rwX,g=rX,o= "$PROV_PREFIX"            || { p_fail "re-verrouillage chmod"; verdict_apply; }

  # 5. Câblage /usr/local/bin — les symlinks-pointeurs des entrées « link », rien d'autre (D3).
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
