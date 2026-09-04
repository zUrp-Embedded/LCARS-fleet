#!/usr/bin/env bash
# SOURCE: runtime/services/forge-recipe/provision-forge-charte.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-06
# STATUS: PROTO-V2 — pose la CHARTE sur la forge : avatars des comptes + org, et le nom du siège master
#         (frère cosmétique de forge.tf). « Charte » couvre les deux : l'image ET le `full_name` du
#         siège sont des faits de présentation, pas de structure.
#
# POURQUOI CE SCRIPT (et pas du .tf) : le provider go-gitea/gitea n'expose AUCUN attribut avatar
# settable (juste org.avatar_url en lecture). L'avatar n'est pas de l'état convergent qu'on déclare —
# c'est un geste one-shot d'upload d'image. Il vit donc dans le MÊME seam que provision-role-tokens.sh :
# forge.tf pose la structure déclarative, ce script pose l'impératif cosmétique. Les deux tournent au
# stand-up de la forge, tous deux avec le master-token — indépendants du token-seam runtime.
#
# PRIVILÈGE : poser l'avatar d'un compte tiers passe par le master/admin-token + header `Sudo: <compte>`
# (Gitea fait agir l'admin AU NOM du compte ; vérifié 2026-07-06 : POST /user/avatar Sudo:engineer -> 204).
# Contrairement au mint de token (que Gitea refuse par header token → basic-auth obligatoire), l'avatar
# ACCEPTE le token admin — donc UN seul token suffit pour tous les comptes, sans leurs passwords.
# L'org, elle, se pose en direct (l'admin édite l'org) sans Sudo.
#
# IDEMPOTENCE PAR RÉASSERTION : on re-POST l'image de charte à chaque run (l'effet visible est stable —
# même image = même rendu). C'est VOULU : un run RÉ-ASSERTE la charte (si quelqu'un a changé un avatar à
# la main, le prochain run le remet). `--check` = sonde seule : PASS si le compte porte un avatar custom
# (hash long), FAIL s'il est resté sur l'identicon par défaut.
#
# USAGE :
#   FORGE_BASE_URL=http://localhost:3000 FORGE_ADMIN_TOKEN=<tok> provision-forge-charte.sh
#   provision-forge-charte.sh --forge URL --admin-token-file /root/forge/test/admin.token
#   provision-forge-charte.sh --forge URL --admin-token-file … --check      # sonde seule
# Options : --avatars-dir DIR (défaut : $LCARS_MEDIA_ROOT/avatars, soit /opt/lcars/share/avatars —
#           ce que l'installation a POSÉ depuis assets/) · --org NAME (défaut fleet ; --org "" pour
#           sauter l'org) · --admiral LOGIN (le master de CETTE forge : il reçoit le delta simple,
#           `admiral.png`. Absent = aucun avatar posé sur un compte humain).
#           Le mapping compte→fichier est une DONNÉE (tableau ENTRIES ci-dessous).
# EXIT : 0 = tout posé/valide · 1 = usage/dépendance · 2 = au moins une entrée en échec.

set -euo pipefail

FORGE="${FORGE_BASE_URL:-}"
ADMIN_TOKEN="${FORGE_ADMIN_TOKEN:-}"
ADMIN_TOKEN_FILE=""
AVATARS_DIR=""
ORG="fleet"
CHECK_ONLY=0

# Mapping compte→fichier (DONNÉE, pas cas spécial) : les rôles portent leur avatar de charte, et
# le compte système porte celui de STARFLEET — parce que c'est sa main : `starfleet` est le seul
# rôle canon (avec `admiral`) à porter `forge_identity: false`, et le catalogue dit pourquoi —
# toutes ses écritures passent par le compte système, qui porte donc l'insigne de starfleet — pas
# le favicon du produit, qui est celui de l'org.
# L'org `fleet` porte AUSSI le favicon (posée à part, endpoint distinct). L'humain n'est PAS listé : il
# pose son propre avatar (compte daily), on ne le décide pas pour lui.
#
# ⚠ CETTE LISTE N'EST PAS UN ROSTER, et ne doit pas le devenir. Elle porte un mapping compte→IMAGE :
# chaque entrée existe parce qu'un PNG de charte existe pour elle. La dériver du catalogue produirait
# une boucle qui échoue sur chaque rôle tiers — un rôle qu'on n'a pas dessiné n'a pas d'avatar, et
# c'est normal. Et un compte de CETTE liste absent de la forge visée n'est PAS un échec (mesuré sur le
# catalogue web — six 404 d'affilée sur un provisionnement correct, pour des comptes qui n'ont aucune
# raison d'y exister).
#
# DEUX PAIRES, ET ELLES SE LISENT DANS LES COULEURS. Une paire partage sa couleur et RIEN d'autre :
# le glyphe reste propre a chaque role, parce que c'est lui qui dit la fonction.
#   · producer  — `engineer` (engrenage) ↔ `scribe` (document)        : orange #FF9900
#   · system    — `chief` (confluence de merge) ↔ `gatekeeper` (portail) : cyan   #33BBCC
# Deux entrees de meme teinte ne sont donc PAS un doublon a corriger. C'est aussi pourquoi `chief`
# est dans cette table : un role qui a un compte et un jeton mais aucun dessin n'a aucun avatar, et
# le verdict de ce script nomme ce trou (6-115).
declare -a ENTRIES=(
  "system_architect:architect.png"
  "fleet_engineer:engineer.png"
  "system_chief:chief.png"
  "system_gatekeeper:gatekeeper.png"
  "fleet_qualifier:qualifier.png"
  "fleet_reviewer:reviewer.png"
  "fleet_scoper:scoper.png"
  "fleet_scribe:scribe.png"
  "fleet_vulcan:vulcan.png"
  # Cote COMPTE : le LOGIN (`<catalogue>_<role>`). Cote IMAGE : le ROLE — une charte pointe des
  # FICHIERS, et un PNG ne se derive pas d'un nom. C'est pourquoi cette table reste tenue a la main
  # la ou les trois autres listes de roles sont derivees du catalogue.
  "system_starfleet:starfleet.png"
)
# ⚠ `starfleet.png` EST DANS CETTE TABLE SOUS LE COMPTE SYSTEME. Le role `starfleet` n'a PAS de
# compte a lui (`forge_identity: false` au canon) — mais le compte SYSTEME est sa main, le catalogue
# l'ecrit, et il s'appelle `system_starfleet`. L'insigne (l'escadre,
# trois deltas) va donc sur le compte qui pose ses gestes. Un dessin appartient au ROLE, une entree
# de cette table a un COMPTE : ici les deux se rejoignent, ailleurs non.
# (Le delta simple, l'ancien insigne de starfleet, est devenu `admiral.png` : le siege garde le
# delta, le role prend l'escadre.)

#
# PARAMETRE, ET PAS ECRIT EN DUR, pour deux raisons qui se cumulent :
#   1. le login du master est VARIABLE — `admiral` au banc, le login de l'installeur en prod. Une
#      entree `admiral:admiral.png` en dur ne poserait rien chez qui n'a pas ce login-la, en
#      silence (un compte de cette table absent de la forge est tolere depuis la mesure du
#      catalogue `web`) ;
#   2. la regle juste au-dessus dit « l'humain n'est PAS liste : il pose son propre avatar, on ne
#      le decide pas pour lui ». Le master EST un compte humain. Ne rien poser par defaut la
#      preserve : le badge n'arrive que si le deploiement NOMME son master, donc le demande.
ADMIRAL=""
# Le dossier d'avatars D'UN CATALOGUE, nommes par le ROLE. La table ci-dessus est celle du catalogue
# de REFERENCE, tenue a la main et par COMPTE ; elle ne peut pas connaitre les roles d'un catalogue
# tiers. Un catalogue apporte les siens, `<role>.png`, et le compte se derive : `<org>_<role>`.
CAT_AVATARS=""

usage() { sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge) FORGE="$2"; shift 2 ;;
    --admin-token-file) ADMIN_TOKEN_FILE="$2"; shift 2 ;;
    --avatars-dir) AVATARS_DIR="$2"; shift 2 ;;
    --org) ORG="$2"; shift 2 ;;
    --admiral) ADMIRAL="$2"; shift 2 ;;
    --catalogue-avatars) CAT_AVATARS="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "provision-forge-charte: option inconnue: $1" >&2; usage >&2; exit 1 ;;
  esac
done


# LES ENTREES D'UN CATALOGUE, DERIVEES DE SES FICHIERS. Aucun index a tenir : le nom du fichier
# EST le role, et le compte est `<org>_<role>` — la meme derivation que `forge.tf` applique au
# roster. Un dossier absent ou vide n'ajoute rien et ne dit rien : l'avatar est facultatif
# (⚖ user 2026-08-16), et un catalogue qui n'en livre pas ne doit produire aucun bruit.
if [[ -n "$CAT_AVATARS" && -d "$CAT_AVATARS" ]]; then
  # Le compte se derive de `--org`, qui EST le nom du catalogue (`forge.tf` : « l'org porte le nom
  # du catalogue »). Pas de garde sur son absence : il a un defaut, donc une garde ne se
  # declencherait jamais — et une garde qui ne peut pas mordre est pire qu'aucune, elle rassure.
  for _png in "$CAT_AVATARS"/*.png; do
    [[ -e "$_png" ]] || continue
    _role="$(basename "$_png" .png)"
    ENTRIES+=("${ORG}_${_role}:${_png}")
  done
fi

command -v curl >/dev/null || { echo "provision-forge-charte: curl requis" >&2; exit 1; }
command -v jq   >/dev/null || { echo "provision-forge-charte: jq requis" >&2; exit 1; }
command -v base64 >/dev/null || { echo "provision-forge-charte: base64 requis" >&2; exit 1; }
[[ -n "$FORGE" ]] || { echo "provision-forge-charte: --forge URL (ou FORGE_BASE_URL) requis" >&2; exit 1; }
FORGE="${FORGE%/}"
# ⚠ LE DEFAUT EST LE CHEMIN INSTALLE, PAS UN VOISIN DU SCRIPT. Un jeu de png propre au script
# (`deps/avatars/`) serait un TROISIEME exemplaire des memes avatars, a cote de la marque
# (`assets/avatars/`) et du deck d'observation — et des copies derivent (mesure du 2026-08-20 : sept
# des neuf roles communs divergeaient entre trois copies, une mise a jour touchant un dossier et pas
# les autres).
#
# `assets/` est la source, et l'installation la pose en `/opt/lcars/share/avatars` a cote de la doc.
# Ce script lit donc ce que la boite a INSTALLE, pas ce qui traine a cote de lui.
: "${LCARS_MEDIA_ROOT:=/opt/lcars/share}"
[[ -n "$AVATARS_DIR" ]] || AVATARS_DIR="$LCARS_MEDIA_ROOT/avatars"
# AUCUN REPLI. Une installation qui n'a pas pose ses medias est une installation RATEE, pas une
# installation degradee : servir des identicons en silence rendrait vert un deploiement a moitie
# fait, et personne ne relierait jamais l'avatar generique a la cause.
[[ -d "$AVATARS_DIR" ]] || { echo "provision-forge-charte: dossier avatars introuvable: $AVATARS_DIR — l'installation ne les a pas poses (COPY assets/avatars du Dockerfile, ou LCARS_MEDIA_ROOT mal cable)" >&2; exit 1; }

# Le master-token n'est requis qu'en mode POSE (le --check lit des champs publics).
if [[ -n "$ADMIN_TOKEN_FILE" ]]; then
  [[ -r "$ADMIN_TOKEN_FILE" ]] || { echo "provision-forge-charte: admin-token-file illisible: $ADMIN_TOKEN_FILE" >&2; exit 1; }
  ADMIN_TOKEN="$(tr -d '[:space:]' < "$ADMIN_TOKEN_FILE")"
fi
if [[ "$CHECK_ONLY" -eq 0 && -z "$ADMIN_TOKEN" ]]; then
  echo "provision-forge-charte: mode pose sans autorité — FORGE_ADMIN_TOKEN ou --admin-token-file requis" >&2
  exit 1
fi

# ⚠ LE JETON ADMIN NE PASSE PAS PAR argv, ET C'EST UNE PROPRIETE QUE L'APPELANT PAIE DEJA.
# `charte.tf` la declare noir sur blanc : « le master-token passe par l'ENVIRONNEMENT, jamais par la
# ligne de commande : un argument est visible dans la table des processus ». Un
# `AUTH=(-H "Authorization: token $ADMIN_TOKEN")` la deferait au premier `curl` : il met le jeton
# dans `/proc/<pid>/cmdline`, lisible par tout le monde pendant la requete. Et ce jeton-la est un
# SITE-ADMIN : avec `Sudo:`, il agit au nom de n'importe quel compte.
#
# `curl -K -` lit sa configuration sur STDIN : ni argv, ni fichier a creer/chmoder/supprimer. Meme
# geste que `runtime/services/provision-role-tokens.sh` (6-141), applique ici a un credential plus puissant.
# La valeur est ECHAPPEE, pas esperee propre : la config de curl est un format cite.
curl_cfg_escape() { # $1=valeur
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

AUTH_CFG="header = \"Authorization: token $(curl_cfg_escape "$ADMIN_TOKEN")\""

# Un seul point de passage vers curl : l'auth arrive par stdin, les options par argv. Ecrire
# `printf … | curl -K -` a chaque site laisserait la porte ouverte au prochain qui ajoute un appel.
forge_curl() { printf '%s\n' "$AUTH_CFG" | curl -K - "$@"; }

# ─── QUI EST LE MASTER — RESOLU UNE FOIS, POUR LES DEUX FAITS QU'IL PORTE ────────────────────────
# ⚠ UNE RESOLUTION, PAS DEUX. Le login du master se DERIVE et ne se parametre pas (arbitrage
# 2026-08-16), donc l'appelant ne le nomme en general pas. Si le nom du siege se repliait sur `id=1`
# quand `--admiral` manque mais que le BADGE n'entrait dans la table qu'au PARSING de l'option, le
# siege garderait son nom et l'avatar du master disparaitrait, EN SILENCE — la sonde dirait « FAIL
# admiral — pas d'avatar custom » a cote de « OK admiral — nom du siege ». Un fait, une resolution.
#
# `/admin/users` EXIGE l'autorite : en `--check` (aucun jeton d'admin garanti) on ne resout pas, on
# se contente de ce que l'appelant a nomme. Une sonde qui devinerait le master rendrait un verdict
# sur un compte qu'elle a choisi elle-meme.
master="$ADMIRAL"
master_src="nomme (--admiral)"
if [[ -z "$master" && "$CHECK_ONLY" -eq 0 ]]; then
  master="$(forge_curl -s -m 10 "$FORGE/api/v1/admin/users?limit=50" \
    | jq -r 'map(select(.id == 1)) | .[0].login // ""' 2>/dev/null || true)"
  master_src="resolu par id=1 (premier compte de la forge)"
fi

# Le badge du master rejoint la table une fois qu'on sait QUI il est — jamais avant. La table nomme
# ses fichiers par ce qu'ils dessinent, et une entree `admiral:admiral.png` en dur ne poserait rien
# chez qui n'a pas ce login-la.
[[ -n "$master" ]] && ENTRIES+=("${master}:admiral.png")

# Un avatar custom uploadé porte un hash long (SHA256, 64 hex) ; l'identicon par défaut porte un hash
# court (32 hex). Heuristique de sonde (dépend de l'interne Gitea, mais stable en 1.26) : basename ≥ 40 hex.
avatar_is_custom() { # $1=avatar_url
  local base="${1##*/}"
  [[ "${#base}" -ge 40 ]]
}

# POST une image (base64) sur un endpoint. Corps JSON écrit en fichier temp (base64 volumineux → pas de
# -d inline fragile). Rend le code HTTP.
post_image() { # $1=url  $2=fichier_png  $3...=headers extra
  local url="$1" png="$2"; shift 2
  local tmp; tmp="$(mktemp)"
  printf '{"image":"%s"}' "$(base64 -w0 "$png")" > "$tmp"
  local code
  code="$(forge_curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST "$@" \
    -H "Content-Type: application/json" --data-binary @"$tmp" "$url")"
  rm -f "$tmp"
  printf '%s' "$code"
}

fail=0
skipped=0

# Le compte existe-t-il sur CETTE forge ? Un catalogue metier different n'a pas les memes roles, et
# poser un avatar sur un compte absent n'est pas un echec de provisionnement : c'est une entree de
# charte sans destinataire. Le distinguer demande le code HTTP, pas le corps — un 404 rend du JSON
# parfaitement lisible, donc `jq` seul ne verrait aucune difference.
account_exists() { # $1=compte
  local code
  code="$(forge_curl -s -o /dev/null -w '%{http_code}' -m 10 "$FORGE/api/v1/users/$1")"
  [[ "$code" == "200" ]]
}

for entry in "${ENTRIES[@]}"; do
  account="${entry%%:*}"
  # Une entree porte soit un NOM DE FICHIER — la table de reference, resolue dans `--avatars-dir` —
  # soit un chemin ABSOLU : les avatars d'un catalogue, qui vivent dans SON arbre et pas dans celui
  # de la recette. Les deux formes coexistent parce que les deux sources coexistent, l'une tenue a
  # la main et l'autre derivee.
  file="${entry#*:}"
  # UN NOM SE RESOUT DANS `--avatars-dir` ; UN CHEMIN NE SE RESOUT PAS. Le discriminant est le `/`,
  # pas le `/` INITIAL — et cette nuance a coute une passe complete au banc du 2026-08-16. La
  # recette passe `--catalogue-avatars ${path.module}/catalogue-avatars`, et `path.module` vaut `.`
  # dans le dossier du module : les entrees derivees portaient donc `./catalogue-avatars/dev.png`,
  # un chemin RELATIF, re-prefixe en `<avatars-dir>/./catalogue-avatars/dev.png` — introuvable, et
  # quatre comptes declares en echec pour une raison qui ne les concernait pas.
  #
  # La table tenue a la main ne porte que des NOMS de fichier (`dev.png`), sans separateur. Toute
  # entree derivee porte un chemin. Le test tient les deux sans avoir a savoir laquelle est laquelle.
  case "${entry#*:}" in
    */*) file="${entry#*:}" ;;
    *) file="$AVATARS_DIR/${entry#*:}" ;;
  esac

  if ! account_exists "$account"; then
    echo "IGNORE $account — compte absent de cette forge (autre catalogue metier) : rien a poser"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    url="$(forge_curl -s -m 10 "$FORGE/api/v1/users/$account" | jq -r '.avatar_url // ""')"
    if avatar_is_custom "$url"; then echo "OK    $account — avatar custom"; else
      echo "FAIL  $account — pas d'avatar custom (identicon/défaut)" >&2; fail=1; fi
    continue
  fi

  [[ -r "$file" ]] || { echo "FAIL  $account — asset introuvable: $file" >&2; fail=1; continue; }
  code="$(post_image "$FORGE/api/v1/user/avatar" "$file" -H "Sudo: $account")"
  if [[ "$code" == "204" || "$code" == "201" ]]; then
    echo "POSÉ  $account — avatar de charte ($(basename "$file"))"
  else
    echo "FAIL  $account — POST avatar -> HTTP $code" >&2; fail=1
  fi
done

# ─── LE NOM DU SIEGE MASTER ──────────────────────────────────────────────────────────────────────
# Le master porte le nom de son SIEGE dans l'UI, pas celui d'une personne. `full_name` est ce que
# Gitea affiche a la place du login (`[ui] DEFAULT_SHOW_FULL_NAME`), et c'est DEJA ce que font les
# comptes de role : `fleet_engineer` s'affiche « engineer » (cf. `instance/accounts.tf`).
#
# CE COMPTE N'EST PAS UNE IDENTITE DE TRAVAIL, et c'est ce qui rend le geste sans victime. Personne
# ne travaille sous root ; l'administrateur se fait un compte a lui pour le quotidien. La boite dit
# la meme chose a tous les etages : Guard B refuse de lancer une fleet sous l'uid 1000,
# `console-humans` exclut admiral des consoles worker, et le deck ne lui ouvre qu'une porte admin
# distincte de la porte worker. Il n'y a donc aucun nom de personne a ecraser ici — c'est un siege,
# et on ecrit le nom du siege dessus.
#
# RESOLUTION : `--admiral` d'abord (le deploiement qui NOMME son master fait autorite), sinon l'id 1
# — le premier compte cree par Gitea, site-admin par construction, celui que l'operateur pose en
# preparant sa forge. L'ancre evite d'exiger une variable de plus ; le login resolu est TOUJOURS
# imprime, donc ce chemin ne pose jamais rien en silence sur un compte qu'on n'a pas annonce.
#
# ⚠ PATCH, et `login_name` + `source_id` sont OBLIGATOIRES dans le corps meme si on ne les change
# pas — meme exigence que la rotation de mot de passe documentee dans `instance/accounts.tf`. Sans
# eux Gitea rend 422, et le message n'aide pas.
if [[ "$CHECK_ONLY" -eq 1 ]]; then
  # SONDE : `full_name` est un champ PUBLIC (`/users/<login>`), donc lisible sans master-token —
  # c'est ce qui permet au banc de verifier ce que la recette a pose, sans pouvoir le reposer.
  if [[ -z "$master" ]]; then
    echo "IGNORE nom du siege — aucun master nomme (--admiral) : rien a sonder"
  else
    fn="$(forge_curl -s -m 10 "$FORGE/api/v1/users/$master" | jq -r '.full_name // ""' 2>/dev/null || true)"
    if [[ "$fn" == "admiral" ]]; then echo "OK    $master — nom du siege « admiral »"; else
      echo "FAIL  $master — nom du siege absent ou autre (vu: ${fn:-<vide>})" >&2; fail=1; fi
  fi
else
  if [[ -z "$master" ]]; then
    echo "IGNORE nom du siege — aucun master nomme et aucun compte id=1 lisible : rien a ecrire"
  else
    code="$(forge_curl -s -o /dev/null -w '%{http_code}' -m 10 -X PATCH \
      -H "Content-Type: application/json" \
      --data-binary "{\"login_name\":\"$master\",\"source_id\":0,\"full_name\":\"admiral\"}" \
      "$FORGE/api/v1/admin/users/$master")"
    if [[ "$code" == "200" ]]; then
      echo "POSÉ  $master — nom du siege « admiral » ($master_src)"
    else
      echo "FAIL  $master — PATCH full_name -> HTTP $code ($master_src)" >&2; fail=1
    fi
  fi
fi

# L'ORG (endpoint distinct, sans Sudo — l'admin édite l'org). --org "" pour sauter.
if [[ -n "$ORG" ]]; then
  # ⚠ LE FAVICON N'EST PAS UN AVATAR DE ROLE : il se lit dans l'arbre favicon installe, sa seule
  # maison. Une copie sous `avatars/` serait l'octet pour octet `assets/favicon/favicon-512.png`
  # sous un autre nom — un doublon dont rien ne dirait qu'il en est un.
  org_file="$LCARS_MEDIA_ROOT/favicon/favicon-512.png"
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    url="$(forge_curl -s -m 10 "$FORGE/api/v1/orgs/$ORG" | jq -r '.avatar_url // ""')"
    if avatar_is_custom "$url"; then echo "OK    org:$ORG — avatar custom"; else
      echo "FAIL  org:$ORG — pas d'avatar custom" >&2; fail=1; fi
  elif [[ -r "$org_file" ]]; then
    code="$(post_image "$FORGE/api/v1/orgs/$ORG/avatar" "$org_file")"
    if [[ "$code" == "204" || "$code" == "201" ]]; then echo "POSÉ  org:$ORG — favicon LCARS"; else
      echo "FAIL  org:$ORG — POST avatar -> HTTP $code" >&2; fail=1; fi
  else
    echo "FAIL  org:$ORG — favicon introuvable: $org_file" >&2; fail=1
  fi
fi

# Le compte des ignores est DIT, jamais tu : un provisionnement qui couvre trois entrees sur dix doit
# le montrer, sinon « tous les avatars poses » ment par omission sur ce qu'il a couvert.
note=""
[[ "$skipped" -gt 0 ]] && note=" ($skipped entree(s) de charte sans compte sur cette forge — ignorees)"

# ⚠ « TOUS LES AVATARS POSES » ETAIT UNE PHRASE PLUS LARGE QUE CE QU'ELLE COUVRAIT (6-115). Elle est
# vraie de LA CHARTE — chaque entree de la table a ete posee — et un lecteur y entend « chaque compte
# de la forge a une tete ». Ce sont deux populations differentes : `chief` a un compte et un jeton,
# et aucune entree ici, donc aucun avatar, sous un verdict qui disait le contraire.
#
# La table N'EST PAS un roster et ne doit pas le devenir (voir son propre commentaire, plus haut :
# la deriver echouerait sur chaque role tiers qu'on n'a pas dessine). Ce qui se corrige n'est donc
# pas la table, c'est la PORTEE de la phrase : elle dit SUR QUOI elle porte, et combien.
# Un compte sans entree de charte reste invisible d'ici — mais plus personne ne lit « tous ».
couvert="${#ENTRIES[@]}"

if [[ "$fail" -ne 0 ]]; then
  echo "provision-forge-charte: AU MOINS UNE ENTRÉE EN ÉCHEC (forge $FORGE)$note" >&2
  exit 2
fi
echo "provision-forge-charte: $couvert entrée(s) de charte posées/valides sur $FORGE$note (la charte est une table tenue à la main : un compte hors table n'a pas d'avatar et n'est pas compté ici)"
