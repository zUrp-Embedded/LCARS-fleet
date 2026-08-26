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
# RANG 45. Il etait PORTEUR tant que ce module accordait un droit a `%$PROV_FLEET_GROUP` : les
# modules se decouvrent par glob ordonne `NN-*.sh` (`deploy/provision`), et un rang < 20 aurait
# ouvert root a un groupe que `20-groups.sh` n'avait pas encore cree.
# Ce module n'accorde plus rien — il RETIRE. Le rang ne porte donc plus de contrainte : il est garde
# tel quel parce que le renumeroter deplacerait quatre gestes sans rien gagner.
#
# QUATRE GESTES, UN MOTIF : le rail toolchain (chantier admiral) est du code livre qui n'etait
# CABLE nulle part — trouve par la validation adversariale du PLAN, 2026-08-19. Ce module est le
# cablage cote provisioning ; le binaire est pose par l'image (Dockerfile), la supervision par le
# domaine (BEAM).
#
#   1. le SUDOERS ETROIT — ⚠ RETIRE LE 2026-08-25, ET CE POINT EST DEVENU SON CONTRAIRE : ce module
#      GARDE DESORMAIS SON ABSENCE. La regle etait `%fleet ALL=(root) NOPASSWD:` sur un binaire
#      nomme. Elle etait defendue ici comme « sure par construction : l'entree du binaire est un
#      manifeste deja merge sur une branche protegee » — c'etait FAUX au moment ou c'etait ecrit.
#      L'appelant passait un SHA dont seule la FORME hexadecimale etait controlee, et le depot d'ops
#      porte des commits NON REVUS par conception (c'est ce que le rail EST : des pods y ouvrent des
#      PR). N'importe quel membre de `fleet` — groupe que le convergeur peuple depuis la forge
#      toutes les 30 s — faisait donc appliquer en root le manifeste de n'importe quel commit.
#      Le geste passe par `toolchain.sock` (`lcars-privileged`), et l'appelant n'y ecrit RIEN : le
#      service resout la tete de la branche protegee lui-meme.
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
# ⚠ `CONVERGE_BIN` A DISPARU AVEC LA REGLE QUI LE NOMMAIT. Ce module ne designe plus aucun binaire :
# le seul a l'invoquer est `lcars-privileged`, qui le connait chez lui. Garder la variable ici en
# ferait une seconde autorite sur un chemin, et c'est celle qu'on ne relit pas qui ment.
RUN_STATE="${LCARS_TOOLCHAIN_RUN_STATE:-/run/lcars/toolchain}"
SYSADMIN_UID="${LCARS_SYSADMIN_UID:-1000}"
# ─── LA SOURCE DU SKILL VIT AUX DEUX ENDROITS, ET LE DÉFAUT N'EN CONNAISSAIT QU'UN ──────────────
# `/opt/lcars/admiral-skills` est un chemin d'IMAGE (`Dockerfile:534`, `COPY fleet/deploy/admiral/
# skills`). Sur le rail poste il n'existe pas : le module dérivait donc en accusant l'image —
# « image sans les sources admiral ? » — sur une machine qui n'est pas une image, et le siège n'y
# recevait jamais son skill.
#
# Mesuré le 2026-08-21, install à froid sur machine dédiée :
#   DRIFT 45-sudoers-toolchain: skill system-issues: source absente (/opt/lcars/admiral-skills)
#
# Les deux chemins sont sondés, l'image d'abord (c'est là que le fichier est FIGÉ, donc autoritaire
# quand elle existe), le dépôt ensuite. `repo_root` est déjà ce que la lib rend au module — on ne
# recopie pas un chemin, on demande. La couture de test garde la priorité sur les deux.
SKILL_SRC="${LCARS_ADMIRAL_SKILLS_SRC:-}"
if [[ -z "$SKILL_SRC" ]]; then
  if [[ -d /opt/lcars/admiral-skills ]]; then
    SKILL_SRC=/opt/lcars/admiral-skills
  else
    SKILL_SRC="$(repo_root)/fleet/deploy/admiral/skills"
  fi
fi

# ─── LE SUDOERS EST RETIRE, ET SON ABSENCE EST DESORMAIS CE QUI SE CONVERGE ─────────────────────
#
# La regle etait `%fleet ALL=(root) NOPASSWD: /usr/local/bin/lcars-toolchain-converge` — le lien le
# plus fin du systeme, un chemin `groupe -> root` DIRECT. Et `fleet` n'etait pas une liste d'ayants
# droit : `human-converger` le peuplait depuis l'equipe `humans` de la forge, TOUTES LES 30 s. Le
# droit d'executer du code en root avait donc la peremption d'un cache, et se retirer demandait un
# `pkill`.
#
# Le geste vit maintenant derriere `toolchain.sock`, servie par `lcars-privileged` — et l'appelant
# n'y passe AUCUN argument : le service resout lui-meme la tete de la branche protegee. L'ancien
# rail laissait passer un SHA dont seule la FORME hexadecimale etait controlee, sur un depot ou des
# commits non revus vivent PAR CONCEPTION (c'est ce que le rail EST : des pods y ouvrent des PR).
#
# ⚠ CESSER DE POSER NE SUFFIT PAS, ET C'EST TOUT L'OBJET DE CE BLOC. Retirer l'ecrivain laisse le
# fichier en place sur CHAQUE boite deja provisionnee : le NOPASSWD survivrait au chantier qui le
# retire, indefiniment, sans que rien ne le dise. C'est mot pour mot la maladie que ce module cite
# a son point 3 — « sans convergence, un admin demis garde son droit indefiniment ». La convergence
# est donc un RETRAIT ACTIF, et l'ABSENCE est ce qui se verifie.
check() {
  if [[ -e "$SUDOERS_FILE" ]]; then
    p_drift "IL RESTE UN CHEMIN groupe → root : $SUDOERS_FILE existe encore — l'apply le retire (le geste d'outillage passe par toolchain.sock depuis ce chantier)"
  else
    p_ok "aucune règle sudoers pour l'outillage ($SUDOERS_FILE absent)"
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
  # 1. Le sudoers — RETIRE. Voir le bloc au-dessus de `check` : cesser de poser laisserait le
  #    NOPASSWD sur toute boite deja provisionnee, et un droit qu'on a cesse d'accorder mais jamais
  #    retire est un droit qui reste.
  if [[ -e "$SUDOERS_FILE" ]]; then
    if rm -f "$SUDOERS_FILE"; then
      PROV_CHANGED=$((PROV_CHANGED + 1))
      p_chg "chemin groupe → root RETIRÉ ($SUDOERS_FILE) — le geste d'outillage passe par toolchain.sock"
    else
      p_fail "$SUDOERS_FILE non retiré — le groupe $PROV_FLEET_GROUP garde un NOPASSWD root"
      verdict_apply
    fi
  fi

  # 2. L'etat conteneur — 2775 : le BEAM (groupe fleet) ecrit le marqueur, root le possede.
  #
  # ⚠ `ensure_dir`, PAS `install -d` + `chgrp`. Trois raisons, et la premiere est une garde :
  #   · `install -d` ne passe pas par `prov_refuse_symlink_path`. C'est le vecteur 6-131 exact —
  #     un lien pose dans un composant du chemin, et le prochain apply en root chmode/chowne la
  #     CIBLE. La garde a ete ajoutee a `ensure_dir` pour ca ; ce site ne l'utilisait pas.
  #   · creation et mode etaient DEUX gestes : un crash entre les deux laissait le repertoire sans
  #     son groupe, donc un reconciliateur muet. `ensure_dir` les pose en un seul geste convergent.
  #   · le chemin est desormais DECLARE dans `prov_runtime_dirs` de `25-directories`, donc pose au
  #     boot par le tmpfiles.d. Cet appel-ci ne cree plus rien sur le rail poste — il VERIFIE. Il
  #     reste indispensable sur docker, ou cette table-la rend vide et ou ce module tourne quand meme
  #     (`APPLY-ON: any`).
  #
  # ⚠ LE GROUPE RESTE UN GESTE SEPARE ET TOLERANT, ET C'EST DELIBERE. `ensure_dir … "root:$GROUPE"`
  # etait la forme evidente : elle `p_fail`-e des que le chown est refuse, donc elle transforme en
  # ECHEC ce que ce module classe en DERIVE depuis toujours — un reconciliateur qui ne peut pas
  # noter n'est pas une machine cassee. (Et `ensure_mode` ne sait comparer que `<user>:`, pas
  # `:<groupe>` : lui apprendre la forme miroir pour un seul appelant serait une capacite pour rien.)
  ensure_dir "$RUN_STATE" 2775 \
    || p_drift "etat conteneur ($RUN_STATE) non convergé — le reconciliateur de toolchain ne pourra pas noter"
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
        # ⚠ ROOT CREUSE ICI DANS UN HOME QUE SON PROPRIETAIRE CONTROLE, et c'est le seul site du
        # module dans ce cas. `install -d` suit les liens, et le `chown` deux lignes plus bas aussi :
        # un lien pose en `~/.claude` faisait chowner sa CIBLE. La portee est etroite — `PROV_HUMAN`
        # est celui qui a tape `sudo`, il a deja root — mais c'est le motif que la lib ferme, et une
        # garde qui ne vaut que quand l'attaquant n'a rien a gagner n'est pas une garde.
        #
        # ⚠ ET LE REPERTOIRE RATE FAIT SAUTER LE BLOC ENTIER, il ne se neutralise pas en variable
        # vide. Premiere ecriture de ce correctif : `|| skdst=""` — et les deux `write_atomic`
        # d'apres devenaient `/SKILL.md` et `/list.sh`, ecrits en ROOT A LA RACINE. Une garde qui
        # transforme un echec en chemin different est pire que l'echec.
        if ensure_dir "$skdst" 0755 "$PROV_HUMAN:"; then
          write_atomic "$skdst/SKILL.md" 0644 "$PROV_HUMAN:" < "$SKILL_SRC/system-issues/SKILL.md" || p_fail "skill system-issues: SKILL.md"
          write_atomic "$skdst/list.sh"  0755 "$PROV_HUMAN:" < "$SKILL_SRC/system-issues/list.sh"  || p_fail "skill system-issues: list.sh"
          # `-h` : on ne dereference pas. `ensure_dir` a deja refuse les liens du chemin, ceci ferme
          # la fenetre entre les deux gestes — et ne coute rien sur un vrai repertoire.
          chown -h "$PROV_HUMAN:" "$home/.claude" "$home/.claude/skills" "$skdst" 2>/dev/null || true
          p_ok "skill system-issues pose chez $PROV_HUMAN"
        else
          p_drift "skill system-issues: $skdst non convergé — RIEN n'est posé chez $PROV_HUMAN"
        fi
      else
        p_drift "skill system-issues: home de $PROV_HUMAN introuvable"
      fi
    else
      p_drift "skill system-issues: source absente ($SKILL_SRC) — image sans les sources admiral ?"
    fi

    if [[ -n "${LCARS_STORE_ROOT:-}" && -d "$LCARS_STORE_ROOT" ]]; then
      # ⚠ LA TOLERANCE EST DELIBEREE — le volume peut etre monte en lecture seule, et la projection
      # n'est pas vitale. Mais elle ne dispense pas de la GARDE : `prov_refuse_symlink_path` refuse
      # un lien dans le chemin AVANT qu'un `install -d` en root le suive. `ensure_dir` ne convient
      # pas ici : il `p_fail`-e, donc il ferait compter un echec la ou on en tolere un.
      prov_refuse_symlink_path "$LCARS_STORE_ROOT/state" \
        && install -d -m 2775 "$LCARS_STORE_ROOT/state" 2>/dev/null || true
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
