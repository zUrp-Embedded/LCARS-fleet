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
# ⚠ LA TABLE NOMME DES QU'ELLE EXISTE, ET `PROV_HUMAN` N'EST QUE LA SEMENCE DU PREMIER PASSAGE.
# Les deux ne sont pas des sources concurrentes : `PROV_HUMAN` sert le seul cas où rien ne préexiste,
# et dès que la ligne `forge_id=1` est posée c'est elle qui dit qui est le siège. Sans cet ordre, un
# renommage côté forge laissait ce module continuer à promouvoir, à reposer le mot de passe et à
# sonder l'adminité d'un compte que plus rien d'autre ne désignait — `seat_binding_report` nommait
# la divergence, et le reste du module travaillait quand même sur l'autre nom.
#
# Un `PROV_FORGE_ADMIN` posé explicitement par l'opérateur l'emporte toujours : `:=` ne remplit que
# le vide, et la divergence qu'il créerait est justement ce que le rapport de siège dit.
: "${PROV_FORGE_ADMIN:=$(prov_seat_from_map)}"
: "${PROV_FORGE_ADMIN:=$PROV_HUMAN}"            # le compte qui ADMINISTRE la forge — l'opérateur
: "${PROV_DOCKER_BIN:=docker}"

#   PROV_FORGE_BIND       l'interface sur laquelle docker PUBLIE le port. C'est une décision de
#                         sécurité : `127.0.0.1` = cette machine seule, `0.0.0.0` = le réseau.
#   PROV_FORGE_ADVERTISE  l'adresse qu'on ÉCRIT dans `ROOT_URL`. Gitea s'en sert pour tous ses
#                         liens, ses URLs de clone et ses retours OAuth. Ouvrir le bind sans la
#                         bouger donne une UI joignable dont chaque lien pointe sur la loopback du
#                         visiteur — cassée depuis toute autre machine.
# Fermer reste possible — `PROV_FORGE_BIND=127.0.0.1` — mais c'est le geste, pas le défaut, et il
# prive la machine de sa CI.
: "${PROV_FORGE_BIND:=0.0.0.0}"
: "${PROV_FORGE_ADVERTISE:=}"
advertise_addr "${PROV_FORGE_ADVERTISE:-$PROV_FORGE_BIND}"
PROV_FORGE_ADVERTISE="$PROV_ADVERTISE"
PROV_FORGE_ADVERTISE_WHY="$PROV_ADVERTISE_WHY"

FORGE_CONTAINER="${PROV_FORGE_PROJECT}-gitea-1"
SEED_FILE="$PROV_TOKENS_DIR/forge-seed.pass"
COMPOSE_FILE="$(repo_root)/fleet/deploy/docker/forge-compose.yml"

# ⚠ BORNE AU BLOC `services:`. `forge-compose.yml` porte aussi un bloc `volumes:` dont les entrees
# sont au MEME indent ; un balayage du fichier entier ne rendrait le bon nom que parce que
# `services:` vient en premier — vert par ordre de fichier, exactement ce qu'on repare. Meme forme
# ⚠ FAIL-CLOSED SUR L'ANCRE. Un compose illisible ne rend pas « rien a filtrer » : il rendrait un
# filtre VIDE, donc une sonde qui ne reconnait plus aucune forge, donc un refus qui accuse la
# machine au lieu du fichier. On meurt ici, en nommant le fichier.
# ⚠ `|| true` OBLIGATOIRE, ET SON ABSENCE A PRODUIT UN MORT SILENCIEUX. Ce module tourne sous
# `set -euo pipefail` : une assignation dont la substitution echoue TUE le script sur place, sans
# un mot. Compose absent -> `sed` sort en 2 -> le module mourait avant d'avoir rien imprime.
FORGE_SERVICE="$(sed -nE '/^services:/,/^[a-z]/{ s/^  ([a-z][a-z0-9_-]*):[[:space:]]*$/\1/p }' "$COMPOSE_FILE" 2>/dev/null | head -n1 || true)"
FORGE_CONTAINER="${PROV_FORGE_PROJECT}-${FORGE_SERVICE}-1"

# ⚠ LE REFUS NE SE POSE PAS ICI, ET MA PREMIERE ECRITURE LE POSAIT. Un `p_die` au chargement tue le
# module AVANT qu'il ait pu constater ce qui compte davantage : sans daemon docker, ce module n'a
# rien a faire du nom d'un service, et son verdict utile est « aucun daemon ». Mesure : le temoin
forge_service_known() {
  [[ -n "$FORGE_SERVICE" ]] && return 0
  p_fail "aucun service lisible dans $COMPOSE_FILE — le nom du conteneur et le filtre docker en derivent tous les deux, et sans lui la sonde ne reconnaitrait AUCUNE forge"
  return 1
}
# ⚠ DEUX URLS, ET CHACUNE A UN SEUL LECTEUR LÉGITIME.
#   LOCAL_URL   par où CE module et ses voisins parlent à la forge — toujours la loopback, parce
#               qu'ils tournent sur la machine. C'est elle qui va dans `forge.url`, lue par
#               `50-forge` et `55-deck-oidc`, et c'est elle que sonde `forge_up`. Elle ne dépend pas
#               de ce qu'on publie : une forge ouverte au réseau reste joignable en local.
#   PUBLIC_URL  ce que Gitea écrit dans ses liens, ses URLs de clone et ses retours OAuth. C'est
#               l'adresse qu'un TIERS compose — un navigateur, un `git clone`, un conteneur de job.
LOCAL_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"
PUBLIC_URL="http://${PROV_FORGE_ADVERTISE}:${PROV_FORGE_HOST_PORT}"

d() { "$PROV_DOCKER_BIN" "$@"; }
forge_up() { curl -fsS -m 5 -o /dev/null "$LOCAL_URL/api/v1/version" 2>/dev/null; }

# Le port sur lequel la forge de CE projet publie AUJOURD'HUI, ou vide si elle ne tourne pas.
# ⚠ ON DEMANDE A DOCKER, PAS AU PORT. `forge_up` sonde l'adresse qu'on VEUT ; elle ne dit rien de
# celle qu'on a. Les deux questions se confondent tant que le port ne change pas, et divergent
# exactement quand il change — c'est-a-dire quand la reponse compte.
forge_running_port() {
  d ps --filter "label=com.docker.compose.project=$PROV_FORGE_PROJECT" \
       --filter "label=com.docker.compose.service=$FORGE_SERVICE" \
       --format '{{.Ports}}' 2>/dev/null \
    | sed -n 's/.*:\([0-9]\{1,5\}\)->3000\/tcp.*/\1/p' | head -n1
}

# ⚠ « QUELQUE CHOSE RÉPOND » N'EST PAS « NOTRE FORGE RÉPOND », et la nuance a coûté une install
forge_is_ours() { [[ "$(forge_running_port)" == "$PROV_FORGE_HOST_PORT" ]]; }

# ⚠ ET LA QUESTION N'A DE SENS QUE SI DOCKER PARLE. Sans lui `forge_running_port` rend vide, ce qui
# est indiscernable de « la forge n'est pas à nous » : refuser là ferait échouer un rail sain sur une
# sonde muette.
docker_answers() { d ps --format '{{.ID}}' >/dev/null 2>&1; }

foreign_forge_refusal() {
  p_fail "une forge répond sur $LOCAL_URL, mais AUCUN conteneur du projet « $PROV_FORGE_PROJECT » ne publie $PROV_FORGE_HOST_PORT — ce n'est pas la forge de cette machine"
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

# Random 10 alphabétiques : assez pour n'être pas devinable sur un LAN, assez court pour être RECOPIÉ
# À LA MAIN sans se tromper — c'est un mot de passe qu'un humain note sur un papier, une fois.
new_password() { head -c 200 /dev/urandom | tr -dc 'A-Za-z' | cut -c1-10; }

announce_password() { # announce_password <login> <mot de passe>
  prov_announce_credential "forge du poste — compte d'administration" "$1" "$2"
}

# ⚠ LE SEED N'EST PAS UN MOT DE PASSE D'HUMAIN, ET IL EN TENAIT LIEU. La recette pose
# `password = var.seed_password` sur TOUT ce qu'elle crée : les comptes de rôle, le compte système,
# et l'humain intégré (`deps/instance/accounts.tf:121`). Le credential avec lequel une personne se
# connecte à la forge était donc le MÊME que celui du compte qui signe les marqueurs système —
# le communiquer, c'était ouvrir les dix.
# ⚠ POSÉ UNE FOIS, PAS À CHAQUE CONVERGENCE. La recette est idempotente et rend 0 au second tour :
# son code de sortie ne distingue pas « je viens de créer ce compte » de « il était déjà là ». Sans
# marqueur, chaque apply reposait donc le mot de passe d'une personne derrière son dos, et invalidait
# celui qu'elle avait noté au run précédent.
# Le marqueur porte le LOGIN, pas un booléen : si l'humain intégré change de nom, c'est un autre
# compte, et il a droit au sien. `PROV_FORGE_ADMIN_RESET` passe outre — c'est la porte par laquelle
# un opérateur qui a perdu ses identifiants en redemande.
BUILTIN_PW_MARK="$PROV_TOKENS_DIR/forge-builtin-human.posed"

announce_builtin_human_password() {
  local login tok pw code
  # ⚠ ON DEMANDE LE NOM, ON NE LE DEVINE NI NE LE RECOPIE. C'est le défaut de `forge-gestures.sh` qui
  # a été appliqué à la recette : ce module doit poser un mot de passe sur CE compte-là. Un littéral
  login="$(bash "$(repo_root)/fleet/services/forge-gestures.sh" builtin-human 2>/dev/null || true)"
  [[ -n "$login" ]] || { p_warn "mot de passe forge de l'humain intégré NON posé : son nom est indéterminable"; return 0; }

  if [[ -z "${PROV_FORGE_ADMIN_RESET:-}" ]] \
     && [[ "$(cat "$BUILTIN_PW_MARK" 2>/dev/null || true)" == "$login" ]]; then
    p_ok "mot de passe forge de « $login » déjà posé — non rejoué (« PROV_FORGE_ADMIN_RESET=1 » en repose un)"
    return 0
  fi

  tok="$(read_token "$PROV_MASTER_TOKEN_FILE")"
  [[ -n "$tok" ]] || { p_warn "mot de passe forge de « $login » NON posé : aucun jeton master lisible"; return 0; }

  pw="$(new_password)"
  # ⚠ RIEN NE PASSE PAR ARGV, NI LE JETON NI LE MOT DE PASSE — `-d` les mettrait dans la ligne de
  # commande, lisible dans /proc de tout l'hôte pendant l'appel. Cicatrice 6-141, déjà payée deux
  # fois sur des credentials moins puissants ; le fichier de config de curl accepte `header =` ET
  # `data =`, donc les deux voyagent par stdin.
  code="$(printf 'header = "Authorization: token %s"\nheader = "Content-Type: application/json"\nrequest = "PATCH"\ndata = "{\\"login_name\\":\\"%s\\",\\"source_id\\":0,\\"password\\":\\"%s\\",\\"must_change_password\\":false}"\n' \
            "$tok" "$login" "$pw" \
          | curl -K - -s -o /dev/null -m 15 -w '%{http_code}' "$LOCAL_URL/api/v1/admin/users/$login" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    PROV_CHANGED=$((PROV_CHANGED + 1))
    prov_announce_credential "forge du poste — humain de fleet" "$login" "$pw"
    # Le marqueur s'écrit APRÈS la pose, jamais avant : posé d'avance, il ferait sauter la pose au
    # run suivant sur la foi d'un geste qui a échoué.
    write_atomic "$BUILTIN_PW_MARK" 0600 "root:root" <<<"$login" \
      || p_warn "marqueur non écrit ($BUILTIN_PW_MARK) — le prochain apply reposera ce mot de passe"
  else
    p_warn "mot de passe forge de « $login » NON posé (HTTP ${code:-aucune réponse}) — son compte garde celui de la création"
  fi
}

# La forge ne garde qu'un HASH : un mot de passe perdu ne se relit pas, il se remplace. Mais le
# remplacer d'office à chaque apply casserait tout ce qui s'authentifie avec — sans le dire, et sur
# le compte qui administre. Le geste se demande donc explicitement, et il n'a de sens que quand le
# compte EXISTE DÉJÀ (une création vient d'afficher le sien).
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

  announce_builtin_human_password
}

# Rend `admin`, `plain`, `absent`, ou `unknown` — quatre états, parce que « pas admin » et « pas de
# compte » appellent deux gestes différents, et « je n'ai pas pu demander » n'en appelle aucun.
forge_admin_state() { # forge_admin_state <login>
  local out body code
  [[ -n "$(read_token "$PROV_MASTER_TOKEN_FILE")" ]] || { echo unknown; return 0; }
  out="$(forge_curl "$PROV_MASTER_TOKEN_FILE" -sS -m 10 -w '\n%{http_code}' "$LOCAL_URL/api/v1/users/$1" 2>/dev/null)" \
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
  # ⚠ NI LE JETON NI LE CORPS PAR `argv` (6-141) : `-K -` fait lire à curl son en-tête ET sa donnée
  # sur stdin. `-H`/`-d` les mettraient dans la ligne de commande, lisible dans `/proc` de tout
  # l'hôte pendant l'appel. La même forme est déjà en place trois fonctions plus haut.
  printf 'header = "Authorization: token %s"\nheader = "Content-Type: application/json"\nrequest = "PATCH"\ndata = "{\\"admin\\":true,\\"login_name\\":\\"%s\\",\\"source_id\\":0}"\n' \
    "$tok" "$1" \
    | curl -K - -fsS -m 15 "$LOCAL_URL/api/v1/admin/users/$1" >/dev/null 2>&1
}

# La derivation est celle de la lib, la MEME que la boite appelle : une seule autorite sur « qui est
# le siege », donc pas de second cadran a tenir accorde.
# UNE SEULE FONCTION POUR LES DEUX VERBES, et le mode ne change QUE l'ecriture. Deux blocs auraient
# diverge : le doctor aurait fini par mesurer autre chose que ce que l'apply converge.
seat_binding_report() { # seat_binding_report <check|apply>
  local mode="${1:?}"
  prov_seat_binding "$PROV_FORGE_ADMIN"

  case "$PROV_SEAT_BINDING" in
    diverge)
      # Le desaccord ne se repare pas ici : renommer un compte unix ou un compte forge est une
      # decision d'operateur, pas une convergence. On le NOMME, et le module derive.
      p_drift "siège : « $PROV_FORGE_ADMIN » côté unix, « $PROV_SEAT_LOGIN » côté $PROV_SEAT_SOURCE — deux acteurs pour un rôle, et le lien n'est PAS enregistré tant qu'ils ne s'accordent pas"
      return 0
      ;;
    unknown)
      p_warn "siège : ni compte unix nommé, ni #1 lisible sur la forge — le lien n'est pas mesurable"
      return 0
      ;;
  esac

  # sur ce rail `PROV_FORGE_ADMIN` vaut `PROV_HUMAN`, donc le candidat n'est jamais vide, donc les
  # trois verdicts atteignables portent un login qui A un compte unix — ou n'enregistrent rien
  # (`diverge`). Un `|| 1000` n'aurait servi aucun etat reel, et aurait ecrit l'uid de quelqu'un
  # d'autre dans la table que le convergeur relit.
  if [[ -n "$(prov_seat_from_map)" ]]; then
    p_ok "siège : « $PROV_SEAT_LOGIN » enregistré ($PROV_UID_MAP_FILE, forge_id 1)"
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
  if ! docker_endpoint; then
    p_fail "$PROV_DOCKER_WHY — la forge du poste est un CONTENEUR, il n'en existe aucune autre forme"
    verdict_check
  fi
  forge_service_known || verdict_check
  if forge_up && docker_answers && ! forge_is_ours; then
    foreign_forge_refusal
    verdict_check
  fi
  if forge_up; then
    p_ok "forge du poste vivante ($LOCAL_URL)$(forge_reach_note)"
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
    p_drift "aucune forge sur $LOCAL_URL — l'apply monte le conteneur, l'amorce et pose sa structure"
  fi
  verdict_check
}

apply() {
  if ! docker_endpoint; then
    p_fail "$PROV_DOCKER_WHY — forge NON montée, et elle ne peut pas l'être autrement"
    verdict_apply
  fi
  forge_service_known || verdict_apply
  # ⚠ CE MODULE NE DÉPEND PLUS D'UNE IMAGE, IL DÉPEND DE `46-tofu`. Il exigeait ici la présence de
  # `lcars-fleet:2` — 1,18 Go bâtis pour exécuter 100 ko de recette dans un conteneur jetable, sur un
  # rail qui ne démarre jamais cette image. Ce qu'elle apportait de réel (une version figée, des
  # providers hors-ligne) est posé SUR la machine, deux crans plus tôt.
  # On sonde le BINAIRE et non la version : `46-tofu` est l'autorité du pin, et re-juger ici en
  # ferait un second. Ce qui manque à ce module, c'est un tofu — pas un avis sur lequel.
  if [[ ! -x "${LCARS_TOFU_BIN:-/usr/local/bin/tofu}" ]]; then
    p_drift "tofu absent — la structure de la forge est son territoire : joue « 46-tofu » d'abord, puis relance"
    verdict_apply
  fi
  # `compose up -d` est la convergence, pas le montage : sur une déclaration inchangée c'est un
  # no-op d'une seconde ; sur une déclaration modifiée il recrée. On l'appelle donc TOUJOURS, et
  # c'est `forge_up` AVANT qui dit si l'on a monté ou simplement reconvergé.
  local was_up=0; forge_up && was_up=1

  # ⚠ LE PORT EST SONDÉ AVANT LE MONTAGE, ET LE VERDICT NOMME L'OCCUPANT.
  # ⚠ « PRIS PAR NOUS » N'EST PAS « PRIS PAR UN AUTRE ». `forge_up` vient de répondre : si NOTRE
  # forge écoute, le port est légitimement occupé et refuser ici casserait l'idempotence — c'est le
  # cas NOMINAL d'un second passage. On ne refuse que si le port est pris ET que la forge ne
  # répond pas.
  # ⚠ CHANGER LE PORT SANS CHANGER LE PROJET DÉPLACE LA FORGE, IL N'EN AJOUTE PAS UNE. `compose up`
  # sur le même projet RECRÉE le conteneur avec le nouveau mapping : les volumes suivent, donc rien
  # n'est perdu — mais l'ancienne adresse cesse de répondre, et tout ce qui la pointait devient
  # périmé jusqu'à la prochaine convergence (`forge.url`, la config du runner, le callback OIDC).
  # Les deux gestes sont nommés parce qu'ils sont deux INTENTIONS différentes, et que refuser sans
  # les distinguer laisserait l'opérateur deviner laquelle on lui refuse.
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
    p_fail "port $PROV_FORGE_HOST_PORT déjà pris${holder:+ par $holder}, et ce n'est PAS la forge de LCARS (elle ne répond pas sur $LOCAL_URL)"
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
  forge_up || { p_fail "forge montée mais muette sur $LOCAL_URL après 120 s"; verdict_apply; }
  if [[ "$was_up" -eq 1 ]]; then
    p_ok "forge du poste vivante et convergée ($LOCAL_URL)$(forge_reach_note)"
  else
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "forge du poste montée ($LOCAL_URL)$(forge_reach_note)"
  fi

  write_atomic "$PROV_TOKENS_DIR/forge.url" 0644 "root:$PROV_FLEET_GROUP" <<<"$LOCAL_URL" \
    || { p_fail "adresse de la forge non posée ($PROV_TOKENS_DIR/forge.url)"; verdict_apply; }
  write_atomic "$PROV_TOKENS_DIR/forge.public.url" 0644 "root:$PROV_FLEET_GROUP" <<<"$PUBLIC_URL" \
    || { p_fail "adresse publique de la forge non posée ($PROV_TOKENS_DIR/forge.public.url)"; verdict_apply; }

  # ⚠ LA REPOSE VIT HORS DE LA GARDE DU JETON MASTER, ET C'EST TOUT L'INTÉRÊT. Le bloc ci-dessous
  # ne s'exécute que sur une forge SANS jeton master — donc une seule fois dans la vie d'une
  # machine. Un opérateur qui a perdu son mot de passe est, par construction, toujours après ce
  # moment-là : une repose enfermée dedans serait inerte exactement quand on en a besoin.
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

    # ⚠ TROIS SORTIES, PAS DEUX, ET LA CONFUSION SE PAYAIT EN COMPTE INEXISTANT. Cette branche
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
    # module. Un secret dont la fermeture dépend d'un module qui n'a pas encore tourné est ouvert
    # pendant l'intervalle, et ouvert tout court le jour où ce module rend la main plus tôt.
    # Le seul lecteur légitime est `catalogue-executor.py`, qui tourne sous `lcars-authority`
    # (`64-services`, `User=$AUTHORITY_USER`) : personne d'autre n'a besoin de ce fichier, donc
    # personne d'autre ne doit pouvoir l'ouvrir — root compris, qui n'en est que le dernier recours.
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

  # LA RACINE DU CATALOGUE, DEMANDÉE À SON AUTORITÉ — et elle sert DEUX fois : au roster ci-dessous,
  # et au dépôt de référence après la structure.
  # ⚠ `|| true` OBLIGATOIRE, ET SON ABSENCE A TUÉ CE MODULE EN SILENCE. Le module tourne sous
  # `set -euo pipefail` : avec `pipefail`, un `mix` qui échoue fait échouer TOUT le pipeline, donc
  # l'affectation, donc `set -e` abat le shell — AVANT la garde juste en dessous, qui est
  # précisément là pour dire ce qui manque.
  # ⚠ ON ÉTIQUETTE LA RÉPONSE, ON NE DEVINE PAS QUELLE LIGNE C'EST. `mix` écrit son avancement sur
  # STDOUT — « Compiling 214 files », « Generated lcars_fleet app » — mêlé à ce que le script
  # imprime. Un `tail -n1` prend donc la dernière ligne de BAVARDAGE quand il y en a après, et rien
  # du tout quand la compilation échoue.
  # ⚠ ET LA SORTIE NE SE JETTE PAS. `2>/dev/null` effaçait la seule chose qui aurait nommé la cause
  # du vide. On la garde, et l'échec en cite la fin : un module qui échoue doit dire POURQUOI, pas
  # seulement QUE.
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

  # LA RECETTE SE JOUE SUR UNE COPIE, JAMAIS DANS LE CHECKOUT. Le conteneur recevait le roster par
  local recipe; recipe="$(mktemp -d "${TMPDIR:-/tmp}/prov-recipe.XXXXXX")"
  cp -a "$(repo_root)/fleet/deploy/deps/." "$recipe/" \
    || { p_fail "recette non copiable ($(repo_root)/fleet/deploy/deps)"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  cp "$enroll/roles.auto.tfvars.json" "$recipe/roles.auto.tfvars.json" \
    || { p_fail "roster non déposé dans la recette"; rm -rf "$recipe" "$enroll"; verdict_apply; }

  # ⚠ ET LE `.terraform/` DE L'ARBRE NE VIENT PAS AVEC. `46-tofu` en laisse un dans le dépôt — c'est
  # son témoin de miroir complet, et il est gitignoré — mais il décrit un répertoire À SON CHEMIN.
  # Le recopier ailleurs, c'est hériter d'un état dont on ne sait pas ce qu'il pointe. On repart
  # d'une init propre : hors-ligne, elle coûte une seconde.
  # ⚠ ET IL FAUT L'INIT : `forge-gestures.sh apply` appelle `tofu apply` NU, sans init préalable —
  # dans l'image, le Dockerfile l'avait joué AU BUILD (« LE TEMOIN DU LOT est le `tofu init` en fin
  # de RUN »). En sortant du conteneur, on hérite de cette dette : sans ce geste, l'apply échoue sur
  # des providers non installés. Le geste n'est pas modifié — la boîte marche, et un init ajouté
  # là-bas irait sur le réseau si sa tofurc ne suivait pas.
  rm -rf "$recipe/.terraform" "$recipe/instance/.terraform"
  local m
  for m in instance .; do
    TF_CLI_CONFIG_FILE="${LCARS_TOFU_DIR:-/opt/lcars/tofu}/tofurc" \
      run_quiet env -C "$recipe/$m" tofu init -input=false -no-color \
      || { p_fail "recette non initialisable ($m) — le miroir de providers couvre-t-il cette recette ? (46-tofu)"; rm -rf "$recipe" "$enroll"; verdict_apply; }
  done

  # Et les deux échecs sont NON FATAUX par conception (une forge sans démo reste une forge). En
  # sortant du conteneur sans les recâbler, on obtenait donc une forge structurée mais VIDE des deux
  # dépôts, sans qu'aucun verdict ne baisse. C'est la forme d'échec la plus chère : un succès qui
  # dit vrai sur ce qu'il a fait, et rien sur ce qu'il n'a pas fait.

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
    FORGE_BASE_URL="$LOCAL_URL" \
    LCARS_RECIPE_DIR="$recipe" \
    LCARS_DEMO_CATALOGUE="$(repo_root)/catalogues/web-demo" \
    LCARS_REFERENCE_CATALOGUE="$ref_catalogue" \
    TF_CLI_CONFIG_FILE="${LCARS_TOFU_DIR:-/opt/lcars/tofu}/tofurc" \
    `# ⚠ AUCUN « LCARS_BUILTIN_HUMAN » ICI, ET SON ABSENCE EST LA DÉCISION. Ce module a porté deux` \
    `# fois de suite le mauvais nom sur cette ligne : d'abord SUDO_USER — donc l'OPÉRATEUR, que la` \
    `# recette pose en admin=false, et qui devenu le #1 de la forge en était le DERNIER admin :` \
    `# « can not delete the last admin user [uid: 1] », structure NON posée, ni jetons de rôle, ni` \
    `# OIDC, ni branche ops, quatre modules tombés pour une ligne — puis PROV_FLEET_HUMAN, vide dans` \
    `# le cas nominal, donc une variable qui ne portait un nom que quand un drapeau l'avait dit.` \
    `#` \
    `# LE COMPTE INTÉGRÉ N'EST PAS UNE PERSONNE, et la recette le dit d'elle-même : « il tient le` \
    `# siège du compte que l'admin d'une forge crée à son installation […] les vraies personnes` \
    `# s'inscrivent seules et un admin les ajoute à humans ». Son nom appartient donc à` \
    `# forge-gestures.sh, qui l'applique lui-même. NE RIEN PASSER est ce qui garde UNE source : un` \
    `# littéral, une variable ou un repli ici en feraient un second, d'accord avec elle jusqu'au` \
    `# jour où l'un des deux bouge — et c'est arrivé deux fois sur cette ligne exactement.` \
    bash "$(repo_root)/fleet/services/forge-gestures.sh" apply 2>&1 | tee "$tf_out" || rc="${PIPESTATUS[0]}"
  rm -rf "$recipe" "$enroll"
  [[ "$rc" -eq 0 ]] \
    || { rm -f "$tf_out"; p_fail "structure NON posée (rc=$rc) — relis la sortie, rien n'est supposé"; verdict_apply; }

  # ⚠ « APPLIQUÉ » N'EST PAS « CHANGÉ », ET LE CODE DE SORTIE NE LES DISTINGUE PAS. La recette est
  # idempotente : elle rend 0 aussi bien après avoir tout posé qu'après n'avoir rien eu à faire.
  # Compter un changement à chaque passage rendrait ce module non-idempotent AU BILAN — une
  # convergence stable annoncerait une mutation à chaque tour, et le compteur cesserait de
  # distinguer « on a agi » de « on a regardé ».
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

  announce_builtin_human_password
  seat_binding_report apply
  verdict_apply
}

case "${1:?usage: 48-forge-host.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
