#!/usr/bin/env bash
# SOURCE: etc/provision-role-tokens.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — pose idempotente des role-tokens forge (A4) : mint + ecriture <dir>/<role>.gitea_token + sonde
#
# LE trou A4 : les tokens des comptes de role (architect, engineer, qualifier, reviewer, gatekeeper,
# consultant) n'avaient AUCUN script de pose. Consequence : un humain NEUF ne peut pas faire tourner
# la chaine (create_issue signe as-architect, donc 401), la « reinstall en 10 min » est une pretention,
# et le jeu de tokens vivant n'existe que dans l'env prive du premier operateur. Ce script EST le
# mecanisme : il mint les tokens sur UNE forge et les ecrit dans UN dossier (un jeu par forge, cf.
# FORGE_ROLE_TOKENS_DIR cote runtime), rejouable a volonte.
#
# DROIT DE MINT (POSIX minimum, rien de maison) : minter le token d'un compte exige la BASIC AUTH
# (`--passwords-file`). Gitea REFUSE la creation de token par header token — meme un token
# site-admin, meme sur soi-meme (`POST /users/{u}/tokens` rend "auth required"). Le discriminant est
# donc la METHODE d'authentification, pas le privilege.
#
# ⚠ MAIS IL EXISTE UNE VOIE ADMIN, et cette ligne affirmait le contraire jusqu'au 2026-08-12.
# Matrice re-mesuree cellule par cellule sur une forge vierge (Gitea 1.26.1) :
#   jeton systeme (non-admin), sans Sudo  -> 403 "doer should be the site admin or be same as the contextUser"
#   jeton systeme (non-admin), avec Sudo  -> 403 "Only administrators allowed to sudo"
#   jeton SITE-ADMIN, avec Sudo           -> 401 "auth required"        (l'auth par jeton ne passe jamais)
#   BASIC AUTH site-admin + `Sudo: <u>`   -> 201, LE TOKEN EST CREE     pour <u>, sans son password
# Ce qu'il faut donc, ce n'est PAS le password de la cible : c'est celui d'un SITE-ADMIN. Le detour
# « poser un password sur la cible puis basic-auth » n'a jamais ete necessaire ; il etait la
# consequence d'une matrice mesuree a moitie.
#
# CE SCRIPT NE PREND PAS CETTE VOIE, et c'est un choix : il minte des comptes de ROLE qu'il a lui-meme
# fait creer, dont il detient donc legitimement les passwords. Emprunter le rail site-admin
# exigerait qu'un credential capable de devenir n'importe qui vive la ou tourne ce script.
# Le password est un SCALPEL (fichier operateur-only) : ce script se lance UNE fois par
# quelqu'un qui a ce droit ; le runtime, lui, ne lit que les fichiers poses (0640, groupe fleet). Le
# script n'invente aucun droit : il echoue proprement s'il n'a pas le sien.
#
# IDEMPOTENCE (provisioning brutal) : un token local DEJA VALIDE sur la forge est saute (aucune
# ecriture). Invalide ou absent : l'ancien token remote du meme nom est supprime puis re-minte, et le
# fichier est reecrit. Appliquer N fois = appliquer 1 fois. `--check` = sonde seule (exit non nul si un
# token est invalide) — c'est le controle du nuke-drill.
#
# USAGE :
#   provision-role-tokens.sh --forge URL --passwords-file /root/forge/roles.json \
#       --extra-token lcars-system:system.gitea_token        # les 6 roles + le token systeme = A4 complet
#   provision-role-tokens.sh --forge URL --check             # sonde seule (nuke-drill)
#   provision-role-tokens.sh --help                          # cette aide
# Options : --tokens-dir DIR (defaut /home/private) · --roles "a b c" (defaut : les 6) ·
#           --extra-token COMPTE:FICHIER (repetable — pour un token dont le compte n'est pas le nom de
#             fichier, ex. le systeme `lcars-system:system.gitea_token`) · --group GRP (defaut fleet) ·
#           --token-name NAME (defaut lcars-fleet) · -h|--help
# passwords-file : JSON {"engineer":"pwd",...} OU {"engineer":{"password":"pwd"},...} (le compte systeme
#   y a sa cle, ex. "lcars-system"). Cle insensible a la casse (Gitea resout les comptes
#   case-insensitive : `Architect` matche le role `architect`).
# EXIT : 0 = tous les tokens poses ou valides · 1 = usage/dependance manquante · 2 = au moins un token
#   en echec.

# NOTE FOR SOURCE READERS: the header above is in French while the rest of this file's comments are in
# English, and that is not an oversight. `usage()` renders that header verbatim — it IS the --help
# output, i.e. text the box says to its operator. Translating it would translate the CLI. Everything
# from here down is source prose and follows the English rule. If you ever split the two (a separate
# heredoc for --help), the header goes English with the rest.
#
# THE BLANK LINE ABOVE THIS NOTE IS LOAD-BEARING: `usage()` is `sed -n '2,/^$/p'`, so the range ends at
# the FIRST blank line. That is what keeps this note out of --help — not its distance from the top.
# Keep the blank line, and put anything that must NOT be printed below it.

set -euo pipefail

FORGE="${FORGE_BASE_URL:-}"
TOKENS_DIR="/home/private"
# vulcan: a RESERVED seat (kind: ReservedSeat in the canon, BL-6-45) — account + token minted,
# both inert until the box opens. A seat = a full identity, no branch here. (The older note
# claiming vulcan "absent rightly, external Codex agent" described the pre-seat world and is
# gone with it.) starfleet: real fleet role, `forge_identity: false` in its canon — every forge
# write goes through the system account, hence no token here either.
#
# This list is locked FOUR ways by `roles.provisioning_locked` (strict equality: canon
# catalogue == forge.tf local.roles == this ROLES == provision-lib.sh PROV_ROLES) — a partial
# role rename or a dropped role goes RED at the gate with the delta named (the old
# one-direction subset check missed exactly that, twice).
ROLES="system_architect system_chief system_gatekeeper fleet_engineer fleet_scribe fleet_qualifier fleet_reviewer fleet_scoper fleet_vulcan"
GROUP="fleet"
TOKEN_NAME="lcars-fleet"
SCOPES="write:repository,write:issue"
# The SYSTEM account creates the org repos (create_project → onboard): POST /orgs/<org>/repos ALSO
# requires write:organization (measured: without it the token is valid but the creation 403s; with it,
# 201). Roles NEVER create an org repo, so they stay at the minimal scope — least privilege: a hijacked
# role token must not be able to administer the org.
# The user scope is the SYSTEM account's alone: only `forge_bot_login` (GET /user, resolving the bot
# login to check the bot-authored markers on route/step_run/result) reads it, and it alone — ROLE
# tokens are NEVER used for that GET. Roles WRITE through `as_role` (posts/reviews/merge); forge
# READS, forge_bot_login included, ALWAYS go through the system token, never a role. A role holding
# it could edit its own account profile, which is useless to its job.
# IT IS `write:user` AND NOT `read:user` BECAUSE THE SYSTEM ACCOUNT OWNS THE DECK'S OAUTH2 CLIENT,
# and registering one is a `/user/` WRITE. Measured 2026-08-12: `POST /user/applications/oauth2`
# answers `required=[write:user]` on a token without it, 201 with it — a refusal about the SCOPE,
# not the auth method, unlike minting a token which Gitea only accepts over basic auth. So
# provisioning can register the client with a token and no password; without the scope the box has
# no front door at all, since the deck refuses to serve anything unauthenticated.
# Listing both would be noise, not belt-and-braces: Gitea NORMALISES the pair and mints
# `write:user` alone. Measured on the widened token, `GET /user` still answers 200 — the write
# scope subsumes the read, and the forge_bot_login rail is intact.
SYSTEM_ACCOUNT="lcars-system"
SYSTEM_SCOPES="$SCOPES,write:organization,write:user"
PASSWORDS_FILE=""
CHECK_ONLY=0
# Non-role tokens whose account is not the filename (the mapping is DATA, not a special case): the
# SYSTEM token is the `lcars-system` account but the runtime reads `system.gitea_token`. Filled by
# `--extra-token <account>:<file>` (repeatable). Without it, A4 leaves the system token a manual step.
declare -a EXTRA_ENTRIES

# --help renders the header block above verbatim. It stops at the FIRST BLANK LINE rather than at a
# hardcoded line number: the previous `2,40p` silently truncated the last sentence the moment the header
# grew by one line, and a usage text that ends mid-sentence is worse than no usage text.
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --forge) FORGE="$2"; shift 2 ;;
    --tokens-dir) TOKENS_DIR="$2"; shift 2 ;;
    --roles) ROLES="$2"; shift 2 ;;
    --group) GROUP="$2"; shift 2 ;;
    --token-name) TOKEN_NAME="$2"; shift 2 ;;
    --passwords-file) PASSWORDS_FILE="$2"; shift 2 ;;
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
if [[ "$CHECK_ONLY" -eq 0 && -z "$PASSWORDS_FILE" ]]; then
  echo "provision-role-tokens: mode pose sans droit de mint — --passwords-file requis (--check pour sonder seul)" >&2
  exit 1
fi
if [[ -n "$PASSWORDS_FILE" && ! -r "$PASSWORDS_FILE" ]]; then
  echo "provision-role-tokens: passwords-file illisible: $PASSWORDS_FILE (lance-le avec le compte qui peut le lire)" >&2
  exit 1
fi

# Token validity probe: GET /user WITH that token. A4 fix (a false negative that was caught in the
# field): a narrowly-scoped token (a role, WITHOUT read:user) answers 403 on /user — ALIVE, merely
# out-of-scope for THAT endpoint. Only 401 means dead/revoked (Gitea authenticates the token, then
# refuses the SCOPE with a 403, distinct from the 401 "this token does not exist / has expired").
# Measured: minimal token (write:repository,write:issue) → GET /user = 403; read:user token → 200;
# revoked token → 401. So the correct probe is: {200,403} = alive; 401 — or anything else, 5xx /
# timeout / connection failure — = invalid or undetermined → re-provision (fail-safe: never assume
# valid on a doubt).
token_valid() { # $1=token
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: token $1" "$FORGE/api/v1/user")"
  [[ "$code" == "200" || "$code" == "403" ]]
}

# ACTION auth on account $1: basic auth (the role's password). Writes the curl args into the global
# CURL_AUTH array (no fragile string escaping). The key lookup is CASE-INSENSITIVE: Gitea resolves
# accounts case-insensitively, so a password-file with `Architect` matches the `architect` role — we
# align with the underlying system rather than imposing a stricter constraint than it does. The value is
# either a bare string OR an object `{password: ...}`. `-u user:pass` basic auth is the only mint Gitea
# accepts.
declare -a CURL_AUTH
set_auth_for() { # $1=role
  local role="$1" pwd
  pwd="$(jq -r --arg r "$role" '
    to_entries[]
    | select((.key | ascii_downcase) == ($r | ascii_downcase))
    | .value | if type=="object" then .password else . end
    | select(. != null and . != "")
  ' "$PASSWORDS_FILE" | head -1)"
  [[ -n "$pwd" ]] || return 1
  CURL_AUTH=(-u "$role:$pwd")
}

# ONE entry to provision = one `account:file` pair (the mapping is DATA). Roles produce
# `<role>:<role>.gitea_token`; `--extra-token` adds the pairs where account is not file (the system:
# `lcars-system:system.gitea_token`). One mint mechanism for all of them.
declare -a ENTRIES
# Le compte est le LOGIN (`<catalogue>_<role>`, unique a l'instance Gitea) et le FICHIER reste le
# ROLE : c'est la cle que le runtime connait — `as_role/2` indexe `<role>.gitea_token`, jamais le
# login. La projection est inversible PAR CONSTRUCTION, `_` etant interdit dans les deux moities.
# LE FICHIER PORTE LE LOGIN, PAS LE ROLE. Il portait `${login#*_}` — le login ampute de son tier —
# donc `fleet_writer` et `web_writer` ecrivaient le MEME `writer.gitea_token` : le catalogue
# provisionne en second prenait en silence l'identite du premier, et rien ne pouvait le signaler,
# puisque le fichier existe et que son contenu est un jeton valide. Le COMPTE etait deja prefixe
# pour cette raison exacte ; le fichier ne l'etait pas. Un jeton appartient a un COMPTE, et un nom
# de role n'est unique que dans son propre catalogue.
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
  curl -s -o /dev/null -m 15 "${CURL_AUTH[@]}" -X DELETE \
    "$FORGE/api/v1/users/$account/tokens/$TOKEN_NAME" || true

  resp="$(curl -s -m 15 "${CURL_AUTH[@]}" -X POST \
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

  # Atomic write (tmp+mv) + POSIX rights: 0640, group fleet — the per-human BEAM reads through the
  # group, nobody else. LOCAL READABILITY is a postcondition on a par with forge validity: a token
  # valid on the forge but owned by the wrong group is UNREADABLE by the runtime — announcing POSE and
  # exiting 0 there hid a broken deploy behind a WARN. So the group ownership is VERIFIED (stat, not
  # just the chgrp exit code), and a mismatch FAILS the account: the file stays written (the mint cost
  # was real, --check will confirm it), but it is not counted as posed and the run exits non-zero.
  install -d -m 0750 "$TOKENS_DIR" 2>/dev/null || true
  tmp="$(mktemp "$TOKENS_DIR/.provision.XXXXXX")" || { echo "FAIL  $account — $TOKENS_DIR non writable" >&2; fail=1; continue; }
  printf '%s\n' "$tok" > "$tmp"
  chmod 0640 "$tmp"
  chgrp "$GROUP" "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"

  if [[ "$(stat -c %G "$file" 2>/dev/null)" != "$GROUP" ]]; then
    echo "FAIL  $account — token valide sur la forge mais groupe != $GROUP : ILLISIBLE par le runtime (chgrp $GROUP requis, droit sur $TOKENS_DIR ?)" >&2
    fail=1
    continue
  fi
  echo "POSE  $account — nouveau token, sonde OK, lisible par le groupe $GROUP → $file"
done

if [[ "$fail" -ne 0 ]]; then
  echo "provision-role-tokens: AU MOINS UN TOKEN N'EST PAS EN PLACE (forge $FORGE)" >&2
  exit 2
fi
echo "provision-role-tokens: tous les tokens sont valides sur $FORGE"
