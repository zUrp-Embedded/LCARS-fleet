#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/52-ops-branch.sh
# AUTHOR: DrDree
# STARDATE: (posee par /push-github)
# STATUS: PROTO-V2 — la boite aux lettres du rail d'outillage : UNE branche, sur LE depot ops
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# ─── CE QUE CETTE BRANCHE EST ──────────────────────────────────────────────────────────────────
# Un pod bloque y ouvre une PR qui demande un outil, un humain signe, le convergeur applique. Elle
# n'existe que sur LE depot ops (`LCARS_OPS_REPO`, defaut `fleet/lcars`) et sur lui seul — jamais
# sur un depot de projet. Un projet a des FACES (code, workshop, ops : son propre registre) ; la
# boite aux lettres, elle, est une propriete du depot de la fleet, pas de ce qu'elle produit.
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
# Donc git, UNE fois, a la creation : un depot jetable, un premier commit — sans parent par
# construction — pousse sous le nom de la branche. Meme idiome que les faces orphelines de
# `Fleet.Project.Onboard` (repo standalone, commit, push sous un nom de branche). Rien n'est
# conserve : ni clone, ni worktree, ni remote.
#
# ─── ET RIEN N'EN A BESOIN SUR LE DISQUE ───────────────────────────────────────────────────────
# Mesure : tout le rail lui parle par l'API. Le depot d'une demande (creation de branche + ecriture
# du fichier + ouverture de PR), la lecture du head par le reconciliateur, la revue par le diff de
# la PR, et l'application par le convergeur — qui lit le manifeste `?ref=<sha>`, AU SHA SIGNE.
# Ce dernier point est une propriete de surete, pas un raccourci : lire « la derniere version de la
# branche » rouvrirait la fenetre entre le constat d'ecart et la lecture, c'est-a-dire permettrait
# d'appliquer autre chose que ce qui a ete signe. Un checkout local serait un etat de plus a
# converger, exactement ce que ce rail existe pour refuser.
#
# ⚠ CE MODULE NE POSE PAS LA PROTECTION. Elle est un geste d'operateur (`forge-gestures.sh
# toolchain-protection <login-du-siege>`) parce qu'elle nomme des approbateurs, et un module de
# provisioning n'a pas a decider qui signe. L'ordre compte dans l'autre sens : la protection sans
# la branche s'annonce VERIFIEE — Gitea garde la regle sous un NOM, que la branche existe ou non.
# C'est ce module qui rend cette annonce vraie.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# LE DEPOT ET LE NOM viennent de l'environnement, avec les MEMES defauts que les deux lecteurs du
# rail (`toolchain-converger.sh`, `Fleet.Admiral.ToolchainReconciler`). Trois copies d'un defaut
# derivent ; celle-ci est la troisieme, et c'est la raison pour laquelle elle est ECRITE ici plutot
# que devinee : un module qui creerait `sysadmin` pendant que le runtime lit `sysops` poserait une
# boite aux lettres que personne ne releve, sans qu'aucun message ne le dise.
: "${LCARS_OPS_REPO:=fleet/lcars}"
: "${LCARS_SYSADMIN_BRANCH:=sysadmin}"

# ─── LA SONDE ───────────────────────────────────────────────────────────────────────────────────
# `GET /repos/<repo>/branches/<branch>` : 200 la branche est la, 404 elle manque. Le jeton systeme
# suffit (lecture d'un depot d'org dont `system` est membre) — pas besoin de l'autorite master.
forge_branch_code() {
  local tokfile="$PROV_TOKENS_DIR/system.gitea_token" tok=""
  local -a auth=()
  [[ -r "$tokfile" ]] && tok="$(tr -d '[:space:]' < "$tokfile")"
  [[ -n "$tok" ]] && auth=(-H "Authorization: token $tok")
  curl -s -o /dev/null -w '%{http_code}' -m 10 "${auth[@]}" \
       "${PROV_FORGE_URL%/}/api/v1/repos/$LCARS_OPS_REPO/branches/$LCARS_SYSADMIN_BRANCH" \
       2>/dev/null || true
}

probe() { # → 0 presente · 1 absente · 2 pas de forge joignable
  [[ -n "${PROV_FORGE_URL:-}" ]] || return 2
  curl -fsS -m 10 -o /dev/null "${PROV_FORGE_URL%/}/api/v1/version" 2>/dev/null || return 2
  case "$(forge_branch_code)" in
    200) return 0 ;;
    404) return 1 ;;
    *)   return 2 ;;
  esac
}

# ─── LE GESTE ───────────────────────────────────────────────────────────────────────────────────
# ⚠ LE JETON NE TOUCHE JAMAIS argv (cicatrice 6-141 : `/proc/<pid>/cmdline` est lisible par tout le
# monde, `environ` non). Il voyage par la config git d'environnement, comme partout ailleurs dans
# le rail — et JAMAIS dans l'URL du remote, qui finirait dans `.git/config` du jetable puis dans
# n'importe quelle sortie de debug.
create_branch() {
  local tokfile="$PROV_TOKENS_DIR/system.gitea_token" tok=""
  [[ -r "$tokfile" ]] && tok="$(tr -d '[:space:]' < "$tokfile")"
  [[ -n "$tok" ]] || { p_fail "pas de jeton systeme ($tokfile) — impossible de pousser la branche"; return 1; }

  local tmp; tmp="$(mktemp -d)"
  # Le jetable meurt quoi qu'il arrive : il contient un depot git avec un remote authentifie.
  trap 'rm -rf "$tmp"' RETURN

  # LE SEMIS. Git ne sait pas representer un dossier vide et le convergeur globe
  # `ops/toolchains.d/*.yaml` — sans fichier, la branche existe et le chemin qu'elle sert n'existe
  # pas. Le README n'est pas de la politesse : la personne qui signe arrive par une notification de
  # PR, pas par la note de design, et ce qu'elle approuve entre dans `/usr` de la boite.
  mkdir -p "$tmp/ops/toolchains.d"
  : > "$tmp/ops/toolchains.d/.gitkeep"
  cat > "$tmp/README.md" <<'SEED'
# Branche `sysadmin` — les demandes d'outillage

Cette branche est une **boite aux lettres**, pas une branche de code : elle n'a aucune histoire
commune avec `main`, et elle ne porte que des manifestes d'outillage sous `ops/toolchains.d/`.

## Ce que tu approuves en signant une PR ici

Le manifeste qui entre par cette PR sera appliqué **par root, sur la boite**, par
`toolchain-converger.sh`. Il n'est pas interprété : le convergeur lit des champs typés et joue des
gabarits de commande fixes, au SHA que tu viens d'approuver. Ce que tu lis dans le diff est donc
exactement ce qui sera fait — c'est la propriété que toute cette mécanique existe pour tenir.

Le champ `evidence` d'un manifeste est écrit **pour toi**. Le convergeur ne le regarde pas.

## Ce qui la protège

`required_approvals=1`, whitelist d'approbateurs, et `dismiss_stale_approvals` — un nouveau push
tue l'approbation. Si tu approuves puis que la branche bouge, il faut re-signer.
SEED

  # `git init` + premier commit = un commit SANS PARENT, donc une branche orpheline par
  # construction. Aucun `--orphan`, donc aucun plancher de version git.
  local ident_n="${PROV_SYSTEM_ACCOUNT:-lcars-system}"
  (
    cd "$tmp"
    git init -q -b "$LCARS_SYSADMIN_BRANCH" .
    git add -A
    GIT_AUTHOR_NAME="$ident_n"    GIT_AUTHOR_EMAIL="$ident_n@noreply.localhost" \
    GIT_COMMITTER_NAME="$ident_n" GIT_COMMITTER_EMAIL="$ident_n@noreply.localhost" \
      git commit -q -m "ops(toolchain): la boite aux lettres des demandes d'outillage"
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.${PROV_FORGE_URL%/}.extraheader" \
    GIT_CONFIG_VALUE_0="Authorization: token $tok" \
      git push -q "${PROV_FORGE_URL%/}/$LCARS_OPS_REPO.git" \
        "HEAD:refs/heads/$LCARS_SYSADMIN_BRANCH"
  ) || { p_fail "création de $LCARS_OPS_REPO:$LCARS_SYSADMIN_BRANCH refusée"; return 1; }

  # RELECTURE : la branche existe VRAIMENT, sinon on n'annonce rien. Un `push` qui rend 0 sur un
  # remote qui a refusé côté hook est un cas connu, et « poussé » n'est pas « présent ».
  probe || { p_fail "après push, $LCARS_SYSADMIN_BRANCH est toujours absente de $LCARS_OPS_REPO"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "branche orpheline $LCARS_OPS_REPO:$LCARS_SYSADMIN_BRANCH créée (ops/toolchains.d/ + README de signature)"
}

check() {
  case "$(probe; echo $?)" in
    0) p_ok "$LCARS_OPS_REPO:$LCARS_SYSADMIN_BRANCH présente — les demandes d'outillage ont où atterrir" ;;
    1) p_drift "$LCARS_OPS_REPO:$LCARS_SYSADMIN_BRANCH ABSENTE — un pod qui demande un outil n'a pas de base de PR, et le réconciliateur échoue à chaque tick sur son head" ;;
    *) p_drift "forge injoignable ou sans réponse sur $LCARS_OPS_REPO — état de la branche $LCARS_SYSADMIN_BRANCH INCONNU (ce module ne conclut pas sans mesure)" ;;
  esac
  verdict_check
}

apply() {
  local rc; probe && rc=0 || rc=$?
  case "$rc" in
    0) # JAMAIS de force-push, JAMAIS de re-semis : cette branche porte des signatures humaines et
       # des manifestes appliqués. Présente = on n'y touche pas, quel que soit son contenu.
       p_ok "$LCARS_OPS_REPO:$LCARS_SYSADMIN_BRANCH déjà présente — rien à faire"
       ;;
    1) create_branch || verdict_apply ;;
    *) p_fail "forge injoignable — la branche ne peut pas être posée (ce n'est pas un état convergé)" ;;
  esac
  verdict_apply
}

case "${1:?usage: 52-ops-branch.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) echo "52-ops-branch.sh: verbe inconnu: $1" >&2; exit 2 ;;
esac
