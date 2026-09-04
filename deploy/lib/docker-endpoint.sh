#!/usr/bin/env bash
# SC2034 AU NIVEAU DU FICHIER, ET C'EST LE CONTRAT DE CETTE LIB QUI LE JUSTIFIE. Ses fonctions
# rendent leurs resultats par des GLOBALES que l'APPELANT lit — `docker_endpoint` pose les
# `PROV_DOCKER_*`, `docker_compose_cmd` les `PROV_COMPOSE_*`. Cinq ne sont jamais relues ici et sont
# donc vues inutilisees (mesure : `PROV_DOCKER_WHY`, `_SOCK`, `_SUDO`, `PROV_COMPOSE_CMD`, `_WHY`).
# La directive doit preceder TOUTE commande, `set -` compris, sinon elle est inerte.
# shellcheck disable=SC2034
# SOURCE: deploy/lib/docker-endpoint.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-19
# STATUS: PROTO-V2 — la sonde docker, partagee par le rail ET par le script d'entree

[[ -n "${LCARS_DOCKER_ENDPOINT_LOADED:-}" ]] && return 0
LCARS_DOCKER_ENDPOINT_LOADED=1

# ─── detect_substrate — ou tourne-t-on ? ─────────────────────────────────────────────────────────
detect_substrate() {
  if [[ -f /.dockerenv || "${LCARS_DOCKER:-}" == "1" ]]; then echo docker
  elif grep -qi microsoft /proc/version 2>/dev/null; then echo wsl
  else echo linux
  fi
}

# ─── docker_endpoint — LE BINAIRE N'EST PAS LA PORTE D'ENTRÉE ────────────────────────────────────
#
# POSE SES RÉSULTATS EN GLOBALES ET N'IMPRIME RIEN — l'appeler dans `$( )` ne rend donc RIEN :
#   PROV_DOCKER_BIN     la CLI à appeler — c'est AUSSI une entrée, cf. la déclaration plus bas
#   PROV_DOCKER_HOST    l'endpoint retenu, vide s'il vient déjà de l'environnement
#   PROV_DOCKER_WHY     vide si docker répond ; sinon la phrase qui dit ce qui manque
#   PROV_DOCKER_DENIED  1 quand le daemon répond mais REFUSE cet utilisateur
#   PROV_DOCKER_SOCK    la PREMIÈRE socket qui a refusé — interne au diagnostic
# Rend 0 si un daemon a répondu, 1 sinon.
# ⚠ ELLE MUTE AUSSI L'ENVIRONNEMENT DE L'APPELANT, ce qu'aucune globale ci-dessus ne dit : `unset
# DOCKER_HOST` quand celui qui arrivait ne répond pas, puis `export DOCKER_HOST` sur l'endpoint
# retenu, et `export DOCKER_CONFIG` UNIQUEMENT si `docker compose` ne répond pas tel quel.
# Cette dernière condition portait sur le substrat (« WSL et la CLI du montage ») : elle était donc
# vraie sur toute distro intégrée, où compose répond pourtant nu — et le config fabriqué remplaçait
# celui de l'humain, contexts compris. Elle porte désormais sur la mesure qui la justifie.
#
# ⚠ `command -v docker` SE TROMPE DANS LES DEUX SENS : sa présence n'exclut pas un daemon éteint, et
# son ABSENCE ne prouve rien du tout — sur WSL le daemon vit dans la VM Docker Desktop et s'expose
# par un MONTAGE partagé, CLI comprise, donc une distro sans aucun binaire joint docker. On cherche
# une PAIRE, CLI et endpoint, et la seule preuve est qu'elle réponde.
# ⚠ LA FORME `${VAR:-}` EST DELIBEREE, ET `=""` CASSERAIT LA COUTURE D'ENTREE : la fonction lit
# `want="${PROV_DOCKER_BIN:-}"` pour honorer une CLI imposee — un shim, une doublure de test — et
# cette initialisation-ci s'execute AVANT elle.
PROV_DOCKER_BIN="${PROV_DOCKER_BIN:-}"
PROV_DOCKER_HOST=""
PROV_DOCKER_WHY=""
PROV_DOCKER_DENIED=0
PROV_DOCKER_SOCK=""

# ─── docker_denied_geste <socket> — LE GESTE, PAS SEULEMENT LE CONSTAT ──────────────────────────
#
# Le daemon repond mais refuse cet utilisateur. « la socket est root:docker 660 » est une MESURE
# juste ; elle ne dit pas quoi TAPER, et un diagnostic dont l'action est introuvable coute plus cher
# qu'un diagnostic absent.
#
# ⚠ TROIS ETATS, ET LES DEUX PREMIERS SE RESSEMBLENT AU POINT DE S'INVERSER. Les groupes d'un
# processus sont fixes A L'OUVERTURE de sa session : un compte qu'on vient d'ajouter est membre pour
# le SYSTEME (`/etc/group`) et ne l'est pas pour son SHELL (`id -nG`). Meme refus, deux gestes
# opposes — « ajoute-toi au groupe » a quelqu'un qui y est deja l'envoie refaire ce qui est fait, et
# chercher la panne ailleurs.
#
# MESURE DU 2026-08-31, SUR CE DEPOT MEME : ce cas exact s'est presente. `getent group docker`
# listait bien le compte, `id -nG` non, et le message d'alors ne distinguait pas les deux — il a
# fallu le trouver a la main.
docker_denied_geste() { # docker_denied_geste <socket>
  local sock="${1:?}" grp me
  grp="$(stat -Lc '%G' "$sock" 2>/dev/null)"
  me="$(id -un)"
  [[ -n "$grp" ]] || { echo "socket illisible — qui la possede ?"; return 0; }
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
    echo "tu ES dans « $grp » pour cette session et l'acces est refuse quand meme — la socket porte-t-elle le bit d'ecriture pour son groupe ?"
  elif getent group "$grp" 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -qx "$me"; then
    echo "tu es dans « $grp » DANS /etc/group mais PAS dans cette session — les groupes sont fixes a l'ouverture : rouvre-la, ou joue « sg $grp -c '<commande>' »"
  else
    echo "ajoute-toi au groupe : « sudo usermod -aG $grp $me », puis ROUVRE ta session (un shell deja ouvert ne les recharge pas)"
  fi
}

_docker_mount_cli() { echo "/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker"; }
_docker_mount_plugins() { echo "/mnt/wsl/docker-desktop/cli-tools/usr/local/lib/docker/cli-plugins"; }

# ─── _docker_plugin_config [<dir>] — UN `DOCKER_CONFIG` QUI VOIT LES PLUGINS DU MONTAGE ─────────
#
# Rend le chemin d'un repertoire `DOCKER_CONFIG` dont le `config.json` pointe `cliPluginsExtraDirs`
# vers les plugins de la CLI du montage. Sans lui, `docker compose` N'EXISTE PAS : `compose` est un
# PLUGIN, pas une sous-commande, et la CLI du montage range les siens dans un repertoire qui n'est
# dans aucune liste par defaut — le mot `compose` tombe et `-f` devient un drapeau global
# (« unknown shorthand flag: 'f' »).
#
# ⚠ `DOCKER_CLI_PLUGIN_EXTRA_DIRS` NE SUFFIT PAS : pas honore par cette version de la CLI (mesure).
# Le detour par `DOCKER_CONFIG` + `cliPluginsExtraDirs` n'est pas une complication gratuite, c'est
# la seule voie qui marche.
#
# ⚠ ON PART DE LA CONFIG DE L'HUMAIN QUAND ELLE EXISTE. Elle porte ses credentials de registry
# (`auths`, `credHelpers`, `credsStore`) ; forcer un repertoire vide les rendrait invisibles, et un
# `pull` d'image privee echouerait en accusant le reseau. Le repli qui ecrit un `config.json` reduit
# aux seuls `cliPluginsExtraDirs` EFFACE ces clefs : il ne sert que quand il n'y a rien a preserver.
# Le repli n'existe que pour une machine sans python3 : il n'a rien a preserver, il ecrase.
_docker_plugin_config() {
  local dir="${1:-}" plug src
  plug="$(_docker_mount_plugins)"
  [[ -d "$plug" ]] || return 1
  if [[ -z "$dir" ]]; then
    dir="$(mktemp -d "${TMPDIR:-/tmp}/lcars-dockercfg.XXXXXX")" || return 1
    chmod 0700 "$dir"
  fi
  mkdir -p "$dir"
  src="${HOME:-}/.docker/config.json"
  if [[ -r "$src" ]] && command -v python3 >/dev/null 2>&1; then
    python3 - "$src" "$plug" > "$dir/config.json" <<'PYCFG' 2>/dev/null || \
      printf '{"cliPluginsExtraDirs":["%s"]}\n' "$plug" > "$dir/config.json"
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    d = {}
d["cliPluginsExtraDirs"] = [sys.argv[2]]
json.dump(d, sys.stdout)
PYCFG
  else
    printf '{"cliPluginsExtraDirs":["%s"]}\n' "$plug" > "$dir/config.json"
  fi
  chmod 0600 "$dir/config.json"
  printf '%s' "$dir"
}

# ─── LES ADRESSES DU DAEMON, PAR SUBSTRAT — ON NE CHERCHE PAS, ON SAIT ───────────────────────────
_docker_sockets() {
  if [[ -n "${LCARS_DOCKER_SOCKETS:-}" ]]; then
    printf '%s\n' "$LCARS_DOCKER_SOCKETS"
    return 0
  fi
  # ⚠ UNE SEULE SOCKET, SUR TOUS LES SUBSTRATS (⚖ user 2026-08-31). Sous WSL, ce balayage essayait
  # ensuite la socket du montage Docker Desktop (`shared-sockets/guest-services/docker.proxy.sock`),
  # qui est `root:root 755` — donc un repli qui EXIGE root pour un daemon auquel l'intégration donne
  # accès par un simple groupe.
  #
  # Ce repli n'avait qu'un cas : une distro dont l'intégration WSL est DÉSACTIVÉE. L'activer est un
  # clic dans Docker Desktop ; offrir un contournement à `sudo` là où un clic suffit apprend le
  # mauvais réflexe, et contredit le canon de la boîte (« elle ne demande jamais sudo »).
  #
  # ⚠ ET IL A COÛTÉ DEUX FOIS. Le 2026-08-30, le refus accusait la proxy au lieu de
  # `/var/run/docker.sock` et envoyait chercher des droits qui ne bloquaient personne — correctif
  # « la PREMIÈRE socket refusée » plus bas. Le 2026-08-31, il m'a fait bâtir un diagnostic entier
  # sur une socket hors sujet pendant que celle qui comptait répondait.
  #
  # L'intégration WSL est donc un PRÉ-REQUIS, pas une commodité : elle expose
  # `/var/run/docker.sock` dans la distro en `root:docker`, ce qui rend WSL identique au linux natif
  # — même socket, même groupe, même condition d'accès.
  printf '%s\n' /var/run/docker.sock
}

docker_endpoint() {
  local want="${PROV_DOCKER_BIN:-}"
  PROV_DOCKER_BIN=""; PROV_DOCKER_HOST=""; PROV_DOCKER_WHY=""; PROV_DOCKER_DENIED=0; PROV_DOCKER_SOCK=""
  local cli sock

  # 1. La CLI.
  #
  # ⚠ SUR WSL, LA CLI DU MONTAGE PASSE AVANT LE PATH : docker est installé côté Windows, ce qu'un
  # PATH offre dans la distro est une copie ou un wrapper, jamais « le » docker — le préférer risque
  # une CLI qui ne correspond pas au daemon. Le PATH ne fait autorité que sur un linux natif.
  local -a candidats
  if [[ "$(detect_substrate)" == "wsl" ]]; then
    candidats=("$want" "$(_docker_mount_cli)" docker)
  else
    candidats=("$want" docker "$(_docker_mount_cli)")
  fi
  # ⚠ UN NOM NU ET UN CHEMIN NE SE TESTENT PAS PAREIL : `[[ -x docker ]]` est VRAI dès que le CWD
  # contient un DOSSIER `docker` — un dossier est exécutable, c'est-à-dire traversable. Un nom nu
  # n'a de sens que par le PATH ; un chemin doit être un fichier.
  for cli in "${candidats[@]}"; do
    [[ -n "$cli" ]] || continue
    if [[ "$cli" == */* ]]; then
      [[ -f "$cli" && -x "$cli" ]] && { PROV_DOCKER_BIN="$cli"; break; }
    else
      command -v "$cli" >/dev/null 2>&1 && { PROV_DOCKER_BIN="$cli"; break; }
    fi
  done
  if [[ -z "$PROV_DOCKER_BIN" ]]; then
    PROV_DOCKER_WHY="aucune CLI docker : ni dans le PATH, ni dans le montage Docker Desktop ($(_docker_mount_cli))"
    return 1
  fi

  # LE CHEMIN DES PLUGINS SE POSE ICI, PARCE QU'IL DEPEND DE LA CLI CHOISIE ET DE RIEN D'AUTRE.
  # Accroche au shim d'escalade plus bas, il ne couvrirait que les appelants NON-ROOT : le module
  # qui a besoin de `compose` tourne en root, ou l'escalade n'a pas lieu, et recevrait la CLI du
  # montage toute nue.
  #
  # ⚠ ON MESURE SI COMPOSE REPOND, ON NE DEDUIT PLUS DU SUBSTRAT. La condition portait sur « WSL ET
  # la CLI du montage » — vraie sur toute distro a integration Docker Desktop, ou compose repond
  # pourtant PARFAITEMENT NU. On fabriquait donc un `DOCKER_CONFIG` inutile, et il n'est pas neutre :
  # il remplace le config de l'humain, donc ses CONTEXTS.
  #
  # Mesure du 2026-08-30, banc WSL a integration activee, avant/apres un simple appel a cette
  # fonction :
  #     contexts AVANT : default desktop-linux
  #     contexts APRES : default          ← `desktop-linux` disparu
  # Le rail n'a rien casse de visible parce qu'il porte `DOCKER_HOST` ; l'humain qui herite de cet
  # environnement, lui, perd le contexte que Docker Desktop lui a pose.
  #
  # La mesure est aussi la seule condition qui reste VRAIE quand le montage n'est pas la : un
  # compose absent est un compose absent, quel que soit le substrat qui l'explique.
  if [[ -z "${DOCKER_CONFIG:-}" ]] && ! "$PROV_DOCKER_BIN" compose version >/dev/null 2>&1; then
    local _pcfg; _pcfg="$(_docker_plugin_config)" && [[ -n "$_pcfg" ]] && export DOCKER_CONFIG="$_pcfg"
  fi

  # 2. L'endpoint.
  #
  # ⚠ UN `DOCKER_HOST` PRESENT N'EST PAS TOUJOURS UNE DECISION : l'integration WSL de Docker Desktop
  # l'INJECTE dans le shell de la distro, et cette socket-la appartient a root. Traiter l'injection
  # comme un choix humain et s'arreter sur son echec refuse des machines saines.
  local _envhost="" _dh=""
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    if "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then return 0; fi
    _dh="${DOCKER_HOST#unix://}"
    if [[ -S "$_dh" ]]; then
      _envhost=" ${DOCKER_HOST}[env,$([[ -w "$_dh" ]] && echo "accessible" || echo "REFUSE $(id -un)")]"
    else
      _envhost=" ${DOCKER_HOST}[env,rien-a-cette-adresse]"
    fi
    # L'`unset` ne sert PAS au balayage — chaque essai porte `DOCKER_HOST=` en tete de commande, qui
    # ecrase l'heritage. Il empeche un endpoint MORT de survivre a la fonction chez l'appelant.
    unset DOCKER_HOST
  fi
  # ⚠ ET ON LIT LE DROIT SUR LA SOCKET, JAMAIS UN MESSAGE. Un libelle d'erreur est une convention de
  # version, et le code de sortie ne discrimine pas : `docker version` rend 1 aussi bien sur une
  # socket qui refuse que sur un daemon absent (mesure du 2026-08-19). `-w` repond a la question
  # exacte — « puis-je m'en servir » — sans dependre de qui la formule.
  while read -r sock; do
    [[ -S "$sock" ]] || continue
    if DOCKER_HOST="unix://$sock" "$PROV_DOCKER_BIN" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
      PROV_DOCKER_HOST="unix://$sock"
      export DOCKER_HOST="$PROV_DOCKER_HOST"
      return 0
    fi
    # ⚠ LA PREMIERE SOCKET REFUSEE, PAS LA DERNIERE, ET C'EST TOUT LE DIAGNOSTIC. Cette affectation
    # ECRASAIT a chaque tour : sur WSL le balayage voit `/var/run/docker.sock` (root:docker 660 —
    # celle qui compte, refusee faute d'appartenance) PUIS la socket du montage
    # (`docker.proxy.sock`, root:root 755). Le refus final accusait donc la seconde, et envoyait
    # l'operateur regarder des droits qui ne sont pas ceux qui le bloquent. Le premier refus est
    # celui qui porte la cause ; les suivants sont des replis.
    #
    # Un diagnostic qui accuse le mauvais objet coute plus cher qu'un diagnostic absent : il fait
    # chercher la panne la ou elle n'est pas. Mesure d'un banc WSL a integration activee, 2026-08-30.
    [[ -w "$sock" ]] || { PROV_DOCKER_DENIED=1; : "${PROV_DOCKER_SOCK:=$sock}"; }
  done < <(_docker_sockets)

  if [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then
    # ⚖ lot 10 (point 10) : PLUS D'ESCALADE. Le shim sudo (une CLI fabriquee qui passait chaque
    # commande sous sudo avec un environnement filtre) couvrait le poste ou la socket appartient a
    # root:docker sans que l'humain soit du groupe — un cas que l'integration WSL obligatoire et la
    # loi 5 (docker_denied_geste : le geste, pas seulement le constat) ont rendu marginal, pour trente
    # lignes qui faisaient tourner compose en root sur le clone de l'humain. Le refus nomme le geste.
    local abs; abs="$(command -v "$PROV_DOCKER_BIN" 2>/dev/null || echo "$PROV_DOCKER_BIN")"
    PROV_DOCKER_WHY="le daemon docker REPOND, mais pas a « $(id -un) » : la socket $PROV_DOCKER_SOCK est $(stat -Lc '%U:%G %a' "$PROV_DOCKER_SOCK" 2>/dev/null) · $(docker_denied_geste "$PROV_DOCKER_SOCK") · CLI retenue : $abs"
    return 1
  fi

  # 3. Rien ne répond.
  local resolved tried=""
  resolved="$(command -v "$PROV_DOCKER_BIN" 2>/dev/null || echo "$PROV_DOCKER_BIN")"
  while read -r sock; do
    if [[ -S "$sock" ]]; then tried+=" ${sock}[socket$([[ -w "$sock" ]] && echo ",accessible" || echo ",NON-ACCESSIBLE")]"
    elif [[ -e "$sock" ]]; then tried+=" ${sock}[existe,PAS-UNE-SOCKET]"
    else tried+=" ${sock}[absent]"
    fi
  done < <(_docker_sockets)
  if [[ "$(detect_substrate)" == "wsl" ]]; then
    # ⚠ LE REFUS NOMME LE PRE-REQUIS, PAS SEULEMENT L'ABSENCE. Sur WSL le daemon vit dans la VM
    # Docker Desktop, et c'est l'INTEGRATION qui l'expose dans la distro en posant
    # `/var/run/docker.sock` (root:docker). Sans elle, il n'y a plus de chemin : le repli par la
    # socket du montage a ete retire (⚖ user 2026-08-31) — il exigeait root pour un daemon auquel un
    # clic donne acces par un groupe.
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$_envhost$tried. Sur WSL, DEUX choses, dans cet ordre : Docker Desktop demarre cote Windows, et l'INTEGRATION WSL activee pour CETTE distro (Settings > Resources > WSL integration). C'est elle qui pose /var/run/docker.sock ici ; sans elle ce rail n'a aucun autre chemin"
  else
    PROV_DOCKER_WHY="aucun daemon docker joignable. CLI retenue : $resolved · sockets essayées :$_envhost$tried. Le service tourne-t-il, et suis-je dans le groupe docker ?"
  fi
  return 1
}

# ─── docker_stream_ok <conteneur> — UN ALLER-RETOUR RÉEL, AVANT DE CAPTURER UN `docker exec` ─────
#
# ⚠ Un relais docker peut répondre parfaitement à `version`/`ps` et rendre ZÉRO OCTET, EXIT 0, sur
# toute commande à flux attaché. La capture vide devient alors un fait, et le diagnostic accuse
# l'objet sain — la forge, pas le tuyau.
docker_stream_ok() {
  local ctr="${1:?docker_stream_ok: nom ou id de conteneur requis}" out
  out="$("${PROV_DOCKER_BIN:-docker}" exec "$ctr" printf 'lcars-stream-ok' 2>/dev/null || true)"
  [[ "$out" == "lcars-stream-ok" ]]
}


# ─── docker_compose_cmd — QUEL COMPOSE, DEMANDÉ UNE FOIS ────────────────────────────────────────
PROV_COMPOSE_CMD=""
PROV_COMPOSE_WHY=""
docker_compose_cmd() { # docker_compose_cmd [<binaire docker>] -> 0 et PROV_COMPOSE_CMD, ou 1 et _WHY
  local bin="${1:-${PROV_DOCKER_BIN:-docker}}"
  PROV_COMPOSE_CMD=""
  PROV_COMPOSE_WHY=""
  if "$bin" compose version >/dev/null 2>&1; then
    PROV_COMPOSE_CMD="$bin compose"
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    PROV_COMPOSE_CMD="docker-compose"
    return 0
  fi
  PROV_COMPOSE_WHY="docker répond, mais compose est absent (ni le plugin « docker compose », ni « docker-compose »)"
  return 1
}
