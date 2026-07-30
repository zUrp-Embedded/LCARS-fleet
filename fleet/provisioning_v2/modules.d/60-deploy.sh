#!/usr/bin/env bash
# SOURCE: fleet/provisioning_v2/modules.d/60-deploy.sh
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
# Ce module N'INVENTE PAS le déploiement : fleet/runtime/etc/install.sh est l'autorité (modèle
# 3 zones SOURCE→INSTALL→STATE, release self-contained, idempotent). Ici, on mécanise la carte de
# déploiement AUTOUR de lui — les gestes qui étaient à la main :
#   1. dévérouiller $PREFIX pour l'humain-bâtisseur (install.sh tourne SANS sudo, la carte l'exige :
#      un build root polluerait le _build du checkout de l'humain) ;
#   2. hex/rebar locaux de l'humain (mix release en a besoin, le gate CI fait pareil) ;
#   3. etc/install.sh (build + pose + template env) — LONG (mix release) ;
#   4. re-VERROUILLER : root:fleet, u=rwX,g=rX,o= (personne ne modifie un runtime déployé) ;
#   5. câbler /usr/local/bin : symlinks fleet_v2+lcars (une seule source), COPIES des 3 launchers
#      pod (contrat spawner : paths absolus /usr/local/bin, défaut de pod.ex — et claude_launch
#      s'exécute DANS le sandbox où seuls les mounts RO système sont visibles → copie réelle,
#      pas un lien vers un prefix potentiellement non-bindé).
# En Docker, tout ceci est un LAYER du stage runtime (docker/Dockerfile) — même install.sh,
# même verrouillage, vérifié par le même doctor. D'où SUBSTRATE: wsl linux.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

RUNTIME_DIR="$(repo_root)/fleet/runtime"
LAUNCHERS=(bwrap_launch.sh host_launch.sh claude_launch.sh)
SYMLINKED=(fleet_v2 lcars)

release_present() { [[ -x "$PREFIX_REL/bin/fleet_umbrella" ]]; }
PREFIX_REL="$PROV_PREFIX/rel/fleet_umbrella"

build_sha() { sed -n 's/^sha=//p' "$PROV_PREFIX/rel/fleet_umbrella/build_info.txt" 2>/dev/null | head -1; }

check() {
  [[ -f "$RUNTIME_DIR/mix.exs" ]] || { p_fail "source runtime introuvable: $RUNTIME_DIR (checkout incomplet)"; verdict_check; }

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

  local f
  for f in "${SYMLINKED[@]}"; do
    if [[ "$(readlink "/usr/local/bin/$f" 2>/dev/null)" == "$PROV_PREFIX/bin/$f" ]]; then
      p_ok "symlink /usr/local/bin/$f"
    else
      p_drift "/usr/local/bin/$f ≠ symlink vers $PROV_PREFIX/bin/$f"
    fi
  done
  for f in "${LAUNCHERS[@]}"; do
    if cmp -s "$PROV_PREFIX/bin/$f" "/usr/local/bin/$f" 2>/dev/null; then
      p_ok "launcher /usr/local/bin/$f (= version du prefix)"
    else
      p_drift "/usr/local/bin/$f absent ou ≠ de la version déployée"
    fi
  done
  verdict_check
}

apply() {
  [[ -f "$RUNTIME_DIR/mix.exs" ]] || { p_fail "source runtime introuvable: $RUNTIME_DIR"; verdict_apply; }
  command -v mix >/dev/null || { p_fail "mix absent — lance d'abord 15-toolchain"; verdict_apply; }
  id "$PROV_HUMAN" >/dev/null 2>&1 || { p_fail "humain-bâtisseur inconnu: $PROV_HUMAN"; verdict_apply; }

  # Idempotence RÉELLE du deploy : si le build déployé EST le HEAD source (propre), il n'y a
  # rien à bâtir — on ne re-mixe pas 3 minutes pour rien, et surtout on ne déverrouille pas le
  # prefix sans raison. (Le sha embarqué build_info.txt est l'empreinte du build, 8 hex.)
  local src_sha deployed_sha
  src_sha="$(git -C "$(repo_root)" rev-parse --short=8 HEAD 2>/dev/null || true)"
  deployed_sha="$(build_sha)"
  if [[ -n "$src_sha" && "$src_sha" == "$deployed_sha" ]] \
      && git -C "$(repo_root)" diff --quiet HEAD -- fleet/runtime 2>/dev/null && release_present; then
    p_ok "build déployé $deployed_sha == HEAD source (fleet/runtime propre) — rien à bâtir"
    # Le câblage /usr/local/bin peut quand même avoir dérivé : on le re-converge, c'est gratuit.
    local f
    for f in "${SYMLINKED[@]}"; do ensure_symlink "/usr/local/bin/$f" "$PROV_PREFIX/bin/$f" || verdict_apply; done
    for f in "${LAUNCHERS[@]}"; do
      cmp -s "$PROV_PREFIX/bin/$f" "/usr/local/bin/$f" 2>/dev/null \
        || { write_atomic "/usr/local/bin/$f" 0755 root:root < "$PROV_PREFIX/bin/$f" || verdict_apply; }
    done
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
  run_quiet as_human env -C "$RUNTIME_DIR" mix local.hex --force  || verdict_apply
  run_quiet as_human env -C "$RUNTIME_DIR" mix local.rebar --force || verdict_apply

  # 3. L'autorité : build + pose (LONG — mix release ; sortie dumpée seulement en échec).
  if ! run_quiet as_human env LCARS_INSTALL_PREFIX="$PROV_PREFIX" bash "$RUNTIME_DIR/etc/install.sh"; then
    p_fail "etc/install.sh en échec (verrou contracts rouge ? warnings-as-errors ?) — le prefix reste déverrouillé pour inspection"
    verdict_apply
  fi
  release_present || { p_fail "install.sh vert mais release absente ($PREFIX_REL) — incohérence, inspecte"; verdict_apply; }

  # 4. Verrou RO (owner root = personne ne remplace un runtime déployé ; groupe fleet lit/traverse).
  chown -R "root:$PROV_FLEET_GROUP" "$PROV_PREFIX" || { p_fail "re-verrouillage chown"; verdict_apply; }
  chmod -R u=rwX,g=rX,o= "$PROV_PREFIX"            || { p_fail "re-verrouillage chmod"; verdict_apply; }

  # 5. Câblage /usr/local/bin.
  local f
  for f in "${SYMLINKED[@]}"; do
    ensure_symlink "/usr/local/bin/$f" "$PROV_PREFIX/bin/$f" || verdict_apply
  done
  for f in "${LAUNCHERS[@]}"; do
    if ! cmp -s "$PROV_PREFIX/bin/$f" "/usr/local/bin/$f" 2>/dev/null; then
      write_atomic "/usr/local/bin/$f" 0755 root:root < "$PROV_PREFIX/bin/$f" || verdict_apply
    fi
  done

  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "runtime déployé : $PROV_PREFIX (build $(build_sha)) + /usr/local/bin câblé"
  verdict_apply
}

case "${1:?usage: 60-deploy.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
