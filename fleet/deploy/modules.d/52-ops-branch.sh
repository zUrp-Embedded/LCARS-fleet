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

# LE NOM DE LA BRANCHE N'EST PAS REGLABLE, ET IL N'EST PAS DECIDE ICI. Son autorite est
# `Fleet.Toolchain.branch/0` ; cette ligne en est une RECOPIE, tenue par le contrat
# `toolchain.branch_single_source` de `mix lcars.contracts.check`, qui rougit si les deux divergent.
#
# ⚠ IL A ETE REGLABLE A MOITIE, et c'est exactement la panne que le gel ferme : une clef d'app-env
# cote BEAM, une variable d'environnement cote shell, aucun pont. Les defauts coincidaient donc rien
# ne cassait — jusqu'a ce que quelqu'un tourne celle du shell : la branche se cree sous le nouveau
# nom, la protection le suit, et le reconciliateur continue d'interroger l'ancien pendant que les
# manifestes atterrissent la ou personne ne regarde. Le rail a l'air calme.
readonly OPS_BRANCH="tool_request"
: "${LCARS_OPS_REPO:=fleet/lcars}"

# ─── LA SONDE ───────────────────────────────────────────────────────────────────────────────────
# `GET /repos/<repo>/branches/<branch>` : 200 la branche est la, 404 elle manque. Le jeton systeme
# suffit (lecture d'un depot d'org dont `system` est membre) — pas besoin de l'autorite master.
forge_repo_code() {
  local tokfile="$PROV_SYSTEM_TOKEN_FILE" tok=""
  local -a auth=()
  [[ -r "$tokfile" ]] && tok="$(tr -d '[:space:]' < "$tokfile")"
  [[ -n "$tok" ]] && auth=(-H "Authorization: token $tok")
  curl -s -o /dev/null -w '%{http_code}' -m 10 "${auth[@]}" \
       "${PROV_FORGE_URL%/}/api/v1/repos/$LCARS_OPS_REPO" 2>/dev/null || true
}

forge_branch_code() {
  local tokfile="$PROV_SYSTEM_TOKEN_FILE" tok=""
  local -a auth=()
  [[ -r "$tokfile" ]] && tok="$(tr -d '[:space:]' < "$tokfile")"
  [[ -n "$tok" ]] && auth=(-H "Authorization: token $tok")
  curl -s -o /dev/null -w '%{http_code}' -m 10 "${auth[@]}" \
       "${PROV_FORGE_URL%/}/api/v1/repos/$LCARS_OPS_REPO/branches/$OPS_BRANCH" \
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
  local tokfile="$PROV_SYSTEM_TOKEN_FILE" tok=""
  [[ -r "$tokfile" ]] && tok="$(tr -d '[:space:]' < "$tokfile")"
  # ⚠ PAS ENCORE N'EST PAS EN PANNE, et c'est la difference qui a fait rougir un banc sain. Ce
  # module tourne en 52, le jeton systeme est minte en 50 — mais au PREMIER boot la forge n'est pas
  # encore semee, donc `50-forge` n'a rien pu frapper et le fichier n'existe pas. Rendre FAIL la
  # faisait publier `rc=1` a une boite dont le seul tort etait d'etre neuve, et le vrai etat — « la
  # branche se posera a la convergence suivante » — n'etait dit nulle part.
  #
  # Un DRIFT dit exactement ca : non converge, converge-moi. Le doctor le montre, la passe d'apres
  # le ferme, et un jeton qui ne viendrait JAMAIS reste visible a chaque passage au lieu de
  # disparaitre dans un echec de boot que personne ne relit.
  [[ -n "$tok" ]] || {
    p_drift "jeton systeme pas encore la ($tokfile) — 50-forge le minte quand la forge est semee ; la branche se posera a la convergence suivante"
    return 0; }

  # ⚠ ET IL Y A UN SECOND « PAS ENCORE », QUE LE PREMIER CACHAIT. Une branche se pousse sur un
  # depot, et le depot ops est seme par l'amorcage de la forge — pas par ce module. Sur un banc neuf
  # l'ordre reel est : boot 1 (pas de jeton) · amorcage passe 1 (structure, pas de semis) · boot 2
  # (jeton frappe, DEPOT PAS ENCORE LA) · amorcage passe 2 (semis). Donc au seul boot qui avait un
  # jeton, la cible n'existait pas.
  #
  # Sans ce garde, git pousse dans le vide et la forge repond « Push to create is not enabled for
  # organizations » en 403 — un message qui parle d'une fonctionnalite desactivee, alors que le fait
  # est « le depot n'est pas encore ne ». Un lecteur y cherche un reglage de forge et ne trouve rien.
  #
  # La distinction ne se lit PAS sur la sonde de branche : sur un depot absent, l'API rend 404 sur la
  # branche exactement comme sur une branche absente d'un depot present. Il faut demander le depot.
  case "$(forge_repo_code)" in
    200) : ;;
    404) p_drift "depot $LCARS_OPS_REPO pas encore seme — l'amorcage de la forge le cree ; la branche se posera a la convergence suivante"
         return 0 ;;
    *)   p_fail "$LCARS_OPS_REPO : la forge ne dit pas s'il existe — on ne pousse pas a l'aveugle"
         return 1 ;;
  esac

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
# Branche `tool_request` — les demandes d'outillage

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
  local ident_n="${PROV_SYSTEM_ACCOUNT:-system_starfleet}"
  (
    cd "$tmp"
    git init -q -b "$OPS_BRANCH" .
    git add -A
    GIT_AUTHOR_NAME="$ident_n"    GIT_AUTHOR_EMAIL="$ident_n@noreply.localhost" \
    GIT_COMMITTER_NAME="$ident_n" GIT_COMMITTER_EMAIL="$ident_n@noreply.localhost" \
      git commit -q -m "ops(toolchain): la boite aux lettres des demandes d'outillage"
    GIT_TERMINAL_PROMPT=0 GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0="http.${PROV_FORGE_URL%/}.extraheader" \
    GIT_CONFIG_VALUE_0="Authorization: token $tok" \
      git push -q "${PROV_FORGE_URL%/}/$LCARS_OPS_REPO.git" \
        "HEAD:refs/heads/$OPS_BRANCH"
  ) || { p_fail "création de $LCARS_OPS_REPO:$OPS_BRANCH refusée"; return 1; }

  # RELECTURE : la branche existe VRAIMENT, sinon on n'annonce rien. Un `push` qui rend 0 sur un
  # remote qui a refusé côté hook est un cas connu, et « poussé » n'est pas « présent ».
  # ⚠ LES DEUX ECHECS DE LA SONDE NE DISENT PAS LA MEME CHOSE, et les confondre envoie l'operateur
  # chercher au mauvais endroit. `probe` rend 1 sur « branche absente » et 2 sur « forge
  # injoignable » : un seul message pour les deux annonçait un push raté là où la forge avait
  # simplement cessé de répondre entre le push et la relecture. Fenêtre étroite, diagnostic faux.
  # (Revue 2026-08-20.)
  local rc; probe && rc=0 || rc=$?
  case "$rc" in
    0) : ;;
    1) p_fail "après push, $OPS_BRANCH est toujours absente de $LCARS_OPS_REPO"; return 1 ;;
    *) p_fail "après push, la forge ne répond plus — l'état de $OPS_BRANCH est INCONNU, ni confirmé ni infirmé"; return 1 ;;
  esac
  PROV_CHANGED=$((PROV_CHANGED + 1))
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
    # ⚠ DRIFT ET PAS FAIL, ET C'EST `check` QUI AVAIT RAISON. Sur la MÊME mesure (`probe` rend 2 :
    # la forge ne répond pas), `check` disait drift et `apply` disait échec. Le modèle du rail est
    # que le doctor n'est pas un autre code — c'est le même check — donc deux verdicts opposés sur
    # une mesure unique est une contradiction interne, pas une nuance.
    #
    # ET LA BONNE RÉPONSE EST DRIFT, parce que « pas de forge » est l'état NORMAL d'une première
    # passe : `48-forge-host` la monte, et s'il dérive (image absente, docker muet) tout l'aval le
    # constate. Ses deux voisins immédiats — `50-forge` et `55-deck-oidc` — dérivent sur cette
    # cause exacte. Ce module seul rendait 1, donc l'apply entier rendait 1, donc `install.sh`
    # déclarait l'installation EN ÉCHEC là où il manquait un geste.
    #
    # Mesuré le 2026-08-21, install à froid sur machine dédiée : DRIFT 48 · DRIFT 50 · **FAIL 52** ·
    # DRIFT 55. Un seul module transformait une convergence partielle en échec.
    *) p_drift "forge injoignable — la branche n'est pas posée. Elle est montée par 48-forge-host (ou par la boîte) ; la branche se posera a la convergence suivante" ;;
  esac
  verdict_apply
}

case "${1:?usage: 52-ops-branch.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) echo "52-ops-branch.sh: verbe inconnu: $1" >&2; exit 2 ;;
esac
