#!/usr/bin/env bash
# SOURCE: etc/provision-role-tokens.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — pose idempotente des role-tokens forge (A4) : mint + ecriture <dir>/<role>.gitea_token + sonde
#
# Il minte les tokens des comptes de role sur UNE forge et les ecrit dans UN dossier — un jeu par
# forge — rejouable a volonte.
#
# DROIT DE MINT : minter le token d'un compte exige la BASIC AUTH (`--passwords-file`). Gitea REFUSE
# la creation de token par header token, meme site-admin, meme sur soi-meme. Le discriminant est la
# METHODE d'authentification, pas le privilege.
#
# ⚠ IL EXISTE POURTANT UNE VOIE ADMIN — matrice mesuree cellule par cellule sur forge vierge :
#   jeton systeme (non-admin), sans Sudo  -> 403 "doer should be the site admin or be same as the contextUser"
#   jeton systeme (non-admin), avec Sudo  -> 403 "Only administrators allowed to sudo"
#   jeton SITE-ADMIN, avec Sudo           -> 401 "auth required"        (l'auth par jeton ne passe jamais)
#   BASIC AUTH site-admin + `Sudo: <u>`   -> 201, LE TOKEN EST CREE     pour <u>, sans son password
# Ce qu'il faut n'est donc PAS le password de la cible, mais celui d'un SITE-ADMIN.
#
# CE SCRIPT NE PREND PAS CETTE VOIE, et c'est un choix : il minte des comptes de ROLE qu'il a fait
# creer et dont il detient legitimement les passwords. Emprunter le rail site-admin exigerait qu'un
# credential capable de devenir N'IMPORTE QUI vive la ou tourne ce script. Le runtime, lui, ne lit
# RIEN : il DEMANDE au service d'autorite, seul proprietaire des fichiers poses.
#
# IDEMPOTENCE : un token local DEJA VALIDE est saute, aucune ecriture. Invalide ou absent, l'ancien
# token remote du meme nom est supprime puis re-minte. `--check` sonde sans jamais ecrire.
#
# USAGE :
#   provision-role-tokens.sh --forge URL --passwords-file /root/forge/roles.json \
#                                                            # les 6 roles + le systeme = A4 complet
#   provision-role-tokens.sh --forge URL --check             # sonde seule (nuke-drill)
#   provision-role-tokens.sh --help                          # cette aide
# Options : --tokens-dir DIR (defaut /opt/lcars/var/tokens) · --roles "a b c" (defaut : les 6) ·
#           --extra-token COMPTE:FICHIER (repetable — pour un token dont le compte n'est pas le nom de
#             fichier. Le compte systeme en etait le seul usager ; il suit le contrat de role depuis
#             qu'il s'appelle `system_starfleet`) · --owner USER (defaut lcars-authority) ·
#           --token-name NAME (defaut lcars-fleet) · -h|--help
# passwords-file : JSON {"engineer":"pwd",...} OU {"engineer":{"password":"pwd"},...} (le compte systeme
#   y a sa cle, ex. "system_starfleet"). Cle insensible a la casse (Gitea resout les comptes
#   case-insensitive : `Architect` matche le role `architect`).
# EXIT : 0 = tous les tokens poses ou valides · 1 = usage/dependance manquante · 2 = au moins un token
#   en echec.

# NOTE FOR SOURCE READERS: the header above is French because `usage()` renders it VERBATIM — it IS
# the --help output, i.e. text the box says to its operator. Everything from here down is source
# prose and follows the English rule.
#
# ⚠ THE BLANK LINE ABOVE THIS NOTE IS LOAD-BEARING: `usage()` is `sed -n '2,/^$/p'`, so the range
# ends at the FIRST blank line. That is what keeps this note out of --help, not its distance from
# the top. Anything that must NOT be printed goes below it.

set -euo pipefail

FORGE="${FORGE_BASE_URL:-}"
# ⚠ LA RACINE SE DEMANDE, ELLE NE SE RECOPIE PAS. `PROV_TOKENS_DIR` est la SSoT
# (`provision-lib.sh`) ; un litteral ici serait un SECOND endroit qui decide ou vivent les jetons,
# et celui qui derive est toujours celui qu'on ne relit pas. Le defaut reste, pour un script qu'un
# operateur lance a la main hors du rail.
TOKENS_DIR="${PROV_TOKENS_DIR:-/opt/lcars/var/tokens}"
#
# This list is locked FOUR ways by `roles.provisioning_locked` (strict equality: canon
# catalogue == forge.tf local.roles == this ROLES == provision-lib.sh PROV_ROLES) — a partial
# role rename or a dropped role goes RED at the gate with the delta named (the old
# one-direction subset check missed exactly that, twice).
ROLES="system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan"
#
OWNER="${PROV_AUTHORITY_USER:-lcars-authority}"
DIR_GROUP="${PROV_FLEET_GROUP:-fleet}"
TOKEN_NAME="lcars-fleet"
SCOPES="write:repository,write:issue"
# ⚠ THE SYSTEM ACCOUNT'S SCOPES ARE WIDER THAN A ROLE'S, AND EACH ADDITION IS MEASURED:
#
#   write:organization  it creates the org repos; without it the token is valid and the creation
#                       403s. Roles NEVER create one, so they stay minimal — a hijacked role token
#                       must not be able to administer the org.
#   write:user          NOT `read:user`: the system account owns the deck's OAuth2 client, and
#                       registering one is a `/user/` WRITE (`required=[write:user]` without it).
#                       Without the scope the box has no front door at all.
#
# Listing `read:user` too would be noise, not belt-and-braces: Gitea NORMALISES the pair and mints
# `write:user` alone, which subsumes the read.
SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-system_starfleet}"
SYSTEM_SCOPES="$SCOPES,write:organization,write:user"
PASSWORDS_FILE=""
MASTER_TOKEN_FILE=""
CHECK_ONLY=0
# Non-role tokens whose account is not the filename (the mapping is DATA, not a special case).
# Filled by `--extra-token <account>:<file>` (repeatable).
declare -a EXTRA_ENTRIES

# ⚠ FIRST BLANK LINE, NEVER A HARDCODED NUMBER: a `2,40p` truncates the last sentence in silence the
# day the header grows by one line, and a usage text ending mid-sentence is worse than none.
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge) FORGE="$2"; shift 2 ;;
    --tokens-dir) TOKENS_DIR="$2"; shift 2 ;;
    --roles) ROLES="$2"; shift 2 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --token-name) TOKEN_NAME="$2"; shift 2 ;;
    --passwords-file) PASSWORDS_FILE="$2"; shift 2 ;;
    --master-token-file) MASTER_TOKEN_FILE="$2"; shift 2 ;;
    --extra-token)
      [[ "$2" == *:* ]] || { echo "provision-role-tokens: --extra-token attend <compte>:<fichier> (vu: $2)" >&2; exit 1; }
      EXTRA_ENTRIES+=("$2"); shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "provision-role-tokens: option inconnue: $1" >&2; usage >&2; exit 1 ;;
  esac
done

command -v curl >/dev/null || { echo "provision-role-tokens: curl requis" >&2; exit 1; }
command -v jq >/dev/null || { echo "provision-role-tokens: jq requis" >&2; exit 1; }
[[ -n "$FORGE" ]] || { echo "provision-role-tokens: --forge URL (ou FORGE_BASE_URL) requis" >&2; exit 1; }
FORGE="${FORGE%/}"

# In POSE mode the basic auth (passwords-file) is required — the only route Gitea accepts to create a
# token (cf. the header: an admin token CANNOT mint).
if [[ "$CHECK_ONLY" -eq 0 && -z "$PASSWORDS_FILE" && -z "$MASTER_TOKEN_FILE" ]]; then
  echo "provision-role-tokens: mode pose sans droit de mint — --passwords-file requis (--check pour sonder seul)" >&2
  exit 1
fi
if [[ -n "$PASSWORDS_FILE" && ! -r "$PASSWORDS_FILE" ]]; then
  echo "provision-role-tokens: passwords-file illisible: $PASSWORDS_FILE (lance-le avec le compte qui peut le lire)" >&2
  exit 1
fi

# ⚠ {200,403} = ALIVE, AND THE 403 IS THE TRAP: a narrowly-scoped token answers 403 on /user while
# being perfectly alive, merely out of scope for THAT endpoint. Gitea authenticates first, THEN
# refuses the scope. Only 401 means dead or revoked; anything else — 5xx, timeout, connection
# failure — counts as undetermined and re-provisions. Never assume valid on a doubt.
#
# ⚠ AND THE SECRET NEVER GOES IN ARGV: a password harvested from /proc re-mints tokens FOREVER, so
# rotating a captured token repairs nothing.
#
# curl's config parser takes `name = "value"` with backslash escapes, so the value is ESCAPED rather
# than hoped to be free of quotes — a password is exactly the kind of string that carries them.
curl_cfg_escape() { # $1=value
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

token_valid() { # $1=token
  local code
  code="$(printf 'header = "Authorization: token %s"\n' "$(curl_cfg_escape "$1")" \
    | curl -K - -s -o /dev/null -w '%{http_code}' -m 10 "$FORGE/api/v1/user")"
  [[ "$code" == "200" || "$code" == "403" ]]
}

# The key lookup is CASE-INSENSITIVE because Gitea resolves accounts that way — we align with the
# underlying system rather than imposing a stricter constraint than it does.
CURL_AUTH_CFG=""

# La voie FORCE ne demande AUCUN secret de plus : avec le jeton master, on pose un password neuf, on
# minte avec, et on l'oublie — il ne survit ni en fichier, ni en variable exportee, ni au prochain
# appel.
#
# ⚠ LE JETON MASTER NE MINTE JAMAIS, IL NE FAIT QUE POSER UN PASSWORD, et la distinction porte le nom
# de l'option. Un mode qui MINTAIT par jeton admin a existe et a ete retire : Gitea rend « auth
# required » sur cette voie quel que soit le privilege. Ici le jeton sert a un `PATCH
# /admin/users/<u>` ; le mint qui suit est une basic-auth de la CIBLE, seule forme jamais acceptee.
force_password_for() { # $1=compte — pose un password neuf, le rend sur stdout
  local account="$1" admin_tok pw
  admin_tok="$(tr -d '[:space:]' < "$MASTER_TOKEN_FILE" 2>/dev/null)" || return 1
  [[ -n "$admin_tok" ]] || return 1
  pw="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | head -c 20)"
  printf 'header = "Authorization: token %s"\nheader = "Content-Type: application/json"\nrequest = "PATCH"\ndata = "{\\"login_name\\":\\"%s\\",\\"source_id\\":0,\\"password\\":\\"%s\\",\\"must_change_password\\":false}"\n' \
    "$admin_tok" "$account" "$pw" \
    | curl -K - -s -o /dev/null -m 15 -w '%{http_code}' "$FORGE/api/v1/admin/users/$account" \
    | grep -q '^200$' || return 1
  printf '%s' "$pw"
}

set_auth_for() { # $1=role
  local role="$1" pwd
  # La voie FORCE d'abord quand un jeton master est fourni : elle ne depend d'aucun etat anterieur.
  if [[ -n "$MASTER_TOKEN_FILE" ]]; then
    pwd="$(force_password_for "$role")" && [[ -n "$pwd" ]] && {
      CURL_AUTH_CFG="user = \"$(curl_cfg_escape "$role"):$(curl_cfg_escape "$pwd")\""
      return 0
    }
    # Echec du PATCH : on ne conclut pas, on retombe sur le fichier — un master token peut etre
    # perime sans que les passwords poses a la creation le soient.
  fi
  pwd="$(jq -r --arg r "$role" '
    to_entries[]
    | select((.key | ascii_downcase) == ($r | ascii_downcase))
    | .value | if type=="object" then .password else . end
    | select(. != null and . != "")
  ' "$PASSWORDS_FILE" | head -1)"
  [[ -n "$pwd" ]] || return 1
  CURL_AUTH_CFG="user = \"$(curl_cfg_escape "$role"):$(curl_cfg_escape "$pwd")\""
}

# ONE entry to provision = one `account:file` pair (the mapping is DATA). Roles produce
# `<role>:<role>.gitea_token`; `--extra-token` adds the pairs where account is not file. The system
# account WAS that pair and is not any more — it derives like the rest. One mint mechanism for all.
declare -a ENTRIES
#
# Le runtime lit par la MEME projection (`Fleet.Credentials.RoleIdentity.token_path/1`) : les deux
# moities de ce contrat se rencontrent sur ce nom de fichier, et il n'existe plus qu'un endroit ou
# il se compose de chaque cote.
for login in $ROLES; do ENTRIES+=("$login:$login.gitea_token"); done
ENTRIES+=("${EXTRA_ENTRIES[@]}")

fail=0
for entry in "${ENTRIES[@]}"; do
  account="${entry%%:*}"
  filename="${entry#*:}"
  file="$TOKENS_DIR/$filename"

  # Differentiated scope (least privilege): the system account creates org repos → write:organization on
  # top; roles stay at the minimal scope. Case-insensitive match (that is how Gitea resolves accounts).
  entry_scopes="$SCOPES"
  [[ "${account,,}" == "${SYSTEM_ACCOUNT,,}" ]] && entry_scopes="$SYSTEM_SCOPES"

  # Idempotence: a local token that is present AND valid → nothing to do.
  if [[ -r "$file" ]]; then
    tok="$(tr -d '[:space:]' < "$file")"
    if [[ -n "$tok" ]] && token_valid "$tok"; then
      echo "OK    $account — token valide ($file)"
      continue
    fi
  fi

  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    echo "FAIL  $account — token absent/invalide ($file)" >&2
    fail=1
    continue
  fi

  if ! set_auth_for "$account"; then
    echo "FAIL  $account — pas de droit de mint (password absent du passwords-file)" >&2
    fail=1
    continue
  fi

  # Re-provision: delete any remote token of the same name (names are unique per account), then mint.
  # A 404/422 on the DELETE is normal (no token of that name) — only the POST is authoritative.
  # `-K -` : l'auth arrive par STDIN, jamais par argv (6-141). `-d` porte un littéral, donc stdin
  # est libre — c'est ce qui rend cette forme utilisable ici sans fichier temporaire.
  printf '%s\n' "$CURL_AUTH_CFG" \
    | curl -K - -s -o /dev/null -m 15 -X DELETE \
      "$FORGE/api/v1/users/$account/tokens/$TOKEN_NAME" || true

  resp="$(printf '%s\n' "$CURL_AUTH_CFG" \
    | curl -K - -s -m 15 -X POST \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"$TOKEN_NAME\",\"scopes\":[$(printf '"%s",' ${entry_scopes//,/ } | sed 's/,$//')]}" \
      "$FORGE/api/v1/users/$account/tokens")"
  tok="$(printf '%s' "$resp" | jq -r '.sha1 // empty')"

  if [[ -z "$tok" ]]; then
    echo "FAIL  $account — la forge ne rend pas de token : $(printf '%s' "$resp" | head -c 160)" >&2
    fail=1
    continue
  fi

  if ! token_valid "$tok"; then
    echo "FAIL  $account — token obtenu mais sonde /user KO : 401, 5xx ou timeout (un scope restreint rend 403, qui compte comme vivant)" >&2
    fail=1
    continue
  fi

  # Atomic write (tmp+mv) + POSIX rights: 0600, owned by the authority service — nobody else opens
  # it, and no group traverses to it. LOCAL READABILITY is a postcondition on a par with forge
  # validity: a token valid on the forge but owned by the wrong account is UNREADABLE by the service
  # — announcing POSE and exiting 0 there hid a broken deploy behind a WARN. So ownership is VERIFIED
  # (stat, not just the chown exit code), and a mismatch FAILS the account: the file stays written
  # (the mint cost was real, --check will confirm it), but it is not counted as posed and the run
  # exits non-zero.
  #
  #
  # ⚠ `-o`/`-g` NE SONT TENTES QUE SI ON EST ROOT, et le repli n'est PAS un `|| true` silencieux :
  # sans le droit de donner le fichier, le controle `stat` plus bas fait echouer le compte. Un secret
  # trop ferme se diagnostique ; mal attribue, non.
  #
  #
  if [[ "$(id -u)" -eq 0 ]]; then
    install -d -m 0710 -o "$OWNER" -g "$DIR_GROUP" "$TOKENS_DIR" 2>/dev/null || true
  else
    install -d -m 0710 "$TOKENS_DIR" 2>/dev/null || true
  fi
  tmp="$(mktemp "$TOKENS_DIR/.provision.XXXXXX")" || { echo "FAIL  $account — $TOKENS_DIR non writable" >&2; fail=1; continue; }
  printf '%s\n' "$tok" > "$tmp"
  chmod 0600 "$tmp"
  chown "$OWNER:$OWNER" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"

  if [[ "$(stat -c %U "$file" 2>/dev/null)" != "$OWNER" ]]; then
    echo "FAIL  $account — token valide sur la forge mais propriétaire != $OWNER : ILLISIBLE par le service d'autorité (chown $OWNER requis, droit sur $TOKENS_DIR ?)" >&2
    fail=1
    continue
  fi
  echo "POSE  $account — nouveau token, sonde OK, détenu par $OWNER seul → $file"
done

if [[ "$fail" -ne 0 ]]; then
  echo "provision-role-tokens: AU MOINS UN TOKEN N'EST PAS EN PLACE (forge $FORGE)" >&2
  exit 2
fi
echo "provision-role-tokens: tous les tokens sont valides sur $FORGE"
