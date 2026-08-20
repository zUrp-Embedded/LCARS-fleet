#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/45-sudoers-toolchain.sh
# AUTHOR: bob
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — les quatre ancrages systeme du domaine admiral (sudoers etroit, etat
#         conteneur, projection du login du siege, skill du siege)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# RANG 45, ET C'EST PORTEUR : les modules se decouvrent par glob ordonne `NN-*.sh`
# (`deploy/provision`), et `%$PROV_FLEET_GROUP` ci-dessous suppose un groupe que `20-groups.sh`
# vient de creer. Un rang < 20 accorderait un NOPASSWD a un groupe inexistant.
#
# QUATRE GESTES, UN MOTIF : le rail toolchain (chantier admiral) est du code livre qui n'etait
# CABLE nulle part — trouve par la validation adversariale du PLAN, 2026-08-19. Ce module est le
# cablage cote provisioning ; le binaire est pose par l'image (Dockerfile), la supervision par le
# domaine (BEAM).
#
#   1. le SUDOERS ETROIT (`01` §4.6) : `%fleet` peut invoquer UN binaire nomme, jamais un shell.
#      Sur par construction : l'entree du binaire est un manifeste deja merge sur une branche
#      protegee, et il est idempotent — un appel direct par n'importe quel membre applique un etat
#      deja approuve.
#      ⚠ CICATRICE `provision-lib.sh:18` : une v1 d'un autre sudoers ecrivait EN PLACE et rendait
#      un fichier tronque — une machine ou plus personne ne passe root. D'ou `write_atomic`,
#      JAMAIS une redirection — et `visudo -cf` sur le contenu AVANT la pose : un sudoers.d
#      invalide fait refuser TOUT sudo, pas seulement celui-ci.
#
#   2. l'ETAT CONTENEUR du reconciliateur (`/run/lcars/toolchain` — un TMPFS : il meurt avec le
#      conteneur PAR CONSTRUCTION, et aucun volume ne peut le recouvrir ; 2775 root:fleet) : le
#      marqueur `toolchain.applied` decrit L'ETAT DE /usr, qui meurt avec le conteneur. Le poser
#      sur le magasin (volume externe, survit au rebuild) faisait dire « a jour » a une boite
#      reconstruite dont /usr etait revenu a la baseline — l'exact mensonge que `01` §4.5 refuse.
#      La duree de vie du marqueur SUIT celle de l'objet qu'il decrit (`01` §4.8, la doctrine des
#      volumes, appliquee a un fichier). Ecrit par le BEAM (uid worker, groupe fleet) => 2775.
#
#   3. la PROJECTION DU LOGIN DU SIEGE (`<store>/state/pilot.assignee`) : l'assignee des issues
#      `error_system` est le login REEL du siege — VARIABLE (celui de l'installeur en prod,
#      `00` §5). Le BEAM ne peut pas le connaitre autrement : l'env `LCARS_ADMIRAL` ne l'atteint
#      pas (le demon tourne sous un uid worker, GUARD B ecarte l'uid qui porte l'env).
#      ⚠ KEYE SUR L'UID, PAS SUR L'APPELANT : ce module tourne pour N'IMPORTE QUEL `--human`
#      (l'entrypoint le joue pour le siege, un enrolement peut le jouer pour un worker). Seul le
#      passage du SIEGE ecrit la projection — `uid == LCARS_SYSADMIN_UID`, la meme cle que
#      GUARD A/B, jamais un nom.
#      REECRITURE INCONDITIONNELLE : c'est une projection convergee, pas une creation — un login
#      qui change doit ecraser l'ancien (`01` §4.7 : « sans convergence, un admin demis garde son
#      droit indefiniment », meme maladie).
#      GARDEE SUR LE MAGASIN : `LCARS_STORE_ROOT` vide/absente => AUCUNE ecriture (sinon bash
#      etendrait en `/state/pilot.assignee`, cree a la racine, jamais lu). Magasin non monte
#      (avant le lot F) => la projection est INERTE et les issues s'ouvrent sans assignee —
#      DR-023, dit au PLAN B0.3, pas a decouvrir.
#
#   4. le SKILL `system-issues` dans le `~/.claude` du SIEGE (`05` §7) : la boite de reception
#      d'admiral, posee par le provisioning et JAMAIS par le catalogue — un skill du catalogue
#      serait montable dans un pod par deux fautes de frappe ; celui-ci ne vit que chez le siege.
#      Meme cle (uid), meme reecriture inconditionnelle que la projection.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

SUDOERS_DIR="${LCARS_SUDOERS_DIR:-/etc/sudoers.d}"
SUDOERS_FILE="$SUDOERS_DIR/lcars-toolchain"
CONVERGE_BIN="${LCARS_TOOLCHAIN_CONVERGE_BIN:-/usr/local/bin/lcars-toolchain-converge}"
RUN_STATE="${LCARS_TOOLCHAIN_RUN_STATE:-/run/lcars/toolchain}"
SYSADMIN_UID="${LCARS_SYSADMIN_UID:-1000}"
SKILL_SRC="${LCARS_ADMIRAL_SKILLS_SRC:-/opt/lcars/admiral-skills}"

sudoers_line() { printf '%%%s ALL=(root) NOPASSWD: %s\n' "$PROV_FLEET_GROUP" "$CONVERGE_BIN"; }

check() {
  if [[ -f "$SUDOERS_FILE" ]] && cmp -s <(sudoers_line) "$SUDOERS_FILE"; then
    p_ok "sudoers etroit ($SUDOERS_FILE)"
  else
    p_drift "sudoers etroit absent ou divergent ($SUDOERS_FILE)"
  fi
  if [[ -d "$RUN_STATE" ]]; then
    p_ok "etat conteneur du reconciliateur ($RUN_STATE)"
  else
    p_drift "etat conteneur absent ($RUN_STATE) — le reconciliateur n'aura pas de memoire"
  fi
  # Le skill du siege — sonde uniquement quand le module tourne POUR le siege (meme cle que apply).
  local _uid; _uid="$(id -u -- "$PROV_HUMAN" 2>/dev/null || true)"
  if [[ "$_uid" == "$SYSADMIN_UID" ]]; then
    local _home; _home="${LCARS_SIEGE_HOME:-$(getent passwd -- "$PROV_HUMAN" | cut -d: -f6)}"
    if [[ -x "$_home/.claude/skills/system-issues/list.sh" ]]; then
      p_ok "skill system-issues present chez $PROV_HUMAN"
    else
      p_drift "skill system-issues ABSENT chez $PROV_HUMAN — la boite de reception est illisible depuis sa session"
    fi
  fi

  # La projection ne se check que si elle est POSSIBLE (magasin monte) et DUE (siege connu).
  if [[ -n "${LCARS_STORE_ROOT:-}" && -d "${LCARS_STORE_ROOT:-/nonexistent}" ]]; then
    if [[ -s "$LCARS_STORE_ROOT/state/pilot.assignee" ]]; then
      p_ok "projection du siege ($(cat "$LCARS_STORE_ROOT/state/pilot.assignee"))"
    else
      p_drift "projection du siege absente — les issues systeme s'ouvriront sans assignee"
    fi
  else
    p_ok "magasin non monte — projection du siege inerte (DR-023, nominal avant le lot F)"
  fi
  verdict_check
}

apply() {
  # 1. Le sudoers — valide AVANT la pose. `visudo -cf` lit un fichier : on valide le contenu dans
  #    un tmp a nous, puis write_atomic pose (tmp + rename, jamais le fichier en etat partiel).
  local vtmp
  vtmp="$(mktemp)" || { p_fail "sudoers: mktemp"; verdict_apply; }
  sudoers_line > "$vtmp"
  if command -v visudo >/dev/null 2>&1 && ! visudo -cf "$vtmp" >/dev/null 2>&1; then
    rm -f "$vtmp"
    p_fail "sudoers: contenu REFUSE par visudo — rien n'est pose"
    verdict_apply
  fi
  write_atomic "$SUDOERS_FILE" 0440 < "$vtmp" || { rm -f "$vtmp"; verdict_apply; }
  rm -f "$vtmp"
  p_ok "sudoers etroit pose ($SUDOERS_FILE)"

  # 2. L'etat conteneur — 2775 : le BEAM (groupe fleet) ecrit le marqueur, root le possede.
  install -d -m 2775 "$RUN_STATE" || { p_fail "etat conteneur: install -d $RUN_STATE"; verdict_apply; }
  chgrp "$PROV_FLEET_GROUP" "$RUN_STATE" 2>/dev/null \
    || p_drift "etat conteneur: chgrp $PROV_FLEET_GROUP a echoue — le reconciliateur ne pourra pas noter"

  # 3+4. La projection du siege ET son skill — uid-keyes, inconditionnels.
  local uid
  uid="$(id -u -- "$PROV_HUMAN" 2>/dev/null || true)"
  if [[ "$uid" == "$SYSADMIN_UID" ]]; then
    # 4. Le skill system-issues — chez le SIEGE et personne d'autre.
    if [[ -d "$SKILL_SRC/system-issues" ]]; then
      local home skdst
      # Couture de test (LCARS_SIEGE_HOME) : les bats ne doivent JAMAIS ecrire dans le vrai home
      # de qui les joue. En prod la variable est absente et getent fait foi.
      home="${LCARS_SIEGE_HOME:-$(getent passwd -- "$PROV_HUMAN" | cut -d: -f6)}"
      if [[ -n "$home" && -d "$home" ]]; then
        skdst="$home/.claude/skills/system-issues"
        install -d -m 0755 "$skdst"
        write_atomic "$skdst/SKILL.md" 0644 "$PROV_HUMAN:" < "$SKILL_SRC/system-issues/SKILL.md"           || p_fail "skill system-issues: SKILL.md"
        write_atomic "$skdst/list.sh" 0755 "$PROV_HUMAN:" < "$SKILL_SRC/system-issues/list.sh"           || p_fail "skill system-issues: list.sh"
        chown "$PROV_HUMAN:" "$home/.claude" "$home/.claude/skills" "$skdst" 2>/dev/null || true
        p_ok "skill system-issues pose chez $PROV_HUMAN"
      else
        p_drift "skill system-issues: home de $PROV_HUMAN introuvable"
      fi
    else
      p_drift "skill system-issues: source absente ($SKILL_SRC) — image sans les sources admiral ?"
    fi

    if [[ -n "${LCARS_STORE_ROOT:-}" && -d "$LCARS_STORE_ROOT" ]]; then
      install -d -m 2775 "$LCARS_STORE_ROOT/state" 2>/dev/null || true
      # Redirection, JAMAIS un pipe vers write_atomic : ses compteurs de verdict vivraient dans le
      # subshell du pipe et seraient perdus (la regle B3 de `30-wsl.sh:152`).
      if write_atomic "$LCARS_STORE_ROOT/state/pilot.assignee" 0644 <<<"$PROV_HUMAN"; then
        p_ok "projection du siege : $PROV_HUMAN -> pilot.assignee"
      else
        p_fail "projection du siege : ecriture impossible"
      fi
    else
      p_ok "magasin non monte — projection du siege inerte (DR-023)"
    fi
  fi

  verdict_apply
}

case "${1:?usage: 45-sudoers-toolchain.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
