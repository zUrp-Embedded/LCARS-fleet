#!/usr/bin/env bash
# SOURCE: runtime/services/forge.d/ops-branch.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — la boite aux lettres du rail d'outillage : UNE branche, sur LE depot ops
# JOUE PAR : le boot du conteneur (a chaque demarrage) et l'installeur d'un poste, par un
# appelant mince. Ni terrain ni ordre ne se declarent ici : ces en-tetes ne sont lus que dans
# `deploy/modules.d`, et les recopier ici promettait une mecanique que personne ne joue.
#
# ─── ORPHELINE, ET AUCUNE API NE SAIT LA FAIRE ─────────────────────────────────────────────────
# `POST /repos/<r>/branches` exige `old_ref_name` : il rend une branche FILLE de ce qu'on lui
# nomme. `PUT /contents/<p>` avec `new_branch` part pareil d'une base existante. Aucun endpoint
# Gitea ne cree un commit sans parent — la question n'est pas de chercher le bon appel, il n'y en a
# pas.
#
# ⚠ ET UNE FILLE DE `main` NE FERAIT PAS L'AFFAIRE, ce n'est pas une preference de purete : elle
# porterait tout l'arbre du code, donc la PR qui ajoute un manifeste se lirait contre lui, et ce
# que l'humain doit voir au moment de SIGNER, c'est le manifeste et rien d'autre. La protection
# (`required_approvals=1`, `dismiss_stale_approvals`) s'appliquerait en prime a une branche qui
# porte du code : la boite aux lettres deviendrait une branche de code par accident.
#
# ⚠ CE MODULE NE POSE PAS LA PROTECTION. Elle est un geste d'operateur (`forge-gestures.sh
# toolchain-protection <login-du-siege>`) parce qu'elle nomme des approbateurs, et un module de
# provisioning n'a pas a decider qui signe. L'ordre compte dans l'autre sens : la protection sans
# la branche s'annonce VERIFIEE — Gitea garde la regle sous un NOM, que la branche existe ou non.
# C'est ce module qui rend cette annonce vraie.

set -euo pipefail

# L'hote nomme le protocole (LCARS_MODULE_PROTOCOL) : le boot du conteneur, un module de
# l'installeur, ou un temoin. Le contrat de ce dialecte est dans le fichier source.
# shellcheck source=../lib/module-protocol.sh
. "${LCARS_MODULE_PROTOCOL:?LCARS_MODULE_PROTOCOL non pose — lance via un module de l installeur ou le boot du conteneur, pas le geste nu}"

# Nue, pas `readonly` : les temoins sourcent la tete d'un module pour epingler une fonction, et un
# second `source` dans le meme shell mourrait en « readonly variable ». Le gel du nom est tenu par
# le contrat `toolchain.branch_single_source` et par ops-branch.bats, pas par l'attribut.
OPS_BRANCH="tool_request"
: "${LCARS_OPS_REPO:=lcars/_ops}"

forge_repo_code() {
  forge_curl "$LCARS_SYSTEM_TOKEN_FILE" -s -o /dev/null -w '%{http_code}' -m 10 \
       "${FORGE_BASE_URL%/}/api/v1/repos/$LCARS_OPS_REPO" 2>/dev/null || true
}

forge_branch_code() {
  forge_curl "$LCARS_SYSTEM_TOKEN_FILE" -s -o /dev/null -w '%{http_code}' -m 10 \
       "${FORGE_BASE_URL%/}/api/v1/repos/$LCARS_OPS_REPO/branches/$OPS_BRANCH" \
       2>/dev/null || true
}

probe() { # → 0 presente · 1 absente · 2 pas de forge joignable
  [[ -n "${FORGE_BASE_URL:-}" ]] || return 2
  curl -fsS -m 10 -o /dev/null "${FORGE_BASE_URL%/}/api/v1/version" 2>/dev/null || return 2
  case "$(forge_branch_code)" in
    200) return 0 ;;
    404) return 1 ;;
    *)   return 2 ;;
  esac
}

# ⚠ LE JETON NE TOUCHE JAMAIS argv (cicatrice 6-141 : `/proc/<pid>/cmdline` est lisible par tout le
# monde, `environ` non). Il voyage par la config git d'environnement, comme partout ailleurs dans
# le rail — et JAMAIS dans l'URL du remote, qui finirait dans `.git/config` du jetable puis dans
# n'importe quelle sortie de debug.
create_branch() {
  local tokfile="$LCARS_SYSTEM_TOKEN_FILE" tok
  tok="$(read_token "$tokfile")"
  [[ -n "$tok" ]] || {
    p_drift "jeton système pas encore là ($tokfile) — le geste des jetons le minte quand la forge est semée (sur un poste, « deploy/workstation up » ; dans un conteneur, son démarrage) ; la branche se posera à la convergence suivante"
    return 0; }

  # La distinction ne se lit PAS sur la sonde de branche : sur un depot absent, l'API rend 404 sur la
  # branche exactement comme sur une branche absente d'un depot present. Il faut demander le depot.
  case "$(forge_repo_code)" in
    200) : ;;
    404) p_drift "depot $LCARS_OPS_REPO absent — l'amorcage de la forge le cree (forge-gestures apply) ; la branche se posera a la convergence suivante"
         return 0 ;;
    *)   p_fail "$LCARS_OPS_REPO : la forge ne dit pas s'il existe — on ne pousse pas a l'aveugle"
         return 1 ;;
  esac

  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  mkdir -p "$tmp/ops/toolchains.d"
  : > "$tmp/ops/toolchains.d/.gitkeep"
  cat > "$tmp/README.md" <<'SEED'
# Branche `tool_request` — les demandes d'outillage

Cette branche est une **boite aux lettres**, pas une branche de code : elle n'a aucune histoire
commune avec `main`, et elle ne porte que des manifestes d'outillage sous `ops/toolchains.d/`.

## Ce que tu approuves en signant une PR ici

Le manifeste qui entre par cette PR sera appliqué **par root, sur le conteneur**, par
`runtime/bin/lcars-toolchain-converge`. Il n'est pas interprété : le convergeur lit des champs typés et joue des
gabarits de commande fixes, au SHA que tu viens d'approuver. Ce que tu lis dans le diff est donc
exactement ce qui sera fait — c'est la propriété que toute cette mécanique existe pour tenir.

Le champ `evidence` d'un manifeste est écrit **pour toi**. Le convergeur ne le regarde pas.

## Ce qui la protège

`required_approvals=1`, whitelist d'approbateurs, et `dismiss_stale_approvals` — un nouveau push
tue l'approbation. Si tu approuves puis que la branche bouge, il faut re-signer.
SEED

  # `git init` + premier commit = un commit SANS PARENT, donc une branche orpheline par
  # construction. Aucun `--orphan`, donc aucun plancher de version git.
  local ident_n="$LCARS_SYSTEM_ACCOUNT"
  (
    cd "$tmp"
    git init -q -b "$OPS_BRANCH" .
    git add -A
    GIT_AUTHOR_NAME="$ident_n"    GIT_AUTHOR_EMAIL="$ident_n@noreply.localhost" \
    GIT_COMMITTER_NAME="$ident_n" GIT_COMMITTER_EMAIL="$ident_n@noreply.localhost" \
      git commit -q -m "ops(toolchain): la boite aux lettres des demandes d'outillage"
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.${FORGE_BASE_URL%/}.extraheader" \
    GIT_CONFIG_VALUE_0="Authorization: token $tok" \
      git push -q "${FORGE_BASE_URL%/}/$LCARS_OPS_REPO.git" \
        "HEAD:refs/heads/$OPS_BRANCH"
  ) || { p_fail "création de $LCARS_OPS_REPO:$OPS_BRANCH refusée"; return 1; }

  # RELECTURE : la branche existe VRAIMENT, sinon on n'annonce rien. Un `push` qui rend 0 sur un
  # remote qui a refusé côté hook est un cas connu, et « poussé » n'est pas « présent ».
  local rc; probe && rc=0 || rc=$?
  case "$rc" in
    0) : ;;
    1) p_fail "après push, $OPS_BRANCH est toujours absente de $LCARS_OPS_REPO"; return 1 ;;
    *) p_fail "après push, la forge ne répond plus — l'état de $OPS_BRANCH est INCONNU, ni confirmé ni infirmé"; return 1 ;;
  esac
  LCARS_CHANGED=$((LCARS_CHANGED + 1))
  p_chg "branche orpheline $LCARS_OPS_REPO:$OPS_BRANCH créée (ops/toolchains.d/ + README de signature)"
}

check() {
  case "$(probe; echo $?)" in
    0) p_ok "$LCARS_OPS_REPO:$OPS_BRANCH présente — les demandes d'outillage ont où atterrir" ;;
    1) p_drift "$LCARS_OPS_REPO:$OPS_BRANCH ABSENTE — un pod qui demande un outil n'a pas de base de PR, et le réconciliateur échoue à chaque tick sur son head" ;;
    *) p_drift "forge injoignable ou sans réponse sur $LCARS_OPS_REPO — état de la branche $OPS_BRANCH INCONNU (ce module ne conclut pas sans mesure)" ;;
  esac
  verdict_check
}

apply() {
  local rc; probe && rc=0 || rc=$?
  case "$rc" in
    0) # JAMAIS de force-push, JAMAIS de re-semis : cette branche porte des signatures humaines et
       # des manifestes appliqués. Présente = on n'y touche pas, quel que soit son contenu.
       p_ok "$LCARS_OPS_REPO:$OPS_BRANCH déjà présente — rien à faire"
       ;;
    1) create_branch || verdict_apply ;;
    *) p_drift "forge injoignable — la branche n'est pas posée. La forge est montée par l'installation sur un poste, ou fournie à l'instance ; la branche se posera à la convergence suivante" ;;
  esac
  verdict_apply
}

case "${1:?usage: ops-branch.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
