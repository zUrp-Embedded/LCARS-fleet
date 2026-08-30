#!/usr/bin/env bash
# SOURCE: fleet/deploy/docker/bench/bench-forge-bootstrap.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-02
# STATUS: geste de BANC — amene une forge jetable NEUVE a l'etat "la fleet peut travailler dessus"
# USAGE : bench-forge-bootstrap.sh [--forge-url http://127.0.0.1:3600] [--container lcars-ticketforge-forge-1]
#                                  [--box lcars-ticket-fleet-lcars-1] [--human lcars] [--human-password toto32toto32]
#                                  [--tofu-dir <ignore>] [--no-seed-repos]
#                                  [--human-admin] [--admin-token TOK]
# EXIT  : 0 forge prete · 1 arguments/dependance · 2 la forge ne repond pas · 3 admiral admin/token
#         4 la structure (gestes de la boite) · 5 le seed · 6 le verdict final ne passe pas
#         7 semis des repos

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

FORGE_URL="http://127.0.0.1:3600"
CONTAINER="lcars-ticketforge-gitea-1"
# `--admin-token` DIT UNE SEULE CHOSE, et elle commande tout le reste : « la forge preexiste et je
# n'en suis pas l'administrateur, je suis un client qui detient un jeton » — le cas de la PRODUCTION.
# Sans lui, la forge est a moi et je la fabrique : le cas du BANC.
ADMIN_TOKEN=""
BOX="lcars-ticket-lcars-1"
HUMAN="lcars"
HUMAN_EMAIL="lcars@lcars.local"
HUMAN_PASSWORD="toto32toto32"
WITH_BOX=1
SEED_REPOS=1
HUMAN_ADMIN=0
DOCKER_BIN="${DOCKER_BIN:-docker}"
ADMIN="admiral"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge-url)      FORGE_URL="${2:?}"; shift 2 ;;
    --container)      CONTAINER="${2:?}"; shift 2 ;;
    --admin-token)    ADMIN_TOKEN="${2:?}"; shift 2 ;;
    --box)            BOX="${2:?}"; shift 2 ;;
    --human)          HUMAN="${2:?}"; shift 2 ;;
    --human-email)    HUMAN_EMAIL="${2:?}"; shift 2 ;;
    --human-password) HUMAN_PASSWORD="${2:?}"; shift 2 ;;
    --tofu-dir)       shift 2 ;;
    --no-box)         WITH_BOX=0; shift ;;
    --no-seed-repos)  SEED_REPOS=0; shift ;;
    --human-admin)    HUMAN_ADMIN=1; shift ;;
    --no-human-admin) HUMAN_ADMIN=0; shift ;;
    -h|--help)        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "bench-forge-bootstrap: option inconnue: $1" >&2; exit 1 ;;
  esac
done

say()  { printf '[bench-forge] %s\n' "$*"; }
die()  { printf '[bench-forge] %s\n' "$*" >&2; exit "${2:-1}"; }
api()  { printf '%s/api/v1' "$FORGE_URL"; }

command -v curl >/dev/null || die "curl requis"
# `tofu` N'EST PLUS UNE DEPENDANCE DE L'HOTE : il vit dans l'image, avec la recette et les gestes.
# C'etait la premiere bidouille de ce banc — exiger d'un poste ce que le produit n'installe nulle part.
command -v python3 >/dev/null || die "python3 requis (lecture des reponses JSON)"

say "attente de la forge : $FORGE_URL"
for _ in $(seq 1 60); do
  curl -sf -m 3 "$(api)/version" >/dev/null 2>&1 && break
  sleep 2
done
curl -sf -m 3 "$(api)/version" >/dev/null 2>&1 || die "la forge ne repond pas: $FORGE_URL" 2

ADMIN_PW="${LCARS_BENCH_ADMIRAL_PW:-toto1234}"

if [[ -n "$ADMIN_TOKEN" ]]; then
  MASTER_TOKEN="$ADMIN_TOKEN"
  curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/user" >/dev/null \
    || die "le jeton d'admin fourni ne s'authentifie pas sur $FORGE_URL" 3
  say "admin fourni (--admin-token) — creation et mint SAUTES, la forge preexiste"
elif ! curl -sf -m 5 "$(api)/users/$ADMIN" >/dev/null 2>&1; then
  say "creation du compte admiral (master forge, $ADMIN)"
  "$DOCKER_BIN" exec -u git "$CONTAINER" gitea admin user create \
      --username "$ADMIN" --password "$ADMIN_PW" --email "admiral@lcars.local" \
      --admin --must-change-password=false >/dev/null 2>&1 \
    || die "creation du compte admiral impossible" 3
else
  say "compte admiral deja present — rotation de son mot de passe pour cette passe"
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

# La boite porte desormais tofu, ses providers, la recette et les gestes (`/opt/lcars/
# forge-gestures.sh`, pose par l'image). Ce banc entre donc par LA MEME PORTE que `box`, et
# ce qu'il exerce est ce que l'admin jouera.
[[ "$WITH_BOX" -eq 1 ]] || die "--no-box n'a plus de sens : la structure se pose DANS la boite (gestes de l'image)" 1

# LE SEED NE SE REGENERE PAS. Le provider n'ecrit PAS le password d'un compte existant (mesure
# 2026-08-16 sur 0.8), donc un seed neuf a la passe 2 donnerait a la boite un fichier qui ne
# correspond plus aux comptes, et le mint des jetons de role partirait en 401 le jour ou l'un
# manque. On relit celui que la boite garde ; on n'en fabrique un que s'il n'y en a pas.
SEED_PW="$("$DOCKER_BIN" exec "$BOX" cat /opt/lcars/var/tokens/forge-seed.pass 2>/dev/null | tr -d '\r\n' || true)"
if [[ -z "$SEED_PW" ]]; then
  SEED_PW="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
  say "seed de banc genere (aucun dans $BOX)"
else
  say "seed relu depuis $BOX (celui des comptes existants)"
fi

ENROLL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bench-enroll.XXXXXX")"
BOX_IMAGE="$("$DOCKER_BIN" inspect -f '{{.Config.Image}}' "$BOX" 2>/dev/null || true)"
[[ -n "$BOX_IMAGE" ]] || die "image de $BOX illisible -- roster non derivable" 4
# ⚠ AUCUN `--catalogue`, ET C'EST LE POINT. Nommer l'arbre de l'HOTE le fait monter dans le
# conteneur, ou la porte tourne en `nobody` : un parent en `drwxrws---` ou un `/home/<user>` en 0700
# lui reste ferme, et le refus ne peut dire que « l'image ne rend pas le roster ». Mesure du
# 2026-08-18 : la meme commande passe sur une machine ou le clone est world-readable et echoue ici.
# L'image PORTE son catalogue ; c'est aussi le plus juste, les comptes doivent correspondre a ce que
# la boite SERVIRA — l'arbre de l'hote peut avoir bouge depuis le build.
ENROLL_OUT="$("$REPO_ROOT/fleet/etc/enroll-catalogue.sh" \
                --tofu-dir "$ENROLL_DIR" \
                --image "$BOX_IMAGE" 2>/dev/null)" \
  || die "derivation du roster en echec (enroll-catalogue.sh, image $BOX_IMAGE) -- recette non enrolee" 4
ROSTER_LINE="$(printf '%s\n' "$ENROLL_OUT" | grep '^PROV_ROLES=')"
ORG="$(printf '%s\n' "$ENROLL_OUT" | sed -n 's/^PROV_FORGE_ORG="\(.*\)"$/\1/p')"
ORG="${ORG:-fleet}"
say "roster derive du catalogue ${ROSTER_LINE#PROV_ROLES=}"
say "org du catalogue : $ORG"
"$DOCKER_BIN" cp "$ENROLL_DIR/roles.auto.tfvars.json" "$BOX:/opt/lcars/fleet/deploy/deps/roles.auto.tfvars.json" \
  || die "roster non depose dans la recette de $BOX" 4
rm -rf "$ENROLL_DIR"

printf '%s' "$MASTER_TOKEN" | "$DOCKER_BIN" exec -i -u root "$BOX" /opt/lcars/forge-gestures.sh config-token \
  || die "jeton master refuse par la boite" 4
printf '%s' "$SEED_PW" | "$DOCKER_BIN" exec -i -u root "$BOX" /opt/lcars/forge-gestures.sh config-seed \
  || die "seed non pose dans la boite" 5

"$DOCKER_BIN" exec -i -u root \
    -e LCARS_BUILTIN_HUMAN="$HUMAN" -e LCARS_BUILTIN_EMAIL="$HUMAN_EMAIL" \
    "$BOX" /opt/lcars/forge-gestures.sh apply < /dev/null \
  || die "apply de la structure en echec dans $BOX (rejoue-le : docker exec -u root $BOX /opt/lcars/forge-gestures.sh apply)" 4
say "structure posee par la boite (org $ORG, teams, comptes, adhesions, propriete, depot modele)"
say "→ relance la boite (docker restart $BOX) pour que 50-forge minte les role-tokens"

# APRES l'apply (tofu vient de (re)poser le seed sur ce compte).
if [[ -n "$ADMIN_TOKEN" ]]; then
  say "humain $HUMAN : identite NON fabriquee (--admin-token) — Gitea la regle a son onboarding"
else
"$DOCKER_BIN" exec -u git "$CONTAINER" gitea admin user change-password \
    --username "$HUMAN" --password "$HUMAN_PASSWORD" --must-change-password=false >/dev/null 2>&1 \
  || die "mot de passe de banc non pose pour $HUMAN" 6
say "humain $HUMAN : mot de passe de banc pose, changement force leve"
fi

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

  # LE WORKER N'EXISTE PAS ENCORE A LA PASSE 1, ET CE N'EST PAS UNE PANNE. Depuis identite-v2
  # l'entrypoint materialise `admiral` (uid 1000) et RIEN d'autre : `$HUMAN` vient de la FORGE, et le
  # convergeur ne le fabrique qu'au boot SUIVANT le seed — precisement la relance que cette passe
  # demande deux lignes plus haut. Un `die` ici tuait l'amorcage sur un ordre qui ne peut pas etre
  # autre : mesure du 2026-08-15, `unable to find user lcars` en sortie de passe 1.
  # Meme forme que le semis : on saute en le DISANT, la passe 2 pose. Ce qui garde l'oubli impossible
  # n'est pas ce message, c'est le verdict de `bench-up.sh`, qui EXIGE ce fichier apres deux passes.
  if ! "$DOCKER_BIN" exec "$BOX" id -u "$HUMAN" >/dev/null 2>&1; then
    say "token operateur minte, pas encore pose : le worker '$HUMAN' n'existe pas dans $BOX (il vient
   de la forge, materialise par le convergeur a la relance). La passe 2 le posera."
  else
    printf '%s\n' "$HUMAN_TOKEN" | "$DOCKER_BIN" exec -i -u "$HUMAN" "$BOX" bash -c \
        'cat > ~/.gitea_token && chmod 600 ~/.gitea_token' \
      || die "token operateur minte mais NON pose dans $BOX — la boite ne pourra pas parler a la forge" 6
  fi
  say "token operateur pose dans $BOX:~$HUMAN/.gitea_token ($OP_TOKEN_NAME)"

fi

# ⚠ CE QUI A DU BOUGER AVEC, et c'est la cicatrice de ce bloc — sa sortie etait CAPTUREE justement
# parce qu'elle avait ete jetee une fois : « la seule ligne qui dit CE QUI a ete pose, et combien
# d'entrees de charte n'avaient pas de compte sur cette forge, disparaissait ». Le retirer sans rien
# mettre a la place aurait recree ce defaut a l'identique.
# ET LA REMONTER DEPUIS L'APPLY EST IMPOSSIBLE : le provisioner recoit une variable `sensitive`, donc
# OpenTofu supprime toutes ses lignes (cf. le bloc de l'etape 4). Le verdict de POSE n'est lisible
# nulle part par un appelant.
# D'OU LA SONDE. Le generique POSE, le banc VERIFIE — c'est la bonne repartition, et pas un repli :
# prouver est le metier du banc, poser est celui de la recette. `--check` ne porte aucune autorite
# (il lit des champs publics, sans master-token) et ne peut donc rien reposer par megarde ; il rend
# les memes lignes de verdict, sur l'etat REEL de la forge plutot que sur l'intention du script.
# La sonde vit DANS la boite avec le reste de la recette (l'hote n'en a plus de copie).
# SC2016 : les guillemets SIMPLES sont le geste. `$FORGE_BASE_URL` doit s'expanser DANS la boite,
# ou il est defini ; `$ADMIN` vient de l'hote et est episse par la sortie de quotes. Doubler les
# quotes ferait resoudre les deux ici, et l'URL de la forge y est vide.
# shellcheck disable=SC2016
charte_out="$("$DOCKER_BIN" exec "$BOX" bash -c \
    'cd /opt/lcars/fleet/deploy/deps && ./provision-forge-charte.sh --forge "$FORGE_BASE_URL" --admiral "'"$ADMIN"'" --check' 2>&1)" || true
printf '%s\n' "$charte_out" | while IFS= read -r l; do [[ -n "$l" ]] && say "charte: $l"; done

# `fleet/lcars` = la source que la boite clone au boot (LCARS_SOURCE_REMOTE, la jambe runtime du
# triangle). Une forge vierge sans elle est une forge sur laquelle la fleet ne peut rien faire — et
# c'est l'etat par defaut apres chaque nuke.
# Un projet neuf se peuple depuis le catalogue sur DISQUE, que la boite porte deja : il n'y a plus
# rien a semer pour qu'un onboard aboutisse.
if [[ "$SEED_REPOS" -eq 1 ]]; then
  SYS_TOKEN="$("$DOCKER_BIN" exec "$BOX" cat "/opt/lcars/var/tokens/${LCARS_SYSTEM_ACCOUNT:-system_starfleet}.gitea_token" 2>/dev/null | tr -d '[:space:]' || true)"

  if [[ -z "$SYS_TOKEN" ]]; then
    say "token systeme absent de la boite — semis SAUTE (relance la boite puis rejoue ce script)"
  else
    curl -s -m 10 -X POST -H "Authorization: token $SYS_TOKEN" -H "Content-Type: application/json" \
      -d '{"name":"lcars","description":"LCARS — la source de la boite","private":false,"auto_init":false}' \
      "$(api)/orgs/$ORG/repos" >/dev/null 2>&1 || true

    LCARS_REMOTE="http://${LCARS_SYSTEM_ACCOUNT:-system_starfleet}:${SYS_TOKEN}@${FORGE_URL#http://}/fleet/lcars.git"
    git -C "$REPO_ROOT" push -q "$LCARS_REMOTE" main:main 2>/dev/null \
      && _main_ok=1 || _main_ok=0
    if [[ "$_main_ok" -eq 1 ]]; then say "fleet/lcars : main pousse"; else say "fleet/lcars : main NON pousse"; fi

    WORK_TREE="${LCARS_WORK_TREE:-/home/projects.ops/LCARS/work}"
    [[ -d "$WORK_TREE/.git" ]] && { git -C "$WORK_TREE" push -q "$LCARS_REMOTE" ops:ops 2>/dev/null \
      && _ops_ok=1 || _ops_ok=0
    if [[ "$_ops_ok" -eq 1 ]]; then say "fleet/lcars : ops pousse"; else say "fleet/lcars : ops NON pousse"; fi ; }

  fi
fi

curl -sf -m 5 -u "$HUMAN:$HUMAN_PASSWORD" "$(api)/user" >/dev/null \
  || die "le login humain ne passe pas — la forge n'est PAS prete" 6

MEMBERS="$(curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/orgs/$ORG/members" \
           | python3 -c 'import json,sys; print(" ".join(sorted(u["login"] for u in json.load(sys.stdin))))')"
say "membres de l'org $ORG : $MEMBERS"

REPOS="$(curl -sf -m 5 -H "Authorization: token $MASTER_TOKEN" "$(api)/orgs/$ORG/repos" \
         | python3 -c 'import json,sys; print(" ".join(sorted(r["full_name"] for r in json.load(sys.stdin))))' 2>/dev/null || echo "(illisibles)")"
say "repos de l'org $ORG : $REPOS"
say "forge de banc PRETE — $FORGE_URL · humain $HUMAN / $HUMAN_PASSWORD"
