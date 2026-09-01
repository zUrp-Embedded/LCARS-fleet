#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/48-forge-host.sh
# AUTHOR: DrDree
# STARDATE: (posée par /push-github)
# STATUS: PROTO-V2 — la forge du POSTE DE TRAVAIL : un conteneur Gitea, amorcé et structuré
# APPLY-ON: wsl linux
# CHECK-ON: wsl linux
# NEEDS: root
# AFTER: 44-media 46-tofu

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

: "${PROV_FORGE_HOST_PORT:=21000}"              # le port qu'elle publie (aligné sur bench-up.sh)
# Un `PROV_FORGE_ADMIN` posé explicitement par l'opérateur l'emporte toujours : `:=` ne remplit que
# le vide, et la divergence qu'il créerait est justement ce que le rapport de siège dit.
: "${PROV_FORGE_ADMIN:=$(prov_seat_from_map)}"
: "${PROV_FORGE_ADMIN:=$PROV_HUMAN}"            # le compte qui ADMINISTRE la forge — l'opérateur
: "${PROV_DOCKER_BIN:=docker}"

: "${PROV_FORGE_BIND:=0.0.0.0}"
: "${PROV_FORGE_ADVERTISE:=}"
advertise_addr "${PROV_FORGE_ADVERTISE:-$PROV_FORGE_BIND}"
PROV_FORGE_ADVERTISE="$PROV_ADVERTISE"
PROV_FORGE_ADVERTISE_WHY="$PROV_ADVERTISE_WHY"

FORGE_CONTAINER="${PROV_FORGE_PROJECT}-gitea-1"
SEED_FILE="$PROV_TOKENS_DIR/forge-seed.pass"
COMPOSE_FILE="$(repo_root)/fleet/deploy/docker/forge-compose.yml"

# ⚠ `|| true` OBLIGATOIRE, ET SON ABSENCE A PRODUIT UN MORT SILENCIEUX. Ce module tourne sous
# `set -euo pipefail` : une assignation dont la substitution echoue TUE le script sur place, sans
# un mot. Compose absent -> `sed` sort en 2 -> le module mourait avant d'avoir rien imprime.
FORGE_SERVICE="$(sed -nE '/^services:/,/^[a-z]/{ s/^  ([a-z][a-z0-9_-]*):[[:space:]]*$/\1/p }' "$COMPOSE_FILE" 2>/dev/null | head -n1 || true)"
FORGE_CONTAINER="${PROV_FORGE_PROJECT}-${FORGE_SERVICE}-1"

forge_service_known() {
  [[ -n "$FORGE_SERVICE" ]] && return 0
  p_fail "aucun service lisible dans $COMPOSE_FILE — le nom du conteneur et le filtre docker en derivent tous les deux, et sans lui la sonde ne reconnaitrait AUCUNE forge"
  return 1
}
# ─── MONTER, OU CONSOMMER — L'AXE FORGE (40-RAILS.md § 13) ──────────────────────────────────────
#
# ⚠ CE MODULE MONTAIT EN DUR, et c'était le raccourci que le § 13 nomme : « forge montée » et
# « déploiement jetable » coïncidaient parce que `--bench` était boîte-seulement. Ils ne coïncident
# pas en général, et le contre-exemple est ce rail-ci — un POSTE DE TRAVAIL qui monte sa forge est un
# déploiement de travail, pas un banc.
#
# Deux états, un seul module :
#   · `FORGE_BASE_URL` posée  → la forge est FOURNIE. On ne monte rien, on la joint et on y pose la
#                               structure. Le travail est le même ; c'est le conteneur qui change de
#                               propriétaire.
#   · absente                 → on monte, comme avant.
#
# ⚠ ET UNE FORGE FOURNIE NE DEMANDE PAS DOCKER. Le refus « la forge du poste est un CONTENEUR » vaut
# pour celle qu'on monte, pas pour celle de quelqu'un d'autre. Exiger un daemon pour parler à une URL
# refuserait une machine parfaitement capable de travailler — c'est la première conséquence concrète
# de l'axe, et elle se voit ici.
#
# ⚠ ET UN TROISIEME CAS, QUI EST UNE DEMANDE EXPLICITE : `PROV_FORGE_MONTEE=1` force la montee meme
# quand `FORGE_BASE_URL` est posee. C'est ce que porte `--bench` sur le rail POSTE — le drapeau dit
# « monte-la-moi », et sur ce rail c'est son seul apport, la montee etant deja le defaut sans URL.
# Sans cette surcharge le drapeau n'avait AUCUN effet sur le poste : il etait accepte, affichait une
# promesse (« forge jetable + runner CI + humain de demo ») et n'en tenait rien.
if [[ "${PROV_FORGE_MONTEE:-}" == "1" ]]; then
  FORGE_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"
  FORGE_MONTEE=1
elif [[ -n "${FORGE_BASE_URL:-}" ]]; then
  FORGE_URL="${FORGE_BASE_URL%/}"
  FORGE_MONTEE=0
else
  FORGE_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"
  FORGE_MONTEE=1
fi

PUBLIC_URL="http://${PROV_FORGE_ADVERTISE}:${PROV_FORGE_HOST_PORT}"

d() { "$PROV_DOCKER_BIN" "$@"; }
forge_up() { curl -fsS -m 5 -o /dev/null "$FORGE_URL/api/v1/version" 2>/dev/null; }

forge_running_port() {
  d ps --filter "label=com.docker.compose.project=$PROV_FORGE_PROJECT" \
       --filter "label=com.docker.compose.service=$FORGE_SERVICE" \
       --format '{{.Ports}}' 2>/dev/null \
    | sed -n 's/.*:\([0-9]\{1,5\}\)->3000\/tcp.*/\1/p' | head -n1
}

forge_is_ours() { [[ "$(forge_running_port)" == "$PROV_FORGE_HOST_PORT" ]]; }

docker_answers() { d ps --format '{{.ID}}' >/dev/null 2>&1; }

foreign_forge_refusal() {
  p_fail "une forge répond sur $FORGE_URL, mais AUCUN conteneur du projet « $PROV_FORGE_PROJECT » ne publie $PROV_FORGE_HOST_PORT — ce n'est pas la forge de cette machine"
  p_fail "  monte la tienne : « --port-forge <autre port> » (ajoute « --forge-project <nom> » si le nom est pris lui aussi)"
}

forge_reach_note() {
  case "$PROV_FORGE_BIND" in
    127.0.0.1|localhost|::1) printf ' — cette machine SEULE' ;;
    *) printf ' — OUVERTE sur %s, composable en %s' "$PROV_FORGE_BIND" "$PUBLIC_URL"
       [[ -n "${PROV_FORGE_ADVERTISE_WHY:-}" ]] && printf ' (%s)' "$PROV_FORGE_ADVERTISE_WHY"
       return 0 ;;
  esac
}

new_password() { head -c 200 /dev/urandom | tr -dc 'A-Za-z' | cut -c1-10; }

announce_password() { # announce_password <login> <mot de passe>
  prov_announce_credential "forge du poste — compte d'administration" "$1" "$2"
}
# ⚠ UN BLOC A DISPARU ICI : `announce_builtin_human_password` (⚖ user 2026-08-30). Il posait, puis
# ANNONCAIT, le mot de passe forge d'un compte humain que la recette pre-semait. Le rail ne fabrique
# plus d'humain de travail — il pose les AUTORITES (le siege, l'admin de forge, le master token) et
# les personnes s'enrolent par la page d'inscription, sous leur nom. Un compte de travail aux
# identifiants imprimes dans une sortie de console etait un geste de BANC, hereditaire de l'epoque
# ou le poste en etait un ; `bench-forge-bootstrap.sh` le tient toujours, la ou il a un sens.
# Le marqueur `forge-builtin-human.posed` part avec : il n'avait d'objet que pour ne pas reposer ce
# mot de passe a chaque convergence.

reset_admin_password_if_asked() { # <rc de la création : 0 = compte tout juste créé>
  [[ -n "${PROV_FORGE_ADMIN_RESET:-}" ]] || return 0
  [[ "${1:-1}" -ne 0 ]] || return 0
  local npw; npw="$(new_password)"
  if d exec -u git "$FORGE_CONTAINER" gitea admin user change-password \
       --username "$PROV_FORGE_ADMIN" --password "$npw" --must-change-password=false \
       >/dev/null 2>&1; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    announce_password "$PROV_FORGE_ADMIN" "$npw"
  else
    p_fail "repose du mot de passe de « $PROV_FORGE_ADMIN » en échec — le compte garde l'ancien"
  fi
}

# Rend `admin`, `plain`, `absent`, ou `unknown` — quatre états, parce que « pas admin » et « pas de
# compte » appellent deux gestes différents, et « je n'ai pas pu demander » n'en appelle aucun.
forge_admin_state() { # forge_admin_state <login>
  local out body code
  [[ -n "$(read_token "$PROV_MASTER_TOKEN_FILE")" ]] || { echo unknown; return 0; }
  out="$(forge_curl "$PROV_MASTER_TOKEN_FILE" -sS -m 10 -w '\n%{http_code}' "$FORGE_URL/api/v1/users/$1" 2>/dev/null)" \
    || { echo unknown; return 0; }
  code="${out##*$'\n'}"; body="${out%$'\n'*}"
  case "$code" in
    200) case "$body" in *'"is_admin":true'*|*'"is_admin": true'*) echo admin ;; *) echo plain ;; esac ;;
    404) echo absent ;;
    *)   echo unknown ;;
  esac
}

forge_promote_admin() { # forge_promote_admin <login>
  local tok
  tok="$(read_token "$PROV_MASTER_TOKEN_FILE")"
  [[ -n "$tok" ]] || return 1
  # `login_name` et `source_id` sont EXIGÉS par l'endpoint (Gitea les relit pour la source
  # d'authentification) : les omettre rend 422 sur un corps qui a l'air complet.
  printf 'header = "Authorization: token %s"\nheader = "Content-Type: application/json"\nrequest = "PATCH"\ndata = "{\\"admin\\":true,\\"login_name\\":\\"%s\\",\\"source_id\\":0}"\n' \
    "$tok" "$1" \
    | curl -K - -fsS -m 15 "$FORGE_URL/api/v1/admin/users/$1" >/dev/null 2>&1
}

seat_binding_report() { # seat_binding_report <check|apply>
  local mode="${1:?}"
  prov_seat_binding "$PROV_FORGE_ADMIN"

  case "$PROV_SEAT_BINDING" in
    diverge)
      p_drift "siège : « $PROV_FORGE_ADMIN » côté unix, « $PROV_SEAT_LOGIN » côté $PROV_SEAT_SOURCE — deux acteurs pour un rôle, et le lien n'est PAS enregistré tant qu'ils ne s'accordent pas"
      return 0
      ;;
    unknown)
      p_warn "siège : ni compte unix nommé, ni #1 lisible sur la forge — le lien n'est pas mesurable"
      return 0
      ;;
  esac

  # ⚠ « NON ENREGISTRE » SE DIT D'UNE CARTE QU'ON A PU LIRE. `prov_seat_from_map` rend vide dans DEUX
  # cas — le siège n'y est pas, ou le fichier n'est pas lisible d'ici — et les deux tombaient sur le
  # même drift. Mesure du 2026-09-01, banc 2001 : ce drift apparaissait sans sudo et disparaissait
  # avec, sur une carte parfaitement en place.
  local _carte; _carte="$(prov_file_state "$PROV_UID_MAP_FILE")"
  if [[ -n "$(prov_seat_from_map)" ]]; then
    p_ok "siège : « $PROV_SEAT_LOGIN » enregistré ($PROV_UID_MAP_FILE, forge_id 1)"
  elif [[ "$_carte" != "present" && "$_carte" != "absent" ]]; then
    p_warn "siège : carte des uid $(prov_state_why "$_carte" "$PROV_UID_MAP_FILE") — rien n'est conclu sur l'enregistrement de « $PROV_SEAT_LOGIN »"
  elif [[ "$mode" != "apply" ]]; then
    p_drift "siège : « $PROV_SEAT_LOGIN » connu ($PROV_SEAT_SOURCE) mais NON enregistré — l'apply pose la ligne"
  elif prov_seat_record "$PROV_SEAT_LOGIN" "$(id -u "$PROV_SEAT_LOGIN")"; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "siège : « $PROV_SEAT_LOGIN » enregistré ($PROV_UID_MAP_FILE, forge_id 1)"
  else
    p_drift "siège : « $PROV_SEAT_LOGIN » NON enregistré dans $PROV_UID_MAP_FILE"
  fi
}

check() {
  # ⚠ LES GARDES DU CONTENEUR NE VALENT QUE POUR LA FORGE QU'ON MONTE. Docker, le compose, le nom de
  # service, « est-ce la nôtre » : quatre questions qui n'ont aucun sens sur une forge FOURNIE. Les
  # poser quand même refuserait une machine capable de travailler, pour un daemon dont ce rail-là n'a
  # pas besoin.
  if [[ "$FORGE_MONTEE" -eq 1 ]]; then
    if ! docker_endpoint; then
      p_fail "$PROV_DOCKER_WHY — la forge du poste est un CONTENEUR, il n'en existe aucune autre forme"
      verdict_check
    fi
    forge_service_known || verdict_check
    if forge_up && docker_answers && ! forge_is_ours; then
      foreign_forge_refusal
      verdict_check
    fi
  elif ! forge_up; then
    # Une forge FOURNIE qui ne répond pas est un DRIFT, pas un échec de sonde : rien n'est cassé
    # ici, c'est l'adresse qu'on nous a donnée qui est muette. Le geste appartient à qui la tient.
    # ⚠ DRIFT ET PAS WARN, ET J AI FAIT L ERREUR INVERSE EN PASSANT. « drift » ne veut pas dire
    # « apply va le corriger » — le contrat des codes dit « etat-cible non tenu », et une forge qui
    # ne repond pas est un FAIT etabli, pas une ignorance. Ce qui distingue un warn est de ne PAS
    # SAVOIR ; ici on sait, et la machine est inutilisable tant que ca dure.
    p_drift "forge FOURNIE muette ($FORGE_URL) — c'est l'adresse de FORGE_BASE_URL ; ce rail ne la monte pas, il la consomme"
    verdict_check
  fi
  if forge_up; then
    if [[ "$FORGE_MONTEE" -eq 1 ]]; then
      p_ok "forge du poste vivante ($FORGE_URL)$(forge_reach_note)"
    else
      p_ok "forge FOURNIE vivante ($FORGE_URL) — montée par quelqu'un d'autre, structurée par nous"
    fi
    if [[ -s "$PROV_MASTER_TOKEN_FILE" ]]; then
      p_ok "autorité de création présente ($PROV_MASTER_TOKEN_FILE)"
    else
      p_drift "forge vivante mais AUCUNE autorité ($PROV_MASTER_TOKEN_FILE) — l'apply la minte"
    fi
    seat_binding_report check
    case "$(forge_admin_state "$PROV_FORGE_ADMIN")" in
      admin)   p_ok "« $PROV_FORGE_ADMIN » administre la forge" ;;
      plain)   p_drift "« $PROV_FORGE_ADMIN » n'est PAS administrateur de sa propre forge — l'apply le promeut" ;;
      absent)  p_drift "« $PROV_FORGE_ADMIN » n'a pas de compte sur cette forge — l'inscription est libre, elle se fait une fois" ;;
      *)       p_warn "adminité de « $PROV_FORGE_ADMIN » non mesurable (jeton absent ou forge muette)" ;;
    esac
  else
    p_drift "aucune forge sur $FORGE_URL — l'apply monte le conteneur, l'amorce et pose sa structure"
  fi
  verdict_check
}

apply() {
  # Mêmes gardes, même raison qu'au `check` : elles portent sur le conteneur, pas sur la forge.
  if [[ "$FORGE_MONTEE" -eq 1 ]]; then
    if ! docker_endpoint; then
      p_fail "$PROV_DOCKER_WHY — forge NON montée, et elle ne peut pas l'être autrement"
      verdict_apply
    fi
    forge_service_known || verdict_apply
  elif ! forge_up; then
    # ⚠ ICI C'EST UN ECHEC, ET AU `check` C'ETAIT UN DRIFT — les deux verbes ne disent pas la même
    # chose. Constater qu'une adresse est muette n'est pas une panne ; s'engager à structurer une
    # forge qu'on ne joint pas en est une, et tout ce qui suit échouerait un geste plus loin.
    p_fail "forge FOURNIE muette ($FORGE_URL) — ce rail la consomme, il ne la monte pas ; c'est à qui la tient de la relever"
    verdict_apply
  fi
  if [[ ! -x "${LCARS_TOFU_BIN:-/usr/local/bin/tofu}" ]]; then
    p_drift "tofu absent — la structure de la forge est son territoire : joue « 46-tofu » d'abord, puis relance"
    verdict_apply
  fi
  local was_up=0; forge_up && was_up=1

  # ─── LE MONTAGE — ET LUI SEUL EST CONDITIONNEL ───────────────────────────────────────────────
  #
  # ⚠ TOUT CE QUI SUIT CE BLOC EST COMMUN AUX DEUX ÉTATS, et c'est le point du § 13 : amorcer,
  # minter l'autorité, promouvoir l'admin, poser la structure — le travail est le MÊME sur une forge
  # fournie. Ce qui change est de savoir qui possède le conteneur. Un module qui aurait dupliqué sa
  # seconde moitié pour le cas « fournie » aurait deux recettes de structure à tenir d'accord.
  if [[ "$FORGE_MONTEE" -eq 1 ]]; then
    if [[ "$was_up" -eq 1 ]] && docker_answers && ! forge_is_ours; then
      foreign_forge_refusal
      verdict_apply
    fi

    local _running; _running="$(forge_running_port)"
    if [[ -n "$_running" && "$_running" != "$PROV_FORGE_HOST_PORT" ]]; then
      p_fail "la forge du projet « $PROV_FORGE_PROJECT » tourne déjà sur le port $_running, et cette passe en demande $PROV_FORGE_HOST_PORT — je ne la déplace pas sans qu'on me le dise"
      p_fail "  une SECONDE forge      : « --forge-project <nom> » (conteneur, réseau, volumes et runner à elle)"
      p_fail "  DÉPLACER celle-ci      : « $PROV_DOCKER_BIN compose -p $PROV_FORGE_PROJECT down » d'abord, puis relance"
      verdict_apply
    fi

    if [[ "$was_up" -eq 0 ]] && port_taken "$PROV_FORGE_HOST_PORT"; then
      local holder; holder="$(port_holder "$PROV_FORGE_HOST_PORT")"
      p_fail "port $PROV_FORGE_HOST_PORT déjà pris${holder:+ par $holder}, et ce n'est PAS la forge de LCARS (elle ne répond pas sur $FORGE_URL)"
      p_fail "choisis-en un autre : PROV_FORGE_HOST_PORT=<port> — ou libère celui-ci"
      verdict_apply
    fi

    [[ "$was_up" -eq 1 ]] \
      || p_step "forge du poste : montage du conteneur Gitea (projet $PROV_FORGE_PROJECT, port $PROV_FORGE_HOST_PORT)"
    LCARS_DEVFORGE_PORT="$PROV_FORGE_HOST_PORT" LCARS_DEVFORGE_BIND="$PROV_FORGE_BIND" \
    LCARS_DEVFORGE_ROOT_URL="$PUBLIC_URL/" \
      run_quiet d compose -f "$COMPOSE_FILE" -p "$PROV_FORGE_PROJECT" up -d \
      || { p_fail "la forge ne converge pas (compose -p $PROV_FORGE_PROJECT)"; verdict_apply; }
    prov_journal_note posed_docker "$PROV_FORGE_PROJECT"
    for _ in $(seq 1 60); do forge_up && break; sleep 2; done
    forge_up || { p_fail "forge montée mais muette sur $FORGE_URL après 120 s"; verdict_apply; }
  fi

  if [[ "$FORGE_MONTEE" -eq 0 ]]; then
    p_ok "forge FOURNIE ($FORGE_URL) — rien à monter ; ce rail y pose sa structure"
  elif [[ "$was_up" -eq 1 ]]; then
    p_ok "forge du poste vivante et convergée ($FORGE_URL)$(forge_reach_note)"
  else
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "forge du poste montée ($FORGE_URL)$(forge_reach_note)"
  fi

  write_atomic "$PROV_TOKENS_DIR/forge.url" 0644 "root:$PROV_FLEET_GROUP" <<<"$FORGE_URL" \
    || { p_fail "adresse de la forge non posée ($PROV_TOKENS_DIR/forge.url)"; verdict_apply; }
  write_atomic "$PROV_TOKENS_DIR/forge.public.url" 0644 "root:$PROV_FLEET_GROUP" <<<"$PUBLIC_URL" \
    || { p_fail "adresse publique de la forge non posée ($PROV_TOKENS_DIR/forge.public.url)"; verdict_apply; }

  [[ -s "$PROV_MASTER_TOKEN_FILE" ]] && reset_admin_password_if_asked 1

  if [[ ! -s "$PROV_MASTER_TOKEN_FILE" ]]; then
    p_step "forge du poste : compte d'administration « $PROV_FORGE_ADMIN » et jeton master"
    local pw err rc; pw="$(new_password)"
    err="$(mktemp "${TMPDIR:-/tmp}/forge-admin.XXXXXX")"
    rc=0
    d exec -u git "$FORGE_CONTAINER" gitea admin user create \
      --username "$PROV_FORGE_ADMIN" --password "$pw" \
      --email "$PROV_FORGE_ADMIN@lcars.local" --admin --must-change-password=false \
      >/dev/null 2>"$err" || rc=$?

    if [[ "$rc" -eq 0 ]]; then
      announce_password "$PROV_FORGE_ADMIN" "$pw"
    elif grep -qiE 'already exist|user already|login name.*taken' "$err" 2>/dev/null; then
      p_ok "compte « $PROV_FORGE_ADMIN » déjà présent (son mot de passe est un hash, il n'est pas relisible)"
      p_warn "besoin d'un mot de passe pour t'y connecter ? « PROV_FORGE_ADMIN_RESET=1 » sur un apply en pose un neuf et l'affiche"
    else
      p_fail "création du compte « $PROV_FORGE_ADMIN » REFUSÉE par la forge : $(tr -d '\r' < "$err" | grep -v '^$' | tail -3 | tr '\n' ' ')"
      rm -f "$err"
      verdict_apply
    fi
    rm -f "$err"

    reset_admin_password_if_asked "$rc"
    docker_stream_ok "$FORGE_CONTAINER" || {
      p_fail "le daemon docker répond aux lectures mais rend du VIDE sur « exec » (relais amputé) — rien ne peut être capturé depuis $FORGE_CONTAINER, et la forge n'y est pour rien. Vise la socket Docker Desktop directement : DOCKER_HOST=unix://$(_docker_mount_sock)"
      verdict_apply
    }
    local tok
    tok="$(d exec -u git "$FORGE_CONTAINER" gitea admin user generate-access-token \
             --username "$PROV_FORGE_ADMIN" --token-name "poste-$(date +%s)" --scopes all --raw \
             2>/dev/null | tail -n1 | tr -d '[:space:]')"
    [[ -n "$tok" ]] || { p_fail "la forge n'a rendu aucun jeton master pour $PROV_FORGE_ADMIN"; verdict_apply; }
    write_atomic "$PROV_MASTER_TOKEN_FILE" 0600 "$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" <<<"$tok" \
      || { p_fail "jeton master non posé ($PROV_MASTER_TOKEN_FILE)"; verdict_apply; }
    p_chg "autorité de création posée ($PROV_MASTER_TOKEN_FILE, $PROV_AUTHORITY_USER seul)"
  else
    p_ok "autorité de création déjà posée ($PROV_MASTER_TOKEN_FILE)"
  fi

  #    ⚠ IL N'EXISTE PAS DE `gitea admin user set-admin` : la CLI sait CRÉER un admin, pas en
  #    promouvoir un. La promotion passe par l'API, avec le jeton master — donc elle n'est possible
  #    que s'il existe déjà une autorité, ce qui est exactement le cas de figure visé.
  case "$(forge_admin_state "$PROV_FORGE_ADMIN")" in
    admin)
      p_ok "« $PROV_FORGE_ADMIN » administre la forge" ;;
    absent)
      p_warn "« $PROV_FORGE_ADMIN » n'a pas de compte sur cette forge — l'inscription est libre, elle se fait une fois puis ce module le promeut" ;;
    plain)
      if forge_promote_admin "$PROV_FORGE_ADMIN"; then
        PROV_CHANGED=$((PROV_CHANGED + 1))
        p_chg "« $PROV_FORGE_ADMIN » promu administrateur de la forge (⚖ D7 : le siège, c'est celui qui installe)"
      else
        p_fail "« $PROV_FORGE_ADMIN » n'a pas pu être promu administrateur — le jeton master de $PROV_MASTER_TOKEN_FILE porte-t-il encore l'adminité ?"
      fi ;;
    *)
      p_warn "adminité de « $PROV_FORGE_ADMIN » non mesurable (forge muette ou jeton absent) — rien n'a été tenté" ;;
  esac

  # 3. LE SEED. Il ne se REGÉNÈRE pas : le provider n'écrit pas le password d'un compte existant
  #    (mesure 2026-08-16), donc un seed neuf donnerait un fichier qui ne correspond plus aux
  #    comptes et le mint des jetons de rôle partirait en 401.
  if [[ ! -s "$SEED_FILE" ]]; then
    local seed; seed="$(head -c 18 /dev/urandom | base64 | tr -d '/+=' | cut -c1-20)"
    [[ -n "$seed" ]] || { p_fail "seed non générable (/dev/urandom illisible ?)"; verdict_apply; }
    write_atomic "$SEED_FILE" 0600 "$PROV_AUTHORITY_USER:$PROV_AUTHORITY_USER" <<<"$seed" \
      || { p_fail "seed non posé ($SEED_FILE)"; verdict_apply; }
    p_chg "seed des comptes posé ($SEED_FILE, $PROV_AUTHORITY_USER seul)"
  else
    p_ok "seed des comptes déjà posé ($SEED_FILE)"
  fi

  local tree; tree="$(repo_root)/fleet"
  p_step "outillage mix pour dériver le roster ($PROV_HUMAN)"
  run_quiet as_human env -C "$tree" mix local.hex --force \
    || { p_fail "hex non installable pour $PROV_HUMAN — le roster ne peut pas se dériver"; verdict_apply; }
  run_quiet as_human env -C "$tree" mix local.rebar --force \
    || { p_fail "rebar non installable pour $PROV_HUMAN — le roster ne peut pas se dériver"; verdict_apply; }
  run_step "dépendances Elixir" -- as_human env -C "$tree" mix deps.get \
    || { p_fail "dépendances Elixir non récupérables ($tree) — sans elles l'arbre ne compile pas"; verdict_apply; }

  local ref_catalogue refout
  refout="$(mktemp "${TMPDIR:-/tmp}/prov-catroot.XXXXXX")" \
    || { p_fail "tmp impossible pour la dérivation du catalogue"; verdict_apply; }
  as_human env -C "$tree" LCARS_TOOL_EVAL=1 mix run --no-start \
    -e 'IO.puts("LCARS_CATALOGUE_ROOT=" <> Fleet.Catalogue.root())' >"$refout" 2>&1 || true
  ref_catalogue="$(grep -m1 '^LCARS_CATALOGUE_ROOT=' "$refout" | cut -d= -f2- || true)"
  if [[ ! -d "$ref_catalogue" ]]; then
    p_fail "catalogue de référence introuvable dans $tree (rendu : « ${ref_catalogue:-<rien>} »)"
    p_fail "dernières lignes de mix : $(tail -n3 "$refout" | tr '\n' '·')"
    rm -f "$refout"; verdict_apply
  fi
  rm -f "$refout"

  local enroll; enroll="$(mktemp -d "${TMPDIR:-/tmp}/prov-enroll.XXXXXX")"
  chown "$PROV_HUMAN" "$enroll" \
    || { p_fail "dossier de roster non cédé à $PROV_HUMAN ($enroll)"; rm -rf "$enroll"; verdict_apply; }
  run_step "roster du catalogue" -- as_human env LCARS_TOOL_EVAL=1 "$tree/etc/enroll-catalogue.sh" --tofu-dir "$enroll" --repo "$tree" --catalogue "$ref_catalogue" \
    || { p_fail "roster non dérivable de l'arbre ($tree) — relis la sortie, elle nomme l'étape"; rm -rf "$enroll"; verdict_apply; }
  [[ -s "$enroll/roles.auto.tfvars.json" ]] \
    || { p_fail "roster vide — la recette serait appliquée sans comptes"; rm -rf "$enroll"; verdict_apply; }
  p_step "forge du poste : pose de la structure (orgs, comptes de rôle, teams, dépôt modèle)"

  local recipe; recipe="$(mktemp -d "${TMPDIR:-/tmp}/prov-recipe.XXXXXX")"
  cp -a "$(repo_root)/fleet/deploy/deps/." "$recipe/" \
    || { p_fail "recette non copiable ($(repo_root)/fleet/deploy/deps)"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  cp "$enroll/roles.auto.tfvars.json" "$recipe/roles.auto.tfvars.json" \
    || { p_fail "roster non déposé dans la recette"; rm -rf "$recipe" "$enroll"; verdict_apply; }

  rm -rf "$recipe/.terraform" "$recipe/instance/.terraform"
  local m
  for m in instance .; do
    TF_CLI_CONFIG_FILE="${LCARS_TOFU_DIR:-/opt/lcars/tofu}/tofurc" \
      run_quiet env -C "$recipe/$m" tofu init -input=false -no-color \
      || { p_fail "recette non initialisable ($m) — le miroir de providers couvre-t-il cette recette ? (46-tofu)"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  done


  local rc=0 tf_out
  tf_out="$(mktemp "${TMPDIR:-/tmp}/prov-tofu.XXXXXX")"
  run_step "structure de la forge" -- env \
    LCARS_PRIVATE_DIR="$PROV_TOKENS_DIR" \
    `# ⚠ LE DÉTENTEUR VOYAGE AVEC LE CHEMIN, ET LES SÉPARER LES FAIT DIVERGER. « put_secret » pose` \
    `# désormais un PROPRIÉTAIRE sur ce qu'il écrit ; sans cette ligne il retomberait sur son défaut` \
    `# compilé pendant que ce module, lui, suivrait PROV_AUTHORITY_USER. Sur une boîte dont le compte` \
    `# de service porte un autre nom, le secret naîtrait détenu par un compte qui n'existe pas — et` \
    `# le service refuserait de démarrer sur un fichier que la boîte vient d'écrire.` \
    LCARS_AUTHORITY_USER="$PROV_AUTHORITY_USER" \
    FORGE_BASE_URL="$FORGE_URL" \
    `# ⚠ LA DESTINATION VOYAGE, LE NOM NON. Ce module dit « ce déploiement est jetable » ; QUEL` \
    `# humain de démonstration cela pose est la décision de « forge-gestures.sh », seul déclarant du` \
    `# nom (deux témoins de ce fichier le gardent, et ils ont attrapé la première version de cette` \
    `# ligne — elle écrivait un défaut « lcars » ici, donc une seconde autorité).` \
    ${PROV_DISPOSABLE:+LCARS_DISPOSABLE=1} \
    LCARS_RECIPE_DIR="$recipe" \
    LCARS_DEMO_CATALOGUE="$(repo_root)/catalogues/web-demo" \
    LCARS_REFERENCE_CATALOGUE="$ref_catalogue" \
    TF_CLI_CONFIG_FILE="${LCARS_TOFU_DIR:-/opt/lcars/tofu}/tofurc" \
    bash "$(repo_root)/fleet/services/forge-gestures.sh" apply 2>&1 | tee "$tf_out" || rc="${PIPESTATUS[0]}"
  rm -rf "$recipe" "$enroll"
  [[ "$rc" -eq 0 ]] \
    || { rm -f "$tf_out"; p_fail "structure NON posée (rc=$rc) — relis la sortie, rien n'est supposé"; verdict_apply; }

  # ⚠ « APPLIQUÉ » N'EST PAS « CHANGÉ », ET LE CODE DE SORTIE NE LES DISTINGUE PAS. La recette est
  # idempotente : elle rend 0 aussi bien après avoir tout posé qu'après n'avoir rien eu à faire.
  # `tofu` le DIT, et c'est la seule source qui le sache : « Apply complete! Resources: N added,
  # M changed, K destroyed », une ligne par module de la recette. Illisible (format changé, sortie
  # tronquée) → on n'invente pas : on ne compte rien et on le nomme.
  local moved
  moved="$(grep -c -E 'Apply complete!.*Resources: [1-9][0-9]* (added|changed|destroyed)|, [1-9][0-9]* (changed|destroyed)' "$tf_out" 2>/dev/null || true)"
  rm -f "$tf_out"
  if [[ "${moved:-0}" -gt 0 ]]; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "structure de la forge posée — 50-forge peut minter les jetons de rôle"
  else
    p_ok "structure de la forge déjà conforme — rien à poser"
  fi

  seat_binding_report apply
  verdict_apply
}

case "${1:?usage: 48-forge-host.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
