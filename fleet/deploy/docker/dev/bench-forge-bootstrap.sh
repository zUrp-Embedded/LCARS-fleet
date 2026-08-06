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
#   4. joue `tofu apply` sur la recette de prod INCHANGEE (org, teams, 8 roles, systeme, humain) ;
#   5. pose le seed dans la boite pour que le mint A4 des role-tokens converge au prochain boot ;
#   6. pose le mot de passe de BANC de l'humain, le promeut SITE-ADMIN (banc seulement, etape
#      6-bis, --no-human-admin pour s'en passer), pose son TOKEN operateur, et cable le token
#      systeme dans son fleet_v2.env (cf. les deux blocs ci-dessous) ;
#   7. pose les avatars de charte (le scribe en a un depuis le 2026-08-02) ;
#   8. SEME la forge : `fleet/lcars` (la source que la boite clone) + `fleet/project-template`
#      (le modele que create_project genere). Une forge vierge sans ces deux repos donne une
#      boite qui ne peut ni se mettre a jour ni onboarder un projet — mesure au drill du soir ;
#   9. rend un verdict MESURE : login humain, comptes de l'org, repos semes.
#
# ─── LE MOT DE PASSE HUMAIN DE BANC, ET POURQUOI IL N'EST PAS UNE FAIBLESSE ─────────────────────
# La recette de PRODUCTION (`fleet/deploy/deps/forge.tf`) donne a l'humain le seed avec
# `must_change_password = true` : il pose son propre secret au premier login. C'est correct et ce
# script n'y touche PAS — il agit APRES l'apply, sur la forge jetable seulement.
# Sur un banc, ce contrat coute une friction a chaque nuke (plusieurs par jour) pour proteger un
# compte qui vit deux heures sur une forge en loopback qu'on detruit ensuite. Le banc pose donc un
# mot de passe CONNU et leve le changement force. C'est une propriete du BANC, jamais un chemin de
# production : rien dans `provisioning/` ni dans le runtime ne lit cette valeur.
# La vraie sortie est l'onboarding humain (BL-6-25) ; d'ici la, la convention est ECRITE plutot que
# retenue.
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
#                                  [--no-human-admin]
# EXIT  : 0 forge prete · 1 arguments/dependance · 2 la forge ne repond pas · 3 bootstrap admin/token
#         4 tofu · 5 la boite (seed) · 6 le verdict final ne passe pas · 7 semis des repos

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

FORGE_URL="http://127.0.0.1:3600"
CONTAINER="lcars-ticketforge-forge-1"
BOX="lcars-ticket-lcars-1"
HUMAN="lcars"
HUMAN_EMAIL="lcars@lcars.local"
# Convention de banc — cf. le bloc d'en-tete. Jamais lue par la prod.
HUMAN_PASSWORD="toto32toto32"
TOFU_DIR=""
WITH_BOX=1
SEED_REPOS=1
# Propriete de BANC, jamais de prod — la raison, son cout et sa sortie sont a l'etape 6-bis.
HUMAN_ADMIN=1
DOCKER_BIN="${DOCKER_BIN:-docker}"
ADMIN="bootstrap"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge-url)      FORGE_URL="${2:?}"; shift 2 ;;
    --container)      CONTAINER="${2:?}"; shift 2 ;;
    --box)            BOX="${2:?}"; shift 2 ;;
    --human)          HUMAN="${2:?}"; shift 2 ;;
    --human-email)    HUMAN_EMAIL="${2:?}"; shift 2 ;;
    --human-password) HUMAN_PASSWORD="${2:?}"; shift 2 ;;
    --tofu-dir)       TOFU_DIR="${2:?}"; shift 2 ;;
    --no-box)         WITH_BOX=0; shift ;;
    --no-seed-repos)  SEED_REPOS=0; shift ;;
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

if ! curl -sf -m 5 "$(api)/users/$ADMIN" >/dev/null 2>&1; then
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
TOKEN_NAME="bench-tofu-$(date +%s)"
MASTER_TOKEN="$("$DOCKER_BIN" exec -u git "$CONTAINER" gitea admin user generate-access-token \
                  --username "$ADMIN" --token-name "$TOKEN_NAME" --scopes all --raw 2>/dev/null | tail -1)"
[[ -n "$MASTER_TOKEN" ]] || die "la forge n'a pas rendu de master token" 3
curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/user" >/dev/null \
  || die "le master token ne s'authentifie pas" 3
say "master token minte ($TOKEN_NAME)"

# ─── 4. tofu apply — la recette de PROD, inchangee ───────────────────────────────────────────────
# Copie de travail par defaut : la recette est jouee hors de l'arbre suivi pour que son tfstate (qui
# porte des valeurs sensibles) ne se retrouve jamais dans un `git status`.
if [[ -z "$TOFU_DIR" ]]; then
  TOFU_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench-tofu.XXXXXX")"
  cp -r "$REPO_ROOT/fleet/deploy/deps/." "$TOFU_DIR/"
  say "recette tofu copiee dans $TOFU_DIR (tfstate hors de l'arbre)"
fi

SEED_PW="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"

(
  cd "$TOFU_DIR"
  export TF_VAR_gitea_url="$FORGE_URL" TF_VAR_gitea_token="$MASTER_TOKEN" \
         TF_VAR_seed_password="$SEED_PW" TF_VAR_human_username="$HUMAN" \
         TF_VAR_human_email="$HUMAN_EMAIL"
  tofu init -no-color >/dev/null 2>&1 || exit 1
  tofu apply -auto-approve -no-color >/dev/null 2>&1 || exit 1
) || die "tofu apply en echec (rejoue-le a la main dans $TOFU_DIR pour voir sa sortie)" 4
say "structure forge posee (org, teams, comptes de role, systeme, humain)"

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
# APRES l'apply (tofu vient de (re)poser le seed + must_change_password=true sur ce compte).
"$DOCKER_BIN" exec -u git "$CONTAINER" gitea admin user change-password \
    --username "$HUMAN" --password "$HUMAN_PASSWORD" --must-change-password=false >/dev/null 2>&1 \
  || die "mot de passe de banc non pose pour $HUMAN" 6
say "humain $HUMAN : mot de passe de banc pose, changement force leve"

# ─── 6-bis. l'humain de banc est SITE-ADMIN (defaut du banc, jamais de la prod) ──────────────────
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
  say "humain $HUMAN : non-admin (--no-human-admin) — modele de prod respecte"
fi

# Token OPERATEUR de l'humain (~/.gitea_token) — mint par basic-auth avec le mot de passe de banc
# qu'on vient de poser. `read:organization` est LOAD-BEARING et non evident : sans lui le token
# rend 403 sur /orgs/.../members ET /teams/... — donc la sonde d'appartenance humaine (le
# prealable de tout onboarding projet) echoue en « NON VERIFIABLE » au lieu de repondre. Mesure
# le 2026-08-02 : minte sans ce scope, il a fait echouer un create_project UNE MARCHE plus loin
# que le token absent, avec un message qui ressemblait a un droit manquant cote forge.
if [[ "$WITH_BOX" -eq 1 ]]; then
  HUMAN_TOKEN="$(curl -s -m 10 -u "$HUMAN:$HUMAN_PASSWORD" -H "Content-Type: application/json" \
      -X POST -d '{"name":"bench-operateur","scopes":["write:repository","write:issue","read:organization","read:user"]}' \
      "$(api)/users/$HUMAN/tokens" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("sha1",""))' 2>/dev/null || true)"

  if [[ -n "$HUMAN_TOKEN" ]]; then
    printf '%s\n' "$HUMAN_TOKEN" | "$DOCKER_BIN" exec -i -u "$HUMAN" "$BOX" bash -c \
        'cat > ~/.gitea_token && chmod 600 ~/.gitea_token' \
      && say "token operateur pose dans $BOX:~$HUMAN/.gitea_token" \
      || say "token operateur NON pose dans la boite"
  else
    say "la forge n'a pas rendu de token operateur (un token du meme nom existe deja ?)"
  fi

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
  ( cd "$TOFU_DIR" && ./provision-forge-avatars.sh --forge "$FORGE_URL" \
      --admin-token-file "$TOFU_DIR/.admin.token" >/dev/null 2>&1 ) \
    && say "avatars de charte poses" \
    || say "avatars NON poses (non bloquant — les comptes gardent une tete vide)"
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
      "$(api)/orgs/fleet/repos" >/dev/null 2>&1 || true

    LCARS_REMOTE="http://lcars-system:${SYS_TOKEN}@${FORGE_URL#http://}/fleet/lcars.git"
    git -C "$REPO_ROOT" push -q "$LCARS_REMOTE" main:main 2>/dev/null \
      && say "fleet/lcars : main pousse" || say "fleet/lcars : main NON pousse"

    WORK_TREE="${LCARS_WORK_TREE:-/home/projects.work/LCARS/work}"
    [[ -d "$WORK_TREE/.git" ]] && { git -C "$WORK_TREE" push -q "$LCARS_REMOTE" work/ops:work/ops 2>/dev/null \
      && say "fleet/lcars : work/ops pousse" || say "fleet/lcars : work/ops NON pousse" ; }

    # Le modele passe par SA tache mix (contenu + flag template + labels protocole) — jamais un
    # push a la main : le contenu vient du catalogue, la tache est la seule a savoir l'assembler.
    printf '%s\n' "$SYS_TOKEN" > "$HERE/.bench-system.token"
    chmod 600 "$HERE/.bench-system.token"
    ( cd "$REPO_ROOT/fleet/runtime" && FORGE_BASE_URL="$FORGE_URL" \
        FORGE_TOKEN_FILE="$HERE/.bench-system.token" mix lcars.project_template.sync >/dev/null 2>&1 ) \
      && say "fleet/project-template : synchronise (contenu + flag + labels)" \
      || say "fleet/project-template : sync EN ECHEC (onboard degradera en bare-create)"
    rm -f "$HERE/.bench-system.token"
  fi
fi

# ─── 9. verdict MESURE ───────────────────────────────────────────────────────────────────────────
curl -sf -m 5 -u "$HUMAN:$HUMAN_PASSWORD" "$(api)/user" >/dev/null \
  || die "le login humain ne passe pas — la forge n'est PAS prete" 6

MEMBERS="$(curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/orgs/fleet/members" \
           | python3 -c 'import json,sys; print(" ".join(sorted(u["login"] for u in json.load(sys.stdin))))')"
say "membres de l'org fleet : $MEMBERS"

REPOS="$(curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/orgs/fleet/repos" \
         | python3 -c 'import json,sys; print(" ".join(sorted(r["full_name"] for r in json.load(sys.stdin))))' 2>/dev/null || echo "(illisibles)")"
say "repos de l'org fleet : $REPOS"
say "forge de banc PRETE — $FORGE_URL · humain $HUMAN / $HUMAN_PASSWORD"
