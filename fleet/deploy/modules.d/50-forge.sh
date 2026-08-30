#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/50-forge.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — forge : SONDE de la structure (territoire OpenTofu) + jambe tokens (A4)
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
# AFTER: 45-catalogues 48-forge-host

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

: "${PROV_PASSWORDS_FILE:=$PROV_TOKENS_DIR/forge-role-passwords.json}"
A4_SCRIPT="$(repo_root)/fleet/etc/provision-role-tokens.sh"
# LE ROSTER EST DERIVE, PAS DECLARE — `prov_roles` (provision-lib) lit ce que les catalogues
# INSTALLES declarent, plus le plancher systeme. Resolu UNE fois ici et non a chaque usage : entre
# deux appels d'un meme cycle la liste ne doit pas bouger, sinon la sonde et le mint travaillent sur
# deux ensembles differents et le rapport parle d'un etat que personne n'a converge.
ROLES="$(prov_roles)"
ACCOUNTS="$ROLES $PROV_SYSTEM_ACCOUNT"

# La forme se teste ICI, pas chez l'appelant : `curl` accepte un « host:port » nu et lui prefixe
# `http://`, alors que le runtime concatene `base_url` verbatim (Fleet.Forge.Client.Transport) et
# refuse. Une sonde plus tolerante que son consommateur rend un vert faux.
forge_reachable() {   # 0 joignable · 1 forme invalide · 2 injoignable
  [[ "$PROV_FORGE_URL" == http://* || "$PROV_FORGE_URL" == https://* ]] || return 1
  curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/version" 2>/dev/null || return 2
}

# ⚠ LE CODE HTTP NE DISCRIMINE RIEN — mesuré le 2026-08-12 sur Gitea 1.26.1, les deux états rendent
# `GET /user/sign_up` -> 200. La page, elle, diffère : ouverte, elle porte le FORMULAIRE ; fermée,
# elle porte « Registration is disabled ». On teste donc la présence du champ `user_name`, et pas le
# texte : un marqueur structurel survit à la locale de l'instance, un message traduit non.
# (Le POST discrimine aussi — 303 contre 403 — mais il CRÉE un compte quand ça marche : une sonde
# ne laisse pas de trace derrière elle.)
probe_registration() {
  local page
  page="$(curl -fsS -m 10 "$PROV_FORGE_URL/user/sign_up" 2>/dev/null || true)"
  if [[ -z "$page" ]]; then
    p_warn "page d'inscription non lisible ($PROV_FORGE_URL/user/sign_up) — l'ouverture de l'inscription N'EST PAS mesurée"
  elif [[ "$page" == *'name="user_name"'* ]]; then
    p_ok "inscription OUVERTE — une personne peut créer son compte, puis un propriétaire d'org l'ajoute à « humans »"
  else
    p_drift "inscription FERMÉE sur cette forge — l'enrollment ne peut pas fonctionner : personne ne peut créer son compte. C'est un réglage d'instance (DISABLE_REGISTRATION dans app.ini), à ouvrir par l'opérateur de la forge"
  fi
}

# La sonde n'a besoin d'AUCUN jeton : `GET /users/<login>` expose `restricted` en anonyme (mesuré).
# C'est ce qui la rend jouable au même rang que `probe_registration`, avant tout mint.
probe_restricted() { # $1=login à sonder
  local login="$1" body
  [[ -n "$login" ]] || return 0
  body="$(curl -fsS -m 10 "$PROV_FORGE_URL/api/v1/users/$login" 2>/dev/null || true)"
  # ⚠ `has()` ET PAS `//` : l'opérateur `//` de jq traite `false` comme absent, donc un compte
  # correctement NON restreint serait lu « non mesurable » et la sonde se tairait là où elle doit
  # dire OK. Même piège que `forge_is_admin` dans human-converger.sh, même correctif.
  case "$(printf '%s' "$body" | jq -r 'if has("restricted") then .restricted else "?" end' 2>/dev/null)" in
    false) p_ok "compte $login non restreint — il voit les orgs des catalogues installés" ;;
    true)  p_drift "compte $login RESTREINT sur la forge — il ne verra AUCUNE org de catalogue dont il n'est pas membre (404 connecté, 200 en anonyme). C'est un réglage d'instance (DEFAULT_USER_IS_RESTRICTED dans app.ini) + le drapeau du compte : geste admin « Site Administration → Users → $login → décocher Restricted »" ;;
    *)     p_warn "drapeau restricted de $login non lisible ($PROV_FORGE_URL/api/v1/users/$login) — la visibilité des catalogues N'EST PAS mesurée" ;;
  esac
}

account_exists() { # $1=login — endpoint public en lecture (pas besoin d'admin pour SONDER)
  curl -fsS -m 10 -o /dev/null "$PROV_FORGE_URL/api/v1/users/$1" 2>/dev/null
}

missing_accounts() { # → la liste des comptes absents (vide = structure complète)
  local acct absents=""
  for acct in $ACCOUNTS; do
    account_exists "$acct" || absents="$absents $acct"
  done
  printf '%s' "${absents# }"
}

check_master_authority() {
  if [[ -r "$PROV_MASTER_TOKEN_FILE" ]]; then
    p_ok "autorité de création présente ($PROV_MASTER_TOKEN_FILE) — un catalogue de plus s'enrôle sans geste d'opérateur"
  else
    p_warn "pas d'autorité de création ($PROV_MASTER_TOKEN_FILE) — la boîte tourne, mais tout geste STRUCTUREL (enrôler un catalogue, ajouter un rôle) redevient manuel : « fleet/deploy/box config » la pose"
  fi
}

converge_authority_modes() {
  local f cur want="$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER"

  for f in "$PROV_MASTER_TOKEN_FILE" "$PROV_FORGE_SEED_FILE"; do
    [[ -f "$f" ]] || continue
    cur="$(stat -c '%a %U:%G' "$f")"
    if [[ "$cur" != "600 $want" ]]; then
      if [[ "$PROV_MODE" == "check" ]]; then
        p_drift "$f est $cur — attendu 600 $want (aucun process d'humain ne doit pouvoir le lire)"
      else
        if chown "$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" "$f" && chmod 0600 "$f"; then
          p_chg "$f -> 0600 $want (seul le service d'autorite l'ouvre)"
        else
          p_fail "$f : mode non convergé"
        fi
      fi
    else
      [[ "$PROV_MODE" == "check" ]] && p_ok "$f (0600 $want)"
    fi
  done

  return 0
}

a4_check() {
  "$A4_SCRIPT" --forge "$PROV_FORGE_URL" --tokens-dir "$PROV_TOKENS_DIR" \
    --roles "$ROLES" --extra-token "$PROV_SYSTEM_ACCOUNT:$(basename "$PROV_SYSTEM_TOKEN_FILE")" --check >/dev/null 2>&1
}

# Le handoff tofu→A4, convergent PAR ENTRÉE : chaque compte de $ACCOUNTS a son entrée dans le
# passwords-file. Fichier absent → dérivé entier depuis le seed ; rôle AJOUTÉ après bootstrap →
# entrée manquante complétée depuis le seed (l'ajout de rôle converge dans le cycle — la
# dérivation fichier-entier ratait ce cas, attrapé au premier ajout réel : scoper). Les entrées
# existantes ne sont JAMAIS réécrites (un password tourné à la main reste sien).
ensure_passwords_entries() {
  local acct absents=()
  for acct in $ACCOUNTS; do
    if ! { [[ -r "$PROV_PASSWORDS_FILE" ]] && jq -e --arg a "$acct" 'has($a)' "$PROV_PASSWORDS_FILE" >/dev/null 2>&1; }; then
      absents+=("$acct")
    fi
  done
  [[ "${#absents[@]}" -eq 0 ]] && return 0
  if [[ ! -r "$PROV_FORGE_SEED_FILE" ]]; then
    p_drift "entrées passwords manquantes (${absents[*]}) et pas de seed ($PROV_FORGE_SEED_FILE) — « FORGE_SEED_PASSWORD=<seed> fleet/deploy/box config » le pose (ou complète $PROV_PASSWORDS_FILE), puis relance"
    return 1
  fi
  local seed tmp rc=0
  seed="$(read_token "$PROV_FORGE_SEED_FILE")"
  [[ -n "$seed" ]] || { p_fail "seed vide : $PROV_FORGE_SEED_FILE"; return 1; }
  tmp="$(mktemp "${TMPDIR:-/tmp}/prov-pwd.XXXXXX")" || { p_fail "tmp passwords-file"; return 1; }
  if ! { if [[ -r "$PROV_PASSWORDS_FILE" ]]; then cat "$PROV_PASSWORDS_FILE"; else printf '{}'; fi; } \
      | jq --arg s "$seed" '. + ($ARGS.positional | map({(.): $s}) | add)' --args "${absents[@]}" > "$tmp"; then
    rm -f "$tmp"; p_fail "complétion jq du passwords-file"; return 1
  fi
  write_atomic "$PROV_PASSWORDS_FILE" 0600 root:root < "$tmp" || rc=1
  rm -f "$tmp"
  [[ "$rc" -eq 0 ]] || return 1
  p_ok "passwords-file complété depuis le seed (entrées : ${absents[*]})"
}

# Sémantique MESURÉE sur Gitea 1.26.4 : publicize est SELF-ONLY (le token système sur autrui : 403,
# même avec write:organization ; sur lui-même : 204) et un token de rôle au scope minimal A4
# (write:repository,write:issue) répond 403 même sur soi. La seule voie est donc la basic-auth DU
# COMPTE — c'est pourquoi le geste vit là où le seed est en main, pas ici.
forge_code() { # $1=chemin d'API → code HTTP, sous le jeton système s'il existe
  forge_curl "$PROV_SYSTEM_TOKEN_FILE" -s -o /dev/null -w '%{http_code}' -m 10 \
        "$PROV_FORGE_URL/api/v1$1" 2>/dev/null || true
}

# TROIS états, pas deux — et c'est tout le correctif. `public_members/<u>` rend 404 aussi bien pour
# un membre qui se cache que pour quelqu'un qui n'est PAS membre (mesuré : `chief` membre caché 404,
# `nonmember` 404). Les traiter pareil produisait une consigne inapplicable — « rends ton adhésion
# publique » à qui n'en a pas — et masquait le défaut inverse : un compte avec un jeton et aucune
# team, qui est exactement ce que `chief` a été jusqu'au 2026-08-10. `members/<u>` les sépare (204
# membre / 404 non-membre) et c'est la sonde qui manquait.
member_state() { # $1=compte → visible | hidden | absent | unknown
  [[ -r "$PROV_SYSTEM_TOKEN_FILE" ]] || { printf 'unknown'; return; }
  [[ "$(forge_code "/orgs/$PROV_FORGE_ORG/members/$1")" == "204" ]] || { printf 'absent'; return; }
  if [[ "$(forge_code "/orgs/$PROV_FORGE_ORG/public_members/$1")" == "204" ]]; then
    printf 'visible'
  else
    printf 'hidden'
  fi
}

members_in_state() { # $1=état recherché, $2=liste → sous-liste
  local acct out=""
  for acct in $2; do [[ "$(member_state "$acct")" == "$1" ]] && out="$out $acct"; done
  printf '%s' "${out# }"
}

members_hidden() { members_in_state hidden "$1"; }

# Elle sonde donc le ROSTER SYSTÈME seul : `$PROV_ROLES` est le plancher (avant que `prov_roles` n'y
# ajoute les catalogues), et c'est exactement la population de l'org système. La visibilité d'une org
# de catalogue est posée par `catalogue install`, dans le geste qui crée ses comptes.
check_members_visible() {
  local hidden absent unknown org_accounts="$PROV_ROLES $PROV_SYSTEM_ACCOUNT"
  unknown="$(members_in_state unknown "$org_accounts")"
  if [[ -n "$unknown" ]]; then
    p_drift "adhésions org NON SONDABLES (jeton système absent : $PROV_SYSTEM_TOKEN_FILE) — l'apply le minte dès que le seed est posé ; rien n'est conclu sur les comptes en attendant"
    return 0
  fi

  absent="$(members_in_state absent "$org_accounts")"
  hidden="$(members_hidden "$org_accounts")"

  # shellcheck disable=SC2086 # liste separee par des espaces, l'eclatement EST le rendu
  [[ -n "$absent" ]] && p_drift \
    "comptes SANS adhésion à l'org :$(printf ' %s' $absent) — jeton valide, zéro droit d'écriture. La recette ne les place dans aucune team (vérifier les listes writers/judges/externals)"

  if [[ -z "$hidden" ]]; then
    p_ok "adhésions org visibles (comptes machine)"
  else
    # shellcheck disable=SC2086 # meme liste, meme rendu
    p_drift "adhésions org PRIVÉES :$(printf ' %s' $hidden) — invisibles aux non-membres, donc un humain ne voit pas quels workers travaillent ici. Le geste qui les pose est « fleet/deploy/box forge-apply » (il les publicise juste après la structure)"
  fi

  if account_exists "$PROV_HUMAN"; then
    case "$(member_state "$PROV_HUMAN")" in
      hidden) p_drift "adhésion org de $PROV_HUMAN privée — geste utilisateur : profil forge → Organizations → $PROV_FORGE_ORG → visible (ou PUT public_members avec SES credentials)" ;;
      absent) p_drift "$PROV_HUMAN n'est membre d'aucune team de $PROV_FORGE_ORG — il ne verra pas les dépôts de l'org (team humans, lecture)" ;;
    esac
  fi
}


# ⚠ ON NE COMPARE PAS LES LABELS ICI, ET C'EST DELIBERE. « Un runner existe mais ne sert pas le label
# demande » est l'autre moitie du probleme (mesure du 2026-08-21 : un job `ubuntu-latest` sur une
# forge dont le seul runner servait `shell,elixir,dood`). Elle se mesure au TICKET et pas au boot :
# `CiGate` escalade en cinq minutes en NOMMANT le label que le job demande. Poser ici une liste de
# labels attendus en ferait une TROISIEME copie — le gabarit livre la porte deja, les defauts de
# `forge-runner.sh` aussi — et c'est exactement la forme qui derive.
check_ci_runner() {
  local body n labels
  [[ -r "$PROV_MASTER_TOKEN_FILE" ]] || {
    p_warn "runners CI non sondables (jeton master absent : $PROV_MASTER_TOKEN_FILE) — rien n'est conclu"
    return 0
  }
  body="$(forge_curl "$PROV_MASTER_TOKEN_FILE" -fsS -m 10 "$PROV_FORGE_URL/api/v1/admin/actions/runners" 2>/dev/null || true)"

  [[ -n "$body" ]] || {
    p_warn "runners CI non sondables (l'API admin n'a pas repondu — portee du jeton master ?) — rien n'est conclu"
    return 0
  }

  n="$(printf '%s' "$body" | jq -r '.total_count // 0' 2>/dev/null || echo 0)"
  if [[ "${n:-0}" -eq 0 ]]; then
    p_drift "AUCUN runner CI enregistre sur cette forge — tout job reste en attente, aucune PR ne fusionne, et le rail de livraison est mort avant son premier ticket. \`49-forge-runner\` l'enrole : rejoue l'apply, sa sortie dira ce qui a bloque"
  else
    labels="$(printf '%s' "$body" \
      | jq -r '[.runners[]? | .name + " [" + ([.labels[]?.name] | join(",")) + "]"] | join(" · ")' 2>/dev/null || true)"
    p_ok "$n runner(s) CI : ${labels:-labels illisibles}"
  fi
}

check() {
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_drift "FORGE_BASE_URL/PROV_FORGE_URL non posé — l'état-cible inclut une forge (pose-le via --env ou l'environnement)"
    verdict_check
  fi
  _rc=0; forge_reachable || _rc=$?   # errexit : le code se recolte par `||`, jamais en nu
  case "$_rc" in
    1) p_drift "FORGE_BASE_URL=« $PROV_FORGE_URL » sans schéma — attendu : http://<hôte>:<port>"
       verdict_check ;;
    2) p_drift "forge injoignable : $PROV_FORGE_URL/api/v1/version"
       verdict_check ;;
  esac
  p_ok "forge joignable ($PROV_FORGE_URL)"
  check_ci_runner
  probe_registration
  probe_restricted "$PROV_HUMAN"
  check_master_authority
  PROV_MODE=check converge_authority_modes

  local miss acct
  miss="$(missing_accounts)"
  if [[ -n "$miss" ]]; then
    p_drift "structure absente (comptes : $miss) — territoire OpenTofu : « fleet/deploy/box forge-apply » la pose (tofu est DANS l'image ; « forge-check » enonce le contrat)"
  else
    for acct in $ACCOUNTS; do p_ok "compte $acct"; done
  fi

  if [[ -x "$A4_SCRIPT" ]]; then
    if a4_check; then
      p_ok "role-tokens valides (sonde A4 --check)"
    else
      p_drift "role-tokens absents/invalides (sonde A4 --check) — l'apply les re-mint"
    fi
  else
    p_fail "script A4 introuvable/inexécutable : $A4_SCRIPT (checkout incomplet ?)"
  fi

  check_human_onboardable
  check_members_visible
  verdict_check
}

# L'HUMAIN sur la forge — ce que le runtime exige à l'onboarding d'un projet, sondé ICI plutôt
# que découvert par un pod au milieu d'un create_project ({:human_not_provisioned, …} puis
# {:human_team_unverifiable, …}, vécus au premier E2E docker). L'appartenance se sonde au
# niveau ORG (204/404, lisible par le token système) et non au niveau TEAM : `GET
# /teams/<id>/members/<u>` est 403 pour lui — Gitea réserve la lecture d'une team à ses membres
# et aux owners, et le système n'est NI l'un NI l'autre (choix forge.tf, blast-radius borné).
check_human_onboardable() {
  local tokfile="$PROV_SYSTEM_TOKEN_FILE" code
  if ! account_exists "$PROV_HUMAN"; then
    p_drift "compte forge absent pour l'humain « $PROV_HUMAN » — l'onboarding projet échouera (human_not_provisioned) : LCARS_HUMAN=$PROV_HUMAN … « fleet/deploy/box forge-apply »"
    return 0
  fi
  p_ok "compte forge de l'humain ($PROV_HUMAN)"
  [[ -r "$tokfile" ]] || { p_drift "token système illisible ($tokfile) — appartenance de $PROV_HUMAN à l'org $PROV_FORGE_ORG non sondable"; return 0; }
  code="$(forge_curl "$tokfile" -s -o /dev/null -w '%{http_code}' -m 10 "$PROV_FORGE_URL/api/v1/orgs/$PROV_FORGE_ORG/members/$PROV_HUMAN" 2>/dev/null || true)"
  case "$code" in
    204) p_ok "$PROV_HUMAN membre de l'org $PROV_FORGE_ORG (sonde du token système)" ;;
    404) p_drift "$PROV_HUMAN N'EST PAS membre de l'org $PROV_FORGE_ORG — l'onboarding projet le refusera ; il entre dans la team humans par « fleet/deploy/box forge-apply »" ;;
    *)   p_drift "appartenance de $PROV_HUMAN à l'org $PROV_FORGE_ORG non vérifiable (HTTP $code) — scope du token système ?" ;;
  esac
}

apply() {
  if [[ -z "$PROV_FORGE_URL" ]]; then
    p_drift "FORGE_BASE_URL/PROV_FORGE_URL non posé — comptes/tokens forge non convergés (pose-le et relance)"
    verdict_apply
  fi
  _rc=0; forge_reachable || _rc=$?   # errexit : le code se recolte par `||`, jamais en nu
  case "$_rc" in
    1) p_drift "FORGE_BASE_URL=« $PROV_FORGE_URL » sans schéma — attendu : http://<hôte>:<port> ; tokens non convergés"
       verdict_apply ;;
    2) p_drift "forge injoignable : $PROV_FORGE_URL — tokens non convergés (relance quand elle répond)"
       verdict_apply ;;
  esac

  # DANS L'APPLY : le boot joue `provision apply` (entrypoint.sh), jamais `check`. Une sonde qui ne
  # vivrait que dans le check ne parlerait a personne au demarrage, c'est-a-dire au seul moment ou
  # l'operateur peut encore enroler un runner AVANT que la fleet ne depense un producteur.
  #
  # TOT : posee en fin d'apply, elle n'etait atteinte que si tout le reste convergeait — la
  # structure absente sort par `verdict_apply` bien avant. On n'aurait donc appris l'absence de
  # runner que sur une boite deja parfaite par ailleurs, ce qui est l'inverse du besoin : une boite
  # qui derive AUSSI ailleurs a exactement le meme rail de livraison mort.
  check_ci_runner
  [[ -x "$A4_SCRIPT" ]] || { p_fail "script A4 introuvable : $A4_SCRIPT"; verdict_apply; }
  check_master_authority
  PROV_MODE=apply converge_authority_modes

  local miss
  miss="$(missing_accounts)"
  if [[ -n "$miss" ]]; then
    p_drift "structure absente (comptes : $miss) — « fleet/deploy/box forge-apply » la pose (il faut le token master + le seed ; « forge-check » enonce le contrat)"
    verdict_apply
  fi

  if a4_check; then
    p_ok "role-tokens déjà valides ($PROV_TOKENS_DIR)"
    verdict_apply
  fi
  ensure_passwords_entries || verdict_apply
  if "$A4_SCRIPT" --forge "$PROV_FORGE_URL" --tokens-dir "$PROV_TOKENS_DIR" \
      --passwords-file "$PROV_PASSWORDS_FILE" --owner "$PROV_AUTHORITY_USER" \
      ${PROV_MASTER_TOKEN_FILE:+--master-token-file "$PROV_MASTER_TOKEN_FILE"} \
      --roles "$ROLES" --extra-token "$PROV_SYSTEM_ACCOUNT:$(basename "$PROV_SYSTEM_TOKEN_FILE")"; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "tokens A4 posés ($PROV_TOKENS_DIR)"
  else
    p_fail "provision-role-tokens.sh en échec (son verdict est au-dessus)"
  fi
  verdict_apply
}

case "${1:?usage: 50-forge.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
