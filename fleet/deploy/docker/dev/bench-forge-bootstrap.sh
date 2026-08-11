#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/dev/bench-forge-bootstrap.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-02
# STATUS: geste de BANC — amene une forge jetable NEUVE a l'etat "la fleet peut travailler dessus"
#
# ─── POURQUOI CE FICHIER EXISTE ─────────────────────────────────────────────────────────────────
# Le concept du banc est « on nuke et on recommence ». Chaque nuke detruit la forge, ses comptes,
# ses tokens et le mot de passe de l'humain — et jusqu'ici la sequence qui remonte tout ca vivait
# dans la MEMOIRE de la session qui l'avait faite. Mesure du 2026-08-02 : apres un redeploy propre,
# l'humain ne pouvait plus se loguer, parce que le mot de passe de banc n'etait ecrit nulle part.
# Une recette qu'on retient de tete est une recette qu'on perd au prochain nuke. Celle-ci est ici.
#
# ⚠ IDEMPOTENT A UNE CONDITION, ET ELLE N'ETAIT PAS ECRITE (mesure du 2026-08-03, en composant ce
# script deux fois de suite depuis bench-up.sh) : sans `--tofu-dir`, l'etape 4 se copie la recette
# dans un mktemp NEUF a chaque passe, donc avec un tfstate VIDE — tofu croit devoir creer une org,
# des teams et dix comptes qui existent deja, et l'apply meurt en 409. Chaque etape prise seule est
# idempotente ; l'ENCHAINEMENT ne l'est que si l'etat de tofu survit d'une passe a l'autre. Donner
# un `--tofu-dir` stable est donc obligatoire des qu'on joue ce script plus d'une fois sur la meme
# forge. Le defaut mktemp reste correct pour l'usage d'origine : UNE passe sur une forge NEUVE.
#
# Ce que le script fait, dans l'ordre :
#   1. attend que la forge reponde ;
#   2. cree le compte admin de bootstrap s'il manque (mot de passe genere, jamais fixe) ;
#   3. minte le master token EPHEMERE du bootstrap (celui que tofu consomme) ;
#   4. joue DEUX `tofu apply` sur la recette de prod : le module `instance/` (systeme, starfleet,
#      humain, roles `system_*` — une fois par FORGE) puis le module catalogue (org, teams, comptes
#      de role metier, adhesions — une fois par CATALOGUE). Deux etats distincts : meler les deux
#      rendrait les comptes partages propriete du premier catalogue enrole ;
#   5. pose le seed dans la boite pour que le mint A4 des role-tokens converge au prochain boot ;
#   6. pose le mot de passe de BANC de l'humain, le promeut SITE-ADMIN (banc seulement, etape
#      6-bis, OPT-IN via --human-admin), pose son TOKEN operateur, et cable le token
#      systeme dans son fleet_v2.env (cf. les deux blocs ci-dessous) ;
#   7. pose les avatars de charte (le scribe en a un depuis le 2026-08-02) ;
#   8. SEME la forge : `fleet/lcars` (la source que la boite clone) + `fleet/project-template`
#      (le modele que create_project genere). Une forge vierge sans ces deux repos donne une
#      boite qui ne peut ni se mettre a jour ni onboarder un projet — mesure au drill du soir ;
#   9. rend un verdict MESURE : login humain, comptes de l'org, repos semes.
#
# ─── LE MOT DE PASSE DE BANC DU COMPTE OPERATEUR ────────────────────────────────────────────────
# Ce bloc disait que la recette pose `must_change_password = true` et que « c'est correct ». Ca ne
# l'etait pas : ce compte n'est pas une personne. Il tient ICI la place du compte admin que Gitea
# fait creer a son INSTALLATION — celui que l'operateur pose quand il prepare la forge. Le reglage
# attendait donc un premier login que personne ne fait, et il fermait le compte en attendant. La
# recette pose desormais `false` (arbitrage user 2026-08-11), donc ce script ne se bat plus contre
# elle.
# Ce qui reste, et qui EST une propriete du banc : un mot de passe CONNU, pour qu'on puisse ouvrir
# l'UI d'une forge jetable sans aller le chercher. Rien dans `provisioning/` ni dans le runtime ne
# lit cette valeur.
#
# ─── LE TOKEN OPERATEUR ET LE CABLAGE ENV — MEME NATURE, MEME RAISON ────────────────────────────
# Corollaire du mot de passe : en PRODUCTION la forge preexiste et Gitea regle l'identite de
# l'humain a son propre onboarding ; le token operateur est un geste d'identite que la recette
# n'automatise pas (70-human le SONDE et l'INSTRUIT, il ne le pose jamais). Sur un banc, cette
# identite nait et meurt avec la forge, plusieurs fois par jour — le geste est donc ici.
#
# Le cablage env vient du meme ordre de cold boot, et la boite le NOMME deja (70-human, cas D4) :
# le premier boot seed `fleet_v2.env` AVANT que la forge soit bootstrappee, donc sans
# `FORGE_TOKEN_FILE` ; ensuite le fichier appartient a l'humain et n'est PLUS jamais reecrit. Sans
# ces deux lignes le runtime retombe sur `~/.gitea_token` (le token de l'HUMAIN), et la creation de
# projet echoue — soit en enoent, soit, pire, en 403 : la team `humans` a `can_create_repos =
# false`, seul le compte SYSTEME cree des repos d'org (forge.tf). Un banc qui pose le token humain
# sans cabler le systeme troque une panne claire contre une panne qui ressemble a un droit manquant.
#
# USAGE : bench-forge-bootstrap.sh [--forge-url http://127.0.0.1:3600] [--container lcars-ticketforge-forge-1]
#                                  [--box lcars-ticket-lcars-1] [--human lcars] [--human-password toto32toto32]
#                                  [--tofu-dir <copie de fleet/deploy/deps>] [--no-box] [--no-seed-repos]
#                                  [--human-admin] [--admin-token TOK]
# EXIT  : 0 forge prete · 1 arguments/dependance · 2 la forge ne repond pas · 3 bootstrap admin/token
#         4 tofu · 5 la boite (seed) · 6 le verdict final ne passe pas · 7 semis des repos

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

FORGE_URL="http://127.0.0.1:3600"
CONTAINER="lcars-ticketforge-forge-1"
# `--admin-token` DIT UNE SEULE CHOSE, et elle commande tout le reste : « la forge preexiste et je
# n'en suis pas l'administrateur, je suis un client qui detient un jeton » — le cas de la PRODUCTION.
# Sans lui, la forge est a moi et je la fabrique : le cas du BANC.
# Ce n'est PAS un `--mode prod|test`. Une etiquette de mode peut etre FAUSSE (un `--mode prod` sur
# une forge vierge echoue tard, et accuse la forge) ; un jeton existe ou n'existe pas. On mesure.
ADMIN_TOKEN=""
BOX="lcars-ticket-lcars-1"
HUMAN="lcars"
HUMAN_EMAIL="lcars@lcars.local"
# Convention de banc — cf. le bloc d'en-tete. Jamais lue par la prod.
HUMAN_PASSWORD="toto32toto32"
TOFU_DIR=""
WITH_BOX=1
SEED_REPOS=1
# Propriete de BANC, jamais de prod — la raison, son cout et sa sortie sont a l'etape 6-bis.
HUMAN_ADMIN=0
DOCKER_BIN="${DOCKER_BIN:-docker}"
ADMIN="bootstrap"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge-url)      FORGE_URL="${2:?}"; shift 2 ;;
    --container)      CONTAINER="${2:?}"; shift 2 ;;
    --admin-token)    ADMIN_TOKEN="${2:?}"; shift 2 ;;
    --box)            BOX="${2:?}"; shift 2 ;;
    --human)          HUMAN="${2:?}"; shift 2 ;;
    --human-email)    HUMAN_EMAIL="${2:?}"; shift 2 ;;
    --human-password) HUMAN_PASSWORD="${2:?}"; shift 2 ;;
    --tofu-dir)       TOFU_DIR="${2:?}"; shift 2 ;;
    --no-box)         WITH_BOX=0; shift ;;
    --no-seed-repos)  SEED_REPOS=0; shift ;;
    --human-admin)    HUMAN_ADMIN=1; shift ;;
    # Accepte et SANS EFFET : c'etait le defaut avant l'inversion du 2026-08-07. Le refuser ferait
    # echouer un appelant qui demande deja le comportement devenu defaut.
    --no-human-admin) HUMAN_ADMIN=0; shift ;;
    -h|--help)        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-forge-bootstrap: option inconnue: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '[bench-forge] %s\n' "$*"; }
die()  { printf '[bench-forge] %s\n' "$*" >&2; exit "${2:-1}"; }
api()  { printf '%s/api/v1' "$FORGE_URL"; }

command -v curl >/dev/null || die "curl requis"
command -v tofu >/dev/null || die "tofu requis"
command -v python3 >/dev/null || die "python3 requis (lecture des reponses JSON)"

# ─── 1. la forge repond ──────────────────────────────────────────────────────────────────────────
say "attente de la forge : $FORGE_URL"
for _ in $(seq 1 60); do
  curl -sf -m 3 "$(api)/version" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf -m 3 "$(api)/version" >/dev/null 2>&1 || die "la forge ne repond pas: $FORGE_URL" 2

# ─── 2-3. admin de bootstrap + master token EPHEMERE ─────────────────────────────────────────────
# Le mot de passe admin est GENERE : personne n'a besoin de s'en souvenir (le compte est un outil
# de provisioning, pas un siege d'operateur), et un mot de passe admin fixe dans un fichier suivi
# serait la seule faiblesse reelle que ce script pourrait introduire.
ADMIN_PW="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"

# LE JETON FOURNI COURT-CIRCUITE 2 ET 3, et ce n'est pas une optimisation : ce sont les SEULES
# etapes qui exigent un `docker exec` DANS la forge. Contre une forge de production — ailleurs, pas
# a nous, peut-etre meme pas en conteneur — elles ne sont pas inutiles, elles sont IMPOSSIBLES.
if [[ -n "$ADMIN_TOKEN" ]]; then
  MASTER_TOKEN="$ADMIN_TOKEN"
  curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/user" >/dev/null \
    || die "le jeton d'admin fourni ne s'authentifie pas sur $FORGE_URL" 3
  say "admin fourni (--admin-token) — creation et mint SAUTES, la forge preexiste"
elif ! curl -sf -m 5 "$(api)/users/$ADMIN" >/dev/null 2>&1; then
  say "creation du compte admin de bootstrap ($ADMIN)"
  "$DOCKER_BIN" exec -u git "$CONTAINER" gitea admin user create \
      --username "$ADMIN" --password "$ADMIN_PW" --email "b@local.test" \
      --admin --must-change-password=false >/dev/null 2>&1 \
    || die "creation de l'admin de bootstrap impossible" 3
else
  say "admin de bootstrap deja present — rotation de son mot de passe pour cette passe"
  "$DOCKER_BIN" exec -u git "$CONTAINER" gitea admin user change-password \
      --username "$ADMIN" --password "$ADMIN_PW" --must-change-password=false >/dev/null 2>&1 \
    || die "rotation du mot de passe admin impossible" 3
fi

# Un token du meme nom peut survivre a une passe precedente : on en minte un HORODATE plutot que
# de gerer une revocation (le compte entier meurt au prochain nuke).
if [[ -z "$ADMIN_TOKEN" ]]; then
  TOKEN_NAME="bench-tofu-$(date +%s)"
  MASTER_TOKEN="$("$DOCKER_BIN" exec -u git "$CONTAINER" gitea admin user generate-access-token \
                    --username "$ADMIN" --token-name "$TOKEN_NAME" --scopes all --raw 2>/dev/null | tail -1)"
  [[ -n "$MASTER_TOKEN" ]] || die "la forge n'a pas rendu de master token" 3
  curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/user" >/dev/null \
    || die "le master token ne s'authentifie pas" 3
  say "master token minte ($TOKEN_NAME)"
fi

# LE MASTER TOKEN SURVIT A CE SCRIPT, et il n'a nulle part d'autre ou vivre. `bench-up.sh` en a
# besoin APRES nous, pour minter le jeton d'enregistrement du runner — un geste qui exige un
# site-admin et qui ne peut pas se faire avant que la forge existe. Il est ecrit dans le tofu-dir
# parce que c'est deja le seul endroit hors de l'arbre suivi ou l'etat de cette passe survit (le
# tfstate y vit pour la meme raison), et en 0600 parce que c'en est un.
if [[ -n "$TOFU_DIR" ]]; then
  printf '%s\n' "$MASTER_TOKEN" > "$TOFU_DIR/.master-token"
  chmod 600 "$TOFU_DIR/.master-token"
fi

# ─── 4. tofu apply — la recette de PROD, en DEUX modules (instance puis catalogue) ───────────────
# Copie de travail par defaut : la recette est jouee hors de l'arbre suivi pour que son tfstate (qui
# porte des valeurs sensibles) ne se retrouve jamais dans un `git status`.
if [[ -z "$TOFU_DIR" ]]; then
  TOFU_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench-tofu.XXXXXX")"
  cp -r "$REPO_ROOT/fleet/deploy/deps/." "$TOFU_DIR/"
  say "recette tofu copiee dans $TOFU_DIR (tfstate hors de l'arbre)"
fi
# Le module INSTANCE a son propre etat : ce qu'il possede (systeme, starfleet, humain, roles
# `system_*`) vit une fois par FORGE, pas une fois par catalogue. Le meler a l'etat d'un catalogue
# rendrait ces comptes propriete du premier enrole — les detruire en detruisant celui-la.
INSTANCE_DIR="${TOFU_DIR%/}.instance"
rm -rf "$TOFU_DIR/instance"
mkdir -p "$INSTANCE_DIR"
cp -r "$REPO_ROOT/fleet/deploy/deps/instance/." "$INSTANCE_DIR/"

# The roster is DERIVED from the catalogue, never taken from the recipe defaults. Those defaults are
# a second writing of a fact `mix lcars.catalogue.roles --tfvars` already produces, and the two DID
# drift: `chief` sat in `roles` and not in `writers`, so it got an account and a token and no write
# right anywhere -- found by reading the org on a bench, not by any check. Deriving here removes the
# second list from the bench's path instead of keeping it correct by hand.
#
# Fail-closed on purpose: this script already needs the source tree (it copies the recipe from it),
# so it needs `mix` too. A bench provisioned from stale defaults would be a bench that does not
# prove what it claims to prove.
ENROLL_OUT="$("$REPO_ROOT/fleet/etc/enroll-catalogue.sh" \
                --catalogue "$REPO_ROOT/fleet/priv/catalogue" \
                --tofu-dir "$TOFU_DIR" \
                --repo "$REPO_ROOT/fleet" 2>/dev/null)" \
  || die "derivation du roster en echec (enroll-catalogue.sh) -- recette non enrolee" 4
ROSTER_LINE="$(printf '%s\n' "$ENROLL_OUT" | grep '^PROV_ROLES=')"
# L'ORG vient du CATALOGUE, comme le roster : elle porte son nom. tofu la lit seul dans
# roles.auto.tfvars.json ; ici c'est le shell qui en a besoin — les sondes d'apres-apply tapent sur
# une org nommee, et viser la mauvaise rend des 404 muets.
ORG="$(printf '%s\n' "$ENROLL_OUT" | sed -n 's/^PROV_FORGE_ORG="\(.*\)"$/\1/p')"
ORG="${ORG:-fleet}"
say "roster derive du catalogue ${ROSTER_LINE#PROV_ROLES=}"
say "org du catalogue : $ORG"

SEED_PW="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"

export TF_VAR_gitea_url="$FORGE_URL" TF_VAR_gitea_token="$MASTER_TOKEN" \
       TF_VAR_seed_password="$SEED_PW" TF_VAR_human_username="$HUMAN" \
       TF_VAR_human_email="$HUMAN_EMAIL"

# INSTANCE d'abord, TOUJOURS : une adhesion peut nommer un compte qu'elle ne cree pas, mais pas un
# compte qui n'existe pas. L'inversion echoue en 404 cote Gitea — bruyamment, jamais en silence.
(
  cd "$INSTANCE_DIR"
  tofu init -no-color >/dev/null 2>&1 || exit 1
  tofu apply -auto-approve -no-color >/dev/null 2>&1 || exit 1
) || die "tofu apply INSTANCE en echec (rejoue-le a la main dans $INSTANCE_DIR pour voir sa sortie)" 4
say "comptes d'instance poses (systeme, starfleet, humain, roles system_*)"

(
  cd "$TOFU_DIR"
  tofu init -no-color >/dev/null 2>&1 || exit 1
  tofu apply -auto-approve -no-color >/dev/null 2>&1 || exit 1
) || die "tofu apply CATALOGUE en echec (rejoue-le a la main dans $TOFU_DIR pour voir sa sortie)" 4
say "structure du catalogue posee (org $ORG, teams, comptes de role metier, adhesions)"

# ─── 5. le seed dans la boite — le handoff tofu → A4 ─────────────────────────────────────────────
# Sans ce fichier, 50-forge ne peut pas minter les role-tokens et le DIT (drift) ; la fleet
# demarre alors sans identite de role, et les producteurs echouent en role_token_unavailable au
# moment de publier — la classe BL-6-34, vecue deux fois.
if [[ "$WITH_BOX" -eq 1 ]]; then
  printf '%s\n' "$SEED_PW" | "$DOCKER_BIN" exec -i "$BOX" bash -c \
      'mkdir -p /home/private && cat > /home/private/forge-seed.pass \
       && chmod 600 /home/private/forge-seed.pass && chown root:root /home/private/forge-seed.pass' \
    || die "seed non pose dans la boite ($BOX)" 5
  say "seed pose dans $BOX:/home/private/forge-seed.pass"
  say "→ relance la boite (docker restart $BOX) pour que 50-forge minte les role-tokens"
else
  printf '%s\n' "$SEED_PW" > "$HERE/.bench-seed.pass"
  chmod 600 "$HERE/.bench-seed.pass"
  say "boite non touchee (--no-box) — seed ecrit dans $HERE/.bench-seed.pass"
fi

# ─── 6. le mot de passe de banc de l'humain ──────────────────────────────────────────────────────
# APRES l'apply (tofu vient de (re)poser le seed sur ce compte).
#
# MEME PRECONDITION QUE 2-3, et pour la meme raison : fabriquer l'identite d'un humain suppose
# ADMINISTRER la forge. En production Gitea la regle a son propre onboarding, et `70-human` la SONDE
# sans jamais la poser — c'est ecrit en tete de ce fichier. Avec `--admin-token`, on est client :
# on ne touche pas au compte, et on le DIT plutot que de le sauter en silence.
if [[ -n "$ADMIN_TOKEN" ]]; then
  say "humain $HUMAN : identite NON fabriquee (--admin-token) — Gitea la regle a son onboarding"
else
"$DOCKER_BIN" exec -u git "$CONTAINER" gitea admin user change-password \
    --username "$HUMAN" --password "$HUMAN_PASSWORD" --must-change-password=false >/dev/null 2>&1 \
  || die "mot de passe de banc non pose pour $HUMAN" 6
say "humain $HUMAN : mot de passe de banc pose, changement force leve"
fi

# ─── 6-bis. SITE-ADMIN — OPT-IN depuis le 2026-08-07, et la polarite EST le sujet ────────────────
# C'etait un opt-out (`--no-human-admin`) : on obtenait donc un site-admin EN OUBLIANT UN FLAG. Une
# propriete qu'on obtient par omission n'est pas une propriete, c'est un accident — et celle-ci
# court-circuite la team `humans`. Le defaut est desormais le modele de PRODUCTION ; le banc demande
# explicitement (bench-up.sh passe --human-admin). Le pourquoi du banc reste entier, ci-dessous.
# Meme nature que le mot de passe ci-dessus, et meme frontiere. La recette de PRODUCTION ne rend
# JAMAIS le quotidien site-admin : `20-DECISION-premier-admin-prerequis-lcars-demo.md` le mesure —
# un daily-admin rend la team `humans` decorative, donc les droits qu'on croit tester ne sont plus
# testes par personne. Sur un banc jetable en loopback, l'inverse coute plus cher : l'operateur qui
# doit inspecter la forge (voir les comptes, purger un depot, debloquer un token) se retrouve
# bloque par un ecran d'admin auquel son seul compte n'a pas acces, plusieurs fois par jour.
# LE COUT EST REEL ET IL EST ICI : tant que ce flag est a 1, ce banc ne peut PAS servir a mesurer
# ce que la team `humans` autorise — elle est court-circuitee. Pour cette mesure-la : --no-human-admin.
# Gitea n'a pas de commande CLI de promotion ; c'est PATCH /admin/users/<u> avec le master token.
# `login_name` + `source_id` sont exiges par EditUserOption meme quand on ne touche qu'un booleen.
if [[ "$HUMAN_ADMIN" -eq 1 ]]; then
  curl -sf -m 10 -H "Authorization: token $MASTER_TOKEN" -H "Content-Type: application/json" \
      -X PATCH -d "{\"admin\":true,\"login_name\":\"$HUMAN\",\"source_id\":0}" \
      "$(api)/admin/users/$HUMAN" >/dev/null \
    || die "promotion site-admin de $HUMAN refusee par la forge" 6
  IS_ADMIN="$(curl -s -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/users/$HUMAN" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("is_admin"))' 2>/dev/null || echo "?")"
  [[ "$IS_ADMIN" == "True" ]] || die "promotion posee mais la forge repond is_admin=$IS_ADMIN" 6
  say "humain $HUMAN : SITE-ADMIN (propriete de banc, verifiee is_admin=True)"
else
  say "humain $HUMAN : non-admin (defaut) — modele de prod ; --human-admin pour un banc"
fi

# Token OPERATEUR de l'humain (~/.gitea_token) — mint par basic-auth avec le mot de passe de banc
# qu'on vient de poser. `read:organization` est LOAD-BEARING et non evident : sans lui le token
# rend 403 sur /orgs/.../members ET /teams/... — donc la sonde d'appartenance humaine (le
# prealable de tout onboarding projet) echoue en « NON VERIFIABLE » au lieu de repondre. Mesure
# le 2026-08-02 : minte sans ce scope, il a fait echouer un create_project UNE MARCHE plus loin
# que le token absent, avec un message qui ressemblait a un droit manquant cote forge.
# ON GARDE CE QUE LA FORGE A DIT, ET ON MEURT AVEC. La version d'avant jetait la reponse
# (`2>/dev/null || true`) puis affichait une cause DEVINEE — « un token du meme nom existe deja ? » —
# en `say`, pas en `die`. Mesure du 2026-08-07 : ce message est sorti sur une forge NEUVE, ou cette
# cause est impossible, et le banc a continue en s'annoncant pret. Deux defauts qui se composent :
# une hypothese presentee comme un diagnostic, et un maillon LOAD-BEARING dont l'absence ne stoppe
# rien. L'en-tete de ce bloc dit pourquoi il est load-bearing : sans `read:organization`, la sonde
# d'appartenance humaine echoue en « NON VERIFIABLE » et un create_project meurt UNE MARCHE plus
# loin, avec un message qui accuse la forge.
# Un nom horodate, comme le master token, pour la meme raison : un token survivant d'une passe
# precedente n'est plus une hypothese a formuler, c'est un cas qu'on ne peut plus rencontrer.
if [[ "$WITH_BOX" -eq 1 ]]; then
  OP_TOKEN_NAME="bench-operateur-$(date +%s)"
  OP_RESP="$(curl -s -m 10 -u "$HUMAN:$HUMAN_PASSWORD" -H "Content-Type: application/json" \
      -X POST -d "{\"name\":\"$OP_TOKEN_NAME\",\"scopes\":[\"write:repository\",\"write:issue\",\"read:organization\",\"read:user\"]}" \
      -w $'\n%{http_code}' "$(api)/users/$HUMAN/tokens" 2>&1 || true)"
  OP_CODE="$(printf '%s' "$OP_RESP" | tail -1)"
  OP_BODY="$(printf '%s' "$OP_RESP" | sed '$d')"
  HUMAN_TOKEN="$(printf '%s' "$OP_BODY" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("sha1",""))
except Exception: print("")' 2>/dev/null || true)"

  [[ -n "$HUMAN_TOKEN" ]] \
    || die "la forge a refuse le token operateur ($OP_TOKEN_NAME) — HTTP $OP_CODE : ${OP_BODY:-<corps vide>}" 6

  printf '%s\n' "$HUMAN_TOKEN" | "$DOCKER_BIN" exec -i -u "$HUMAN" "$BOX" bash -c \
      'cat > ~/.gitea_token && chmod 600 ~/.gitea_token' \
    || die "token operateur minte mais NON pose dans $BOX — la boite ne pourra pas parler a la forge" 6
  say "token operateur pose dans $BOX:~$HUMAN/.gitea_token ($OP_TOKEN_NAME)"

  # Les DEUX lignes que 70-human instruit (cas D4) : le runtime doit ecrire sur la forge avec le
  # compte SYSTEME, jamais avec celui de l'humain. Ajoutees seulement si absentes — apres le seed,
  # ce fichier appartient a l'humain.
  "$DOCKER_BIN" exec -u "$HUMAN" "$BOX" bash -c \
      'grep -q "^FORGE_TOKEN_FILE=" ~/.lcars/fleet_v2.env \
       || printf "FORGE_TOKEN_FILE=/home/private/system.gitea_token\nFORGE_BOT_LOGIN=lcars-system\n" >> ~/.lcars/fleet_v2.env' \
    && say "fleet_v2.env : token systeme cable (FORGE_TOKEN_FILE + FORGE_BOT_LOGIN)" \
    || say "fleet_v2.env NON cable — la creation de projet echouera (cf. l'en-tete)"
fi

# ─── 7. avatars de charte ────────────────────────────────────────────────────────────────────────
# Le mapping compte→fichier vit dans le script de la recette (DONNEE, pas cas special) — un role
# ajoute au catalogue sans sa ligne la garde une tete vide sur la forge (mesure : le scribe, le
# 2026-08-02, apres son rename).
if [[ -f "$TOFU_DIR/provision-forge-avatars.sh" ]]; then
  printf '%s\n' "$MASTER_TOKEN" > "$TOFU_DIR/.admin.token"
  chmod 600 "$TOFU_DIR/.admin.token"
  # La sortie du script est CAPTUREE, plus jetee. Elle etait envoyee a /dev/null derriere un
  # "non bloquant" : la seule ligne qui dit CE QUI a ete pose, et combien d'entrees de charte
  # n'avaient pas de compte sur cette forge, disparaissait. Un provisionnement qui couvre trois
  # entrees sur dix doit le montrer.
  avatar_out="$( cd "$TOFU_DIR" && ./provision-forge-avatars.sh --forge "$FORGE_URL" \
      --admin-token-file "$TOFU_DIR/.admin.token" 2>&1 )" \
    && say "avatars: ${avatar_out##*$'\n'}" \
    || say "avatars NON poses, les comptes gardent une tete vide : ${avatar_out##*$'\n'}"
  rm -f "$TOFU_DIR/.admin.token"
fi

# ─── 8. le semis : la source et le modele ────────────────────────────────────────────────────────
# `fleet/lcars` = la source que la boite clone au boot (LCARS_SOURCE_REMOTE, la jambe runtime du
# triangle). `fleet/project-template` = le modele que `create_project` genere (absent, l'onboard
# degrade en bare-create + scaffold local, LOUD). Une forge vierge sans les deux est une forge sur
# laquelle la fleet ne peut rien faire — et c'est l'etat par defaut apres chaque nuke.
if [[ "$SEED_REPOS" -eq 1 ]]; then
  SYS_TOKEN="$("$DOCKER_BIN" exec "$BOX" cat /home/private/system.gitea_token 2>/dev/null | tr -d '[:space:]' || true)"

  if [[ -z "$SYS_TOKEN" ]]; then
    say "token systeme absent de la boite — semis SAUTE (relance la boite puis rejoue ce script)"
  else
    curl -s -m 10 -X POST -H "Authorization: token $SYS_TOKEN" -H "Content-Type: application/json" \
      -d '{"name":"lcars","description":"LCARS — la source de la boite","private":false,"auto_init":false}' \
      "$(api)/orgs/$ORG/repos" >/dev/null 2>&1 || true

    LCARS_REMOTE="http://lcars-system:${SYS_TOKEN}@${FORGE_URL#http://}/fleet/lcars.git"
    git -C "$REPO_ROOT" push -q "$LCARS_REMOTE" main:main 2>/dev/null \
      && say "fleet/lcars : main pousse" || say "fleet/lcars : main NON pousse"

    WORK_TREE="${LCARS_WORK_TREE:-/home/projects.ops/LCARS/work}"
    [[ -d "$WORK_TREE/.git" ]] && { git -C "$WORK_TREE" push -q "$LCARS_REMOTE" ops:ops 2>/dev/null \
      && say "fleet/lcars : ops pousse" || say "fleet/lcars : ops NON pousse" ; }

    # Le modele passe par SA tache mix (contenu + flag template + labels protocole) — jamais un
    # push a la main : le contenu vient du catalogue, la tache est la seule a savoir l'assembler.
    printf '%s\n' "$SYS_TOKEN" > "$HERE/.bench-system.token"
    chmod 600 "$HERE/.bench-system.token"
    ( cd "$REPO_ROOT/fleet" && FORGE_BASE_URL="$FORGE_URL" \
        FORGE_TOKEN_FILE="$HERE/.bench-system.token" mix lcars.project_template.sync >/dev/null 2>&1 ) \
      && say "fleet/project-template : synchronise (contenu + flag + labels)" \
      || say "fleet/project-template : sync EN ECHEC (onboard degradera en bare-create)"
    rm -f "$HERE/.bench-system.token"
  fi
fi

# ─── 9. verdict MESURE ───────────────────────────────────────────────────────────────────────────
curl -sf -m 5 -u "$HUMAN:$HUMAN_PASSWORD" "$(api)/user" >/dev/null \
  || die "le login humain ne passe pas — la forge n'est PAS prete" 6

MEMBERS="$(curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/orgs/$ORG/members" \
           | python3 -c 'import json,sys; print(" ".join(sorted(u["login"] for u in json.load(sys.stdin))))')"
say "membres de l'org $ORG : $MEMBERS"

REPOS="$(curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/orgs/$ORG/repos" \
         | python3 -c 'import json,sys; print(" ".join(sorted(r["full_name"] for r in json.load(sys.stdin))))' 2>/dev/null || echo "(illisibles)")"
say "repos de l'org $ORG : $REPOS"
say "forge de banc PRETE — $FORGE_URL · humain $HUMAN / $HUMAN_PASSWORD"
