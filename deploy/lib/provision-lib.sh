#!/usr/bin/env bash
# les fonctions rendent leurs résultats par des globales PROV_* que l'appelant lit : shellcheck les voit inutilisées
# shellcheck disable=SC2034
# SOURCE: deploy/lib/provision-lib.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-12
# STATUS: la bibliothèque des modules — constantes de l'installeur et choix de l'opérateur, verdicts, primitives convergentes et atomiques, client de forge, lanceur de gestes, sondes de la machine et de la forge

_PROV_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=docker-endpoint.sh
. "$_PROV_LIB_DIR/docker-endpoint.sh"

PROV_CONSTANTS_FILE="$_PROV_LIB_DIR/../installer-constants.env"
PROV_MANIFEST_FILE="$_PROV_LIB_DIR/../system.manifest"

# chaque CLE=valeur devient une variable : le fichier est une donnée, jamais exécuté ; un chemin absolu
# se lit sous LCARS_DECOR_ROOT, la racine qu'un témoin pose et qu'une machine laisse vide
prov_load_constants() { # prov_load_constants <fichier>
  local l k v
  [[ -r "$1" ]] || { printf 'ÉCHEC : constantes de l'"'"'installeur illisibles : %s\n' "$1" >&2; exit 1; }
  while IFS= read -r l || [[ -n "$l" ]]; do
    k="${l%%=*}"; v="${l#*=}"
    [[ "$k" != "$l" && "$k" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    [[ "$v" != /* ]] || v="${LCARS_DECOR_ROOT:-}$v"
    printf -v "$k" '%s' "$v"
  done < "$1"
}
prov_load_constants "$PROV_CONSTANTS_FILE"

prov_canon() { printf '%s' "${1#"${LCARS_DECOR_ROOT:-}"}"; }   # le chemin tel que le manifeste le déclare
prov_decor() { printf '%s%s' "${LCARS_DECOR_ROOT:-}" "$1"; }    # un chemin système, sous le décor s'il y en a un

# ─── LES FAITS DU PRODUIT, ET L'INSTALLEUR EST UN LECTEUR COMME LES AUTRES ───────────────────────
#
# ⚖ Décision 3 du plan runtime (R6). Un fait de la machine — le groupe `fleet`, l'org système, le
# répertoire des jetons — s'écrit UNE fois, dans `runtime/etc/facts.env`, et quatre langages le
# lisent : le shell du produit (`services/lib/facts.sh`), son Python (`lcars_facts.py`), son Elixir
# (`Fleet.Facts`), et cette lib.
#
# ⚠ CE FICHIER-CI NE PEUT PAS DISPARAÎTRE POUR AUTANT : `installer-constants.env` est une DONNÉE que
# `docker compose --env-file` et `env_field` lisent sans shell — elle ne peut référencer aucun autre
# fichier. Les constantes qui portent un fait restent donc un MIROIR, et un miroir se tient : la
# table ci-dessous les apparie, et `prov_refuse_faits_divergents` refuse la divergence AVANT qu'un
# module ne pose quoi que ce soit. Le mur `facts.single_source` tient la même paire à la porte.
#
# Les faits vivent dans leur propre tableau : les y verser en `LCARS_*` écraserait les entrées de
# l'OPÉRATEUR que cette lib lit sous ces noms (`LCARS_BUILTIN_HUMAN`, `LCARS_DECOR_ROOT`…).
# Deux candidats : un checkout (`deploy/lib/../../runtime/etc`) et la copie posée sous la racine du
# produit (`/opt/lcars/deploy/lib/../../etc`). Un appelant qui NOMME le fichier passe devant les
# deux — c'est ce que font les témoins, et le même ordre que les trois autres lecteurs.
# ⚠ DEUX NOMS, ET CE N'EST PAS UN DÉTAIL. `PROV_PRODUCT_FACTS_FILE` est l'ENTRÉE (ce que l'appelant
# nomme) ; `PROV_FAITS_FICHIER` est le chemin RETENU, que la lib écrit. Hors mode POSIX, bash range
# une assignation posée en préfixe d'un `source` (`VAR=x . lib`) dans un environnement TEMPORAIRE
# qu'il défait au retour — y réécrire n'y survit pas. Le chemin retenu doit donc porter un autre nom,
# sans quoi le premier lecteur meurt sur une variable non liée, loin de la cause (mesuré le 2026-09-19).
PROV_FAITS_FICHIER="${PROV_PRODUCT_FACTS_FILE:-}"
if [[ -z "$PROV_FAITS_FICHIER" ]]; then
  PROV_FAITS_FICHIER="$_PROV_LIB_DIR/../../runtime/etc/facts.env"
  [[ -r "$PROV_FAITS_FICHIER" ]] || PROV_FAITS_FICHIER="$_PROV_LIB_DIR/../../etc/facts.env"
fi
declare -A PROV_FAITS=()
PROV_FAITS_LUS=0
# ⚠ PAS DE REFUS AU SOURCING, ET C'EST LA MÊME RÈGLE QUE `prov_refuse_homonymes` : cette lib est
# sourcée par tout ce qui LIT la machine (`doctor`, `list`, `mesure`, `accept`, `pack`), et un arbre
# dont les faits manquent est exactement celui qu'on veut diagnostiquer. Le refus appartient à ce
# qui POSE — `prov_refuse_faits_divergents`, que `deploy/provision apply` appelle avant tout module.
# Rien ici ne DÉRIVE d'un fait : les constantes portent leurs valeurs, les faits servent à les VÉRIFIER.
prov_load_facts() { # prov_load_facts <fichier> — mêmes règles que les constantes : donnée, jamais exécutée
  local l k v
  [[ -r "$1" ]] || return 0
  PROV_FAITS_LUS=1
  while IFS= read -r l || [[ -n "$l" ]]; do
    k="${l%%=*}"; v="${l#*=}"
    [[ "$k" != "$l" && "$k" =~ ^LCARS_[A-Z0-9_]*$ ]] || continue
    [[ "$v" != /* ]] || v="${LCARS_DECOR_ROOT:-}$v"
    PROV_FAITS["$k"]="$v"
  done < "$1"
}
prov_load_facts "$PROV_FAITS_FICHIER"

# la constante de l'installeur, puis le fait du produit qu'elle recopie
PROV_FACT_MIRRORS=(
  PROV_PREFIX=LCARS_PREFIX
  PROV_LINK_DIR=LCARS_LINK_DIR
  PROV_TOKENS_DIR=LCARS_PRIVATE_DIR
  PROV_FLEET_GROUP=LCARS_FLEET_GROUP
  PROV_CONSOLE_GROUP=LCARS_CONSOLE_GROUP
  PROV_AUTHORITY_USER=LCARS_AUTHORITY_USER
  PROV_SYSTEM_USER=LCARS_SYSTEM_USER
  PROV_SYSTEM_ACCOUNT=LCARS_SYSTEM_ACCOUNT
  PROV_HUMANS_TEAM=LCARS_HUMANS_TEAM
  PROV_CATALOGUES_DIR=LCARS_CATALOGUES_DIR
  PROV_CATALOGUES_WORK=LCARS_CATALOGUES_WORK
  PROV_DECK_OIDC_FILE=LCARS_DECK_OIDC_FILE
  PROV_DEPOSIT_SPOOL=LCARS_DEPOSIT_SPOOL
  # les trois que l'opérateur peut régler : le miroir porte sur le DÉFAUT, pas sur son choix
  PROV_FORGE_ORG_DEFAULT=LCARS_FORGE_ORG
  PROV_DECK_PORT_DEFAULT=LCARS_LANDING_PORT
  PROV_DEPOSIT_MAX_BYTES_DEFAULT=LCARS_DEPOSIT_MAX_BYTES
)
prov_refuse_faits_divergents() { # rc 1 et la paire nommée si une constante ment sur son fait
  local p cst fait ecarts=()
  if [[ "$PROV_FAITS_LUS" -eq 0 ]]; then
    printf 'ÉCHEC : faits du produit illisibles (%s) — cet arbre ne porte pas `runtime/etc/facts.env`,\n' "$PROV_FAITS_FICHIER" >&2
    printf '       donc rien ne dit que ce que l'"'"'installeur va poser est ce que le produit ira lire.\n' >&2
    return 1
  fi
  for p in "${PROV_FACT_MIRRORS[@]}"; do
    cst="${p%%=*}"; fait="${p#*=}"
    [[ -v "PROV_FAITS[$fait]" ]] \
      || { ecarts+=("$fait absent de $PROV_FAITS_FICHIER, alors que $cst le recopie"); continue; }
    [[ "${!cst}" == "${PROV_FAITS[$fait]}" ]] \
      || ecarts+=("$cst=${!cst} mais $fait=${PROV_FAITS[$fait]}")
  done
  [[ "${#ecarts[@]}" -eq 0 ]] && return 0
  printf 'ÉCHEC : les constantes de l'"'"'installeur et les faits du produit ne disent pas la même chose (%d) :\n' "${#ecarts[@]}" >&2
  printf '  · %s\n' "${ecarts[@]}" >&2
  printf '       Le fait fait autorité (%s). Une constante qui en diverge fait poser à\n' "$PROV_FAITS_FICHIER" >&2
  printf '       l'"'"'installeur un objet que le produit ira chercher ailleurs.\n' >&2
  return 1
}

: "${PROV_FORGE_BASE:=$PROV_FORGE_BASE_DEFAULT}"
: "${PROV_FORGE_ORG:=$PROV_FORGE_ORG_DEFAULT}"
# le dépôt du système, dans l'org système : dérivé, jamais choisi à part (un choix à part diverge)
: "${PROV_OPS_REPO:=$PROV_FORGE_ORG/_ops}"
: "${PROV_DECK_PORT:=$PROV_DECK_PORT_DEFAULT}"
: "${PROV_DEPOSIT_MAX_BYTES:=$PROV_DEPOSIT_MAX_BYTES_DEFAULT}"
: "${PROV_SSH_PORT:=$PROV_SSH_PORT_DEFAULT}"
: "${PROV_FORGE_HOST_PORT:=$PROV_FORGE_HOST_PORT_DEFAULT}"
# LCARS_BUILTIN_HUMAN est un choix explicite : il gagne sur l'humain que le journal retient
PROV_BUILTIN_HUMAN="${LCARS_BUILTIN_HUMAN:-${PROV_BUILTIN_HUMAN:-$PROV_BUILTIN_HUMAN_DEFAULT}}"
# ⚠ SUR GITEA, UNE ORG *EST* UN UTILISATEUR : les deux partagent un espace de noms, et l'org système
# meurt en « user already exists » au milieu du plan tofu si un compte porte son nom — le MÊME plan
# pose les deux, donc la collision naît sur une forge vierge, sans que rien ne préexiste.
#
# Ce n'est PAS un refus au sourcing. La lib est sourcée par tout ce qui lit la machine (`doctor`,
# `list`, `mesure`, `accept`, `pack`), et une machine dont le journal retient le nom fautif est
# exactement celle qu'on veut diagnostiquer : refuser de la SONDER n'aide personne. Le refus
# appartient à ce qui POSE, et `deploy/provision apply` l'appelle avant tout module.
prov_refuse_homonymes() { # prov_refuse_homonymes — rc 1 et un message si un nom est demandé deux fois
  local pris
  [[ -n "$PROV_BUILTIN_HUMAN" ]] || return 0
  for pris in "$PROV_FORGE_ORG:l'org système" "$PROV_BUNDLED_CATALOGUE:l'org du catalogue embarqué"; do
    [[ "$PROV_BUILTIN_HUMAN" == "${pris%%:*}" ]] || continue
    printf 'ÉCHEC : l'"'"'humain de démonstration « %s » porte le nom de %s — sur Gitea une org et un compte partagent l'"'"'espace de noms, et la même recette pose les deux. La structure de la forge mourrait sur une ligne qui parle d'"'"'org. Rien n'"'"'a été fait.\n  → --humain-demo AUTRE_NOM, ou une autre org (PROV_FORGE_ORG).\n' \
      "$PROV_BUILTIN_HUMAN" "${pris#*:}" >&2
    return 1
  done
  return 0
}

PROV_FORGE_PROJECT="${PROV_FORGE_BASE}-forge"
PROV_RUNNER_PROJECT="${PROV_FORGE_BASE}-runner"
PROV_FORGE_NET="${PROV_FORGE_PROJECT}_default"

# ⚠ UN RUNNER QUI DÉRIVE NE TOMBE PAS EN PANNE : IL NE PREND PLUS LES JOBS. Des labels qui ne
# correspondent plus, ou une adresse de forge qu'un conteneur de job n'atteint pas, ne cassent rien
# de visible — la CI accepte les jobs, et personne ne les sert. C'est le mode de défaillance le plus
# silencieux du rail, et il mérite d'être MESURÉ des deux côtés.
#
# ⚖ Elle vit ICI et pas dans `49-forge-runner.sh` parce que le doctor du conteneur
# (`deploy/container status`) doit poser la même question : ce module la jouait seul, donc un banc
# dont le runner avait dérivé se présentait en bonne santé. Une seconde écriture aurait divergé —
# c'est la leçon que ce chantier vient de payer deux fois.
#
# ⚠ ELLE NE CONCLUT RIEN QUAND ELLE N'A PAS PU LIRE. Conteneur absent, docker muet, environnement
# illisible : elle rend VIDE, comme « conforme ». C'est délibéré et c'est la règle du dépôt — ce
# qu'on n'a pas pu lire ne se transforme pas en écart. L'appelant qui a besoin de distinguer les
# deux mesure la présence du conteneur lui-même.
prov_runner_ecart() { # prov_runner_ecart <conteneur> <url attendue> <labels attendus> → l'écart, ou rien
  local conteneur="$1" url_attendue="$2" labels_attendus="$3" env url labels
  [[ -n "$conteneur" ]] || return 0
  env="$("${PROV_DOCKER_BIN:-docker}" inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$conteneur" 2>/dev/null)" || return 0
  [[ -n "$env" ]] || return 0
  url="$(env_field <(printf '%s\n' "$env") GITEA_INSTANCE_URL)"
  labels="$(env_field <(printf '%s\n' "$env") GITEA_RUNNER_LABELS)"
  if [[ -n "$url" && -n "$url_attendue" && "$url" != "$url_attendue" ]]; then
    printf "vise %s, qu'un job n'atteint pas (attendu %s)\n" "$url" "$url_attendue"
  elif [[ -n "$labels" && -n "$labels_attendus" && "$labels" != "$labels_attendus" ]]; then
    printf 'porte les labels %s (attendu %s)\n' "$labels" "$labels_attendus"
  fi
}

# sous --bench (PROV_FORGE_MONTEE), la forge est celle du poste et un FORGE_BASE_URL résiduel n'y change
# rien. Une forge fournie vient de FORGE_BASE_URL, ou du mode « fournie » que 48 grave dans forge.mode,
# avec forge.url. Dans un conteneur sans forge fournie, l'adresse reste vide : le geste du produit la
# lit dans forge.url. Partout ailleurs, la forge est celle du poste, sur la loopback au port choisi.
_prov_lu() { head -n1 "$1" 2>/dev/null | tr -d '[:space:]' || true; }
if [[ "${PROV_FORGE_MONTEE:-}" == "1" ]]; then
  PROV_FORGE_DU_POSTE=1
elif [[ -n "${FORGE_BASE_URL:-}" ]]; then
  PROV_FORGE_DU_POSTE=0; PROV_FORGE_URL="$FORGE_BASE_URL"; PROV_FORGE_PUBLIC_URL="${FORGE_PUBLIC_URL:-}"
elif [[ "$(_prov_lu "$PROV_FORGE_MODE_FILE")" == fournie ]]; then
  PROV_FORGE_DU_POSTE=0; PROV_FORGE_URL="$(_prov_lu "$PROV_FORGE_URL_FILE")"; PROV_FORGE_PUBLIC_URL="$(_prov_lu "$PROV_FORGE_PUBLIC_URL_FILE")"
elif [[ "${PROV_SUBSTRATE:-$(detect_substrate)}" == docker ]]; then
  PROV_FORGE_DU_POSTE=0; PROV_FORGE_URL=""; PROV_FORGE_PUBLIC_URL=""
else
  PROV_FORGE_DU_POSTE=1
fi
if [[ "$PROV_FORGE_DU_POSTE" -eq 1 ]]; then
  PROV_FORGE_URL="http://127.0.0.1:${PROV_FORGE_HOST_PORT}"
  PROV_FORGE_PUBLIC_URL="$(_prov_lu "$PROV_FORGE_PUBLIC_URL_FILE")"
fi
unset -f _prov_lu
PROV_FORGE_URL="${PROV_FORGE_URL%/}"
PROV_FORGE_PUBLIC_URL="${PROV_FORGE_PUBLIC_URL%/}"
: "${PROV_FORGE_PUBLIC_URL:=$PROV_FORGE_URL}"
: "${PROV_DUMP_LINES:=40}"
: "${PROV_HUMAN:=${SUDO_USER:-$(id -un)}}"

PROV_MODULE_TAG="${PROVISION_MODULE:-$(basename "${0:-provision-lib}")}"
PROV_CHANGED=0
PROV_DRIFT=0
PROV_FAILED=0

if [[ -n "${NO_COLOR:-}" ]]; then PROV_COLOR=0
elif [[ -n "${PROV_COLOR:-}" ]]; then :
elif [[ -t 1 ]]; then PROV_COLOR=1
else PROV_COLOR=0
fi
if [[ "$PROV_COLOR" -eq 1 ]]; then
  _PG=$'\033[1;32m'; _PC=$'\033[0;36m'; _PA=$'\033[38;5;214m'; _PR=$'\033[1;31m'; _PN=$'\033[0m'
else
  _PG=''; _PC=''; _PA=''; _PR=''; _PN=''
fi

p_step() { printf '%s>>    %s:%s %s\n' "$_PC" "$PROV_MODULE_TAG" "$_PN" "$*"; }
p_ok()   { printf '%sOK    %s:%s %s\n' "$_PG" "$PROV_MODULE_TAG" "$_PN" "$*"; return 0; }
p_chg()  { printf '%sPOSÉ  %s:%s %s\n' "$_PC" "$PROV_MODULE_TAG" "$_PN" "$*"; return 0; }
p_drift(){ printf '%sDRIFT %s:%s %s\n' "$_PA" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; PROV_DRIFT=$((PROV_DRIFT + 1)); }
p_warn() { printf '%sWARN  %s:%s %s\n' "$_PA" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; }
p_fail() { printf '%sFAIL  %s:%s %s\n' "$_PR" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; PROV_FAILED=$((PROV_FAILED + 1)); }
p_die()  { PROV_VERDICT_RENDERED=1; printf '%sFATAL %s:%s %s\n' "$_PR" "$PROV_MODULE_TAG" "$_PN" "$*" >&2; exit 1; }

# ⚠ `PROV_FACTS_FILE` N'EST PAS `PROV_PRODUCT_FACTS_FILE`, ET L'HOMONYMIE COÛTE CHER : celui-ci est
# la MESURE du préflight, en ÉCRITURE, dont `deploy/provision` fixe le chemin ; l'autre est le
# fichier de faits du PRODUIT, en lecture seule. Mesuré le 2026-09-19 : les nommer pareil a fait
# écrire le préflight DANS `runtime/etc/facts.env`, qui a gagné quarante lignes de mesures.
p_fact() { # p_fact <nom> <valeur…>
  [[ -n "${PROV_FACTS_FILE:-}" ]] || return 0
  printf '%s=%s\n' "$1" "${*:2}" 2>/dev/null >> "$PROV_FACTS_FILE" || true
}

# le runner arme la garde (PROVISION_RUN) : un module qui meurt sans verdict rend 3, jamais un code lu comme un verdict
PROV_VERDICT_RENDERED=0
_prov_exit_guard() {
  local rc=$?
  [[ "$PROV_VERDICT_RENDERED" -eq 1 ]] && return 0
  printf '%sERREUR %s:%s mort avant de rendre son verdict (rc=%d)\n' \
    "$_PR" "$PROV_MODULE_TAG" "$_PN" "$rc" >&2
  exit 3
}
if [[ -n "${PROVISION_RUN:-}" ]]; then
  trap _prov_exit_guard EXIT
  unset PROVISION_RUN
fi

verdict_check() {
  PROV_VERDICT_RENDERED=1
  if [[ "$PROV_FAILED" -gt 0 ]]; then exit 2; fi
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 1
  exit 0
}
verdict_apply() {
  PROV_VERDICT_RENDERED=1
  [[ "$PROV_FAILED" -gt 0 ]] && exit 1
  [[ "$PROV_DRIFT" -gt 0 ]] && exit 2
  exit 0
}

_prov_phase_of() { # _prov_phase_of <fichier> -> le libellé de la dernière phase reconnue du build de la release
  local m
  m="$(grep -oE 'Compiling [0-9]+ files|Release created at' "$1" 2>/dev/null | tail -n1 || true)"
  case "$m" in
    "Compiling"*)         echo "compilation" ;;
    "Release created at") echo "release posée" ;;
    *)                    echo "démarrage" ;;
  esac
}

# Exécuter et qualifier sont deux gestes : run_capture exécute et rend le code, l'appelant pose le
# verdict. run_quiet et run_step posent le verdict ordinaire — un échec est un FAIL, avec sa sortie.
_prov_run() { # _prov_run <libellé ou vide> <cmd…> — avec un libellé, la phase et la durée à l'écran ; sur échec, la sortie reste dans PROV_LAST_OUT
  local label="$1" rc=0; shift
  PROV_LAST_OUT=""
  if [[ "${PROV_VERBOSE:-0}" -eq 1 ]]; then
    [[ -z "$label" ]] || p_step "$label"
    "$@" || rc=$?
  elif [[ -z "$label" ]]; then
    PROV_LAST_OUT="$(mktemp "${TMPDIR:-/tmp}/prov-out.XXXXXX")"
    "$@" >"$PROV_LAST_OUT" 2>&1 || rc=$?
  else
    local t0="$SECONDS" phase="" prev="" el pid
    PROV_LAST_OUT="$(mktemp "${TMPDIR:-/tmp}/prov-out.XXXXXX")"
    "$@" >"$PROV_LAST_OUT" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
      phase="$(_prov_phase_of "$PROV_LAST_OUT")"
      el="$(printf '%02d:%02d' "$(( (SECONDS - t0) / 60 ))" "$(( (SECONDS - t0) % 60 ))")"
      if [[ -t 1 ]]; then
        printf '\r\033[K%s>>%s    %s: %s · %s · %s' "$_PC" "$_PN" "$PROV_MODULE_TAG" "$label" "$phase" "$el"
      elif [[ "$phase" != "$prev" ]]; then
        printf '%s>>%s    %s: %s · %s\n' "$_PC" "$_PN" "$PROV_MODULE_TAG" "$label" "$phase"
      fi
      prev="$phase"
      sleep 1
    done
    wait "$pid" || rc=$?
    [[ -t 1 ]] && printf '\r\033[K'
  fi
  if [[ "$rc" -eq 0 && -n "$PROV_LAST_OUT" ]]; then rm -f "$PROV_LAST_OUT"; PROV_LAST_OUT=""; fi
  PROV_LAST_RC="$rc"
  return "$rc"
}

run_capture() { _prov_run "" "$@"; }   # run_capture <cmd…>

prov_dump_last() { # les dernières lignes de la sortie capturée ; le fichier est conservé
  [[ -n "${PROV_LAST_OUT:-}" && -f "$PROV_LAST_OUT" ]] || return 0
  local n; n="$(wc -l < "$PROV_LAST_OUT")"
  {
    printf '───── sortie : %s dernières lignes sur %s ─────\n' "$PROV_DUMP_LINES" "$n"
    tail -n "$PROV_DUMP_LINES" "$PROV_LAST_OUT"
    printf '───── sortie COMPLÈTE conservée : %s ─────\n' "$PROV_LAST_OUT"
  } >&2
}

run_quiet() { # run_quiet <cmd…>
  local rc=0
  run_capture "$@" || rc=$?
  [[ "$rc" -eq 0 ]] || { p_fail "commande en échec (rc=$rc) : $*"; prov_dump_last; }
  return "$rc"
}

run_step() { # run_step [--ok N]… <label> -- <cmd…> — un code listé rend 0 sans verdict : l'appelant le qualifie sur PROV_LAST_RC
  local ok_codes=() label rc=0 c
  while [[ "$1" == "--ok" ]]; do ok_codes+=("$2"); shift 2; done
  label="$1"; shift 2
  _prov_run "$label" "$@" || rc=$?
  for c in "${ok_codes[@]}"; do
    [[ "$rc" == "$c" ]] || continue
    [[ -z "$PROV_LAST_OUT" ]] || rm -f "$PROV_LAST_OUT"
    PROV_LAST_OUT=""
    return 0
  done
  [[ "$rc" -eq 0 ]] || { p_fail "commande en échec (rc=$rc) : $label"; prov_dump_last; }
  return "$rc"
}

prov_lock_path() { # prov_lock_path → le chemin du verrou de l'apply, dans un dossier 0700 de l'appelant
  local dir uid
  uid="$(id -u)"

  if [[ "$uid" -eq 0 ]]; then
    dir=/run/lock/lcars
  else
    dir="${XDG_RUNTIME_DIR:-/run/user/$uid}/lcars"
  fi

  prov_refuse_symlink_path "$dir" || return 1

  local parent="${dir%/*}"
  [[ -d "$parent" ]] || { p_fail "verrou : $parent absent — pas d'emplacement sûr pour un verrou"; return 1; }
  mkdir -p "$dir" || { p_fail "verrou : dossier impossible : $dir"; return 1; }
  chmod 0700 "$dir" || { p_fail "verrou : chmod 0700 refusé : $dir"; return 1; }

  local owner
  owner="$(stat -c '%u' "$dir")" || { p_fail "verrou : stat impossible : $dir"; return 1; }
  [[ "$owner" == "$uid" ]] || { p_fail "verrou : $dir appartient à l'uid $owner, pas à $uid"; return 1; }

  local lock="$dir/provision.lock"
  [[ -L "$lock" ]] && { p_fail "verrou : $lock est un symlink — refusé"; return 1; }

  printf '%s\n' "$lock"
}

# ⚖ PHASE 6, ÉTAPE 2 : `prov_refuse_symlink_path` a rejoint `runtime/services/lib/primitives.sh`,
# que cette lib source plus bas. Il était déclaré « identité de rail — son refus porte le vocabulaire
# du décor » ; mesure du 2026-09-20 : les deux corps étaient IDENTIQUES ligne pour ligne, à la
# ponctuation du message près, et aucun ne portait le moindre vocabulaire de décor. La garde
# elle-même n'a pas bougé : on n'écrit jamais À TRAVERS un lien, et le chemin est remonté composant
# par composant depuis la racine.
#
# ⚠ ET IL EST APPELÉ AVANT D'ÊTRE DÉFINI — par `prov_ensure_parent_dir` ci-dessus, et par
# `prov_scaffold_dir` plus bas. C'est légal et voulu : bash résout les fonctions À L'APPEL, et
# aucune de ces fonctions ne s'exécute avant que le `source` des primitives ne soit passé.


prov_owner() { # prov_owner <user[:group]> → user:group — « user: » prend le groupe de connexion de user ; les coreutils uutils (Ubuntu 26.04) ignorent la forme nue
  local o="$1" g
  [[ -z "$o" || -z "${LCARS_DECOR_ROOT:-}" ]] || { printf '%s:%s' "$(id -un)" "$(id -gn)"; return 0; }   # sous un décor, tout appartient à qui le joue
  [[ "$o" == *: ]] || { printf '%s' "$o"; return 0; }
  g="$(id -gn -- "${o%:}" 2>/dev/null)" || { printf '%s' "$o"; return 0; }
  printf '%s:%s' "${o%:}" "$g"
}

# ─── LES PRIMITIVES CONVERGENTES : UNE SOURCE, LES DEUX RAILS (⚖ phase 6, RT-C-20) ──────────────
#
# `env_field`, `read_token`, `ensure_dir`, `ensure_mode` et `write_atomic` étaient écrites ICI *et*
# dans `runtime/services/lib/module-protocol.sh` — dix corps pour cinq gestes. Les deux copies
# avaient déjà dérivé, et pas seulement en prose : `ensure_mode` du produit RELISAIT le mode après
# `chmod` et refusait s'il n'avait pas pris ; celui d'ici ne le faisait pas. Un `chmod` qui
# n'aboutit pas était compté comme posé sur ce rail et refusé sur l'autre.
#
# LE SENS DE LA DÉPENDANCE EST CELUI QUI EST DÉJÀ PERMIS : l'installeur APPELLE le produit
# (`prov_geste` joue `runtime/services/forge.d/*.sh` sur le protocole du produit). Il peut donc
# sourcer une lib du produit ; l'inverse resterait interdit.
#
# Ce que cette lib fournit à ces primitives est son DIALECTE — `p_fail`, `p_chg`, `prov_owner` (avec
# sa clause de décor, qui lui appartient), `prov_refuse_symlink_path` — et son compteur de poses.
# Bash résout les fonctions À L'APPEL : chacune parle donc la langue de son hôte.
_compte_pose() { PROV_CHANGED=$((PROV_CHANGED + 1)); }
PROV_PRIMITIVES_SH="${PROV_PRIMITIVES_SH:-}"
if [[ -z "$PROV_PRIMITIVES_SH" ]]; then
  PROV_PRIMITIVES_SH="$_PROV_LIB_DIR/../../runtime/services/lib/primitives.sh"
  [[ -r "$PROV_PRIMITIVES_SH" ]] || PROV_PRIMITIVES_SH="$_PROV_LIB_DIR/../../services/lib/primitives.sh"
fi
# ⚠ PAS DE REFUS AU SOURCING, MEME REGLE QUE POUR LES FAITS : cette lib est sourcée par tout ce qui
# LIT la machine (`doctor`, `list`, `mesure`, `accept`, `pack`), et un arbre incomplet est
# exactement celui qu'on veut diagnostiquer. Mais ne RIEN définir laisserait la première pose mourir
# sur un « command not found », la mort sans nom que ce dépôt refuse partout ailleurs. Les cinq noms
# existent donc toujours : absentes, ce sont des refus qui DISENT ce qui manque.
PROV_PRIMITIVES_ABSENTES=0
if [[ -r "$PROV_PRIMITIVES_SH" ]]; then
  # shellcheck source=../../runtime/services/lib/primitives.sh
  . "$PROV_PRIMITIVES_SH"
else
  PROV_PRIMITIVES_ABSENTES=1
  _prov_sans_primitives() {
    p_fail "primitives du produit illisibles ($PROV_PRIMITIVES_SH) — « $1 » ne peut rien poser. Cet arbre ne porte pas runtime/services/lib/primitives.sh ; sur une machine, « deploy/workstation up » la pose."
    return 1
  }
  env_field()    { _prov_sans_primitives env_field; }
  read_token()   { _prov_sans_primitives read_token; }
  ensure_dir()   { _prov_sans_primitives ensure_dir; }
  ensure_mode()  { _prov_sans_primitives ensure_mode; }
  write_atomic() { _prov_sans_primitives write_atomic; }
  # ⚠ SIXIÈME BOUCHON DEPUIS LA PHASE 6 ÉTAPE 2, et le plus important de tous : sans lui, la garde
  # qui refuse d'écrire À TRAVERS un lien mourrait sur « command not found ». Un refus qui n'existe
  # pas est un refus qui ne refuse rien, et celui-là protège des mutations jouées en root.
  prov_refuse_symlink_path() { _prov_sans_primitives prov_refuse_symlink_path; }
  # `lan_addr` rend une valeur : son bouchon dit la cause et ne rend RIEN — ce que `advertise_addr`
  # traite déjà comme « aucune adresse de sortie détectée » et replie sur 127.0.0.1, en le disant.
  lan_addr() { _prov_sans_primitives lan_addr; }
fi

# ⚠ LE BOUCHON NE SUFFIT PAS, ET C'EST UNE PROPRIÉTÉ DU SHELL, PAS UN OUBLI : `env_field` et
# `read_token` RENDENT une valeur, donc leurs appelants les jouent en `$(…)`. Le `p_fail` du bouchon
# s'exécute alors dans un SOUS-SHELL : la phrase part bien sur stderr, mais le compteur qu'elle
# incrémente meurt avec lui — FAIL imprimé, verdict VERT. Pire pour `read_token` : le bouchon rend la
# chaîne vide, que `forge_api` lit comme « pas de jeton » et transforme en requête ANONYME.
# Le refus appartient donc à CELUI QUI POSE, une fois, avant le premier module — là où il est dans le
# shell principal et où son code de sortie compte encore.
prov_exige_primitives() { # prov_exige_primitives <geste> → 0 présentes · 1 absentes, la cause dite
  [[ "$PROV_PRIMITIVES_ABSENTES" == 1 ]] || return 0
  echo "$1 : primitives du produit illisibles ($PROV_PRIMITIVES_SH) — cet arbre ne porte pas runtime/services/lib/primitives.sh. Rien n'est posé : une pose sans elles écrirait des jetons vides et lirait la forge en anonyme. Sur une machine, « deploy/workstation up » les pose ; dans un kit, « deploy/pack.sh » les embarque." >&2
  return 1
}

prov_check_mode() { # prov_check_mode <chemin> <mode> <propriétaire> → 0 conforme · 1 écart dit en DRIFT · 2 absent, rien de dit
  local cur want
  [[ -e "$1" ]] || return 2
  cur="$(stat -c '%a %U:%G' "$1")"
  want="${2#0} $(prov_owner "$3")"
  [[ "$cur" != "$want" ]] || return 0
  p_drift "$1 : $cur ≠ $want — l'apply le repose"
  return 1
}


prov_scaffold_dir() { # prov_scaffold_dir <chemin> <mode> [owner] — un repertoire de travail, hors journal
  local path="$1" mode="$2" owner="${3:-}"
  owner="$(prov_owner "$owner")"
  prov_refuse_symlink_path "$path" || return 1
  [[ -d "$path" ]] || mkdir -p "$path" || { p_fail "prov_scaffold_dir: mkdir refusé: $path"; return 1; }
  chmod "$mode" "$path" || { p_fail "prov_scaffold_dir: chmod $mode refusé: $path"; return 1; }
  [[ -z "$owner" ]] || chown "$owner" "$path" || { p_fail "prov_scaffold_dir: chown $owner refusé: $path"; return 1; }
  return 0
}
prov_promote_dir() { # prov_promote_dir <échafaudage> <final> — un final existant est échangé en un seul renommage (coreutils 9.5) : il ne manque à aucun instant
  local from="$1" to="$2"
  [[ -d "$from" ]] || { p_fail "prov_promote_dir : échafaudage absent : $from"; return 1; }
  [[ -n "$to" && "$to" != / ]] || { p_fail "prov_promote_dir : destination vide ou racine"; return 1; }
  if [[ -e "$to" || -L "$to" ]]; then
    mv --exchange -T -- "$from" "$to" || { p_fail "prov_promote_dir : bascule refusée : $from → $to"; return 1; }
    rm -rf -- "$from"
  else
    mv -T -- "$from" "$to" || { p_fail "prov_promote_dir : bascule refusée : $from → $to"; return 1; }
  fi
  return 0
}

_prov_manifest_col() { # _prov_manifest_col <objet> <colonne> [type] [trait exclu] — la colonne de la première ligne qui déclare l'objet, hors « - »
  awk -v p="$1" -v n="$2" -v type="${3:-}" -v sans="${4:-}" '
    $1 ~ /^#/ { next }
    { t=$1; sub(/:.*/, "", t); trait=$1; sub(/^[^:]*:?/, "", trait) }
    (type == "" || t == type) && (sans == "" || trait != sans) && $2 == p && $n != "-" { print $n; exit }
  ' "$PROV_MANIFEST_FILE"
}
prov_manifest_gid()       { _prov_manifest_col "$1" 3 group; }
prov_manifest_mode()      { _prov_manifest_col "$(prov_canon "$1")" 3 "" unset; }
prov_manifest_owner()     { _prov_manifest_col "$(prov_canon "$1")" 4; }
prov_manifest_substrate() { _prov_manifest_col "$(prov_canon "$1")" 5; }

prov_substrate_satisfait() { # prov_substrate_satisfait <liste> <substrat> -> 0 si le substrat est couvert par la liste
  local liste="$1" sub="$2" mot
  [[ "$liste" == any ]] && return 0
  liste="${liste//+/ }"
  for mot in $liste; do
    [[ "$mot" == "$sub" ]] && return 0
  done
  return 1
}

prov_group_gid_ok() { # prov_group_gid_ok <groupe existant> → 0 s'il porte le gid que system.manifest déclare, ou si elle n'en déclare aucun ; 1 et un drift sinon
  local gid cur
  gid="$(prov_manifest_gid "$1")"
  cur="$(getent group "$1" | cut -d: -f3)"
  [[ -z "$gid" || "$cur" == "$gid" ]] && return 0
  p_drift "groupe $1 : gid $cur, la table déclare $gid — une machine ne se renumérote pas, elle se recrée"
  return 1
}

ensure_group() { # ensure_group <groupe> — le gid, s'il est fixé, vient de system.manifest
  local grp="$1" gid
  gid="$(prov_manifest_gid "$grp")"
  if ! getent group "$grp" >/dev/null; then
    local -a args=()
    [[ -n "$gid" ]] && args+=(-g "$gid")
    run_quiet groupadd "${args[@]}" "$grp" || return 1
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "groupe $grp${gid:+ (gid $gid, table)}"
    return 0
  fi
  prov_group_gid_ok "$grp" || true
}

prov_pgrep_pattern() { # prov_pgrep_pattern <chaine> -> le motif ERE qui ne matche pas son porteur
  local s="$1"; printf '[%s]%s\n' "${s:0:1}" "${s:1}"
}

prov_in_group() { # prov_in_group <user> <groupe> -> 0 si <user> est membre de <groupe> (session : id -nG)
  local groups; groups="$(id -nG "$1" 2>/dev/null)" || return 1
  [[ " $groups " == *" $2 "* ]]
}

ensure_member() {
  local user="$1" grp="$2"
  id "$user" >/dev/null 2>&1 || { p_fail "ensure_member: user inconnu: $user"; return 1; }
  if ! prov_in_group "$user" "$grp"; then
    run_quiet usermod -aG "$grp" "$user" || return 1
    PROV_CHANGED=$((PROV_CHANGED + 1))
    p_chg "$user ∈ $grp (effectif au prochain login — ou « sg $grp -c '<cmd>' » dans cette session)"
  fi
}

ensure_symlink() {
  local link="$1" target="$2"
  prov_refuse_symlink_path "$(dirname "$link")" || return 1
  if [[ -L "$link" ]]; then
    [[ "$(readlink "$link")" == "$target" ]] && return 0
  elif [[ -e "$link" ]]; then
    p_fail "ensure_symlink: $link existe et n'est pas un symlink — refus d'écraser, à retirer explicitement"
    return 1
  fi
  ln -sfn "$target" "$link" || { p_fail "ensure_symlink: ln refusé: $link"; return 1; }
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$link → $target"
}

ensure_managed_block() {
  local file="$1" marker="$2" mode="$3" owner="${4:-}"
  local begin="# >>> lcars:${marker} >>> (bloc géré par deploy — édition manuelle écrasée au prochain apply)"
  local end="# <<< lcars:${marker} <<<"
  local block existing
  block="$(cat)"
  existing=""
  [[ -f "$file" ]] && existing="$(awk -v b="# >>> lcars:${marker} >>>" -v e="$end" '
      index($0, b) == 1 {skip=1; next}
      $0 == e            {skip=0; next}
      !skip              {print}
    ' "$file")"
  local tmp rc=0
  tmp="$(mktemp "${TMPDIR:-/tmp}/prov-block.XXXXXX")" || { p_fail "ensure_managed_block : tmp impossible"; return 1; }
  {
    if [[ -n "$existing" ]]; then printf '%s\n' "$existing"; fi
    printf '%s\n%s\n%s\n' "$begin" "$block" "$end"
  } > "$tmp"
  write_atomic "$file" "$mode" "$owner" < "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

fetch_verify() {
  local url="$1" sha="$2" dest="$3" mode="$4"
  local dir tmp actual
  dir="$(dirname "$dest")"
  tmp="$(mktemp "$dir/.fetch.XXXXXX")" || { p_fail "fetch_verify : tmp impossible dans $dir"; return 1; }
  if ! run_capture curl -fsSL --proto '=https' -m 300 -o "$tmp" "$url"; then
    rm -f "$tmp"; p_fail "fetch_verify : téléchargement raté : $url"; prov_dump_last; return 1
  fi
  actual="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$tmp"
    p_fail "fetch_verify : sha256 différent pour $url"
    p_fail "  attendu : $sha"
    p_fail "  trouvé  : $actual"
    return 1
  fi
  if ! { chmod "$mode" "$tmp" && mv -f "$tmp" "$dest"; }; then
    rm -f "$tmp"; p_fail "fetch_verify: pose finale ratée: $dest"; return 1
  fi
  PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$dest (sha256 vérifié)"
}

prov_journal_note() { # prov_journal_note <clef> <valeur…>
  [[ -n "${PROV_JOURNAL_ACC:-}" ]] || return 0
  printf '%s %s\n' "$1" "${*:2}" 2>/dev/null >> "$PROV_JOURNAL_ACC" || true
}

prov_announce_credential() { # prov_announce_credential <libellé> <login> <secret>
  if [[ -n "${PROV_ANNOUNCE_FILE:-}" ]]; then
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" 2>/dev/null >> "$PROV_ANNOUNCE_FILE" || true
    return 0
  fi
  prov_print_credentials <<< "$(printf '%s\t%s\t%s\n' "$1" "$2" "$3")"
}

_prov_box_plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
_prov_box_pad() { # <texte> <largeur>
  local p n; p="$(_prov_box_plain "$1")"; n=$(( $2 - ${#p} )); (( n < 0 )) && n=0
  printf '%s%*s' "$1" "$n" ''
}
prov_box_emit() { # prov_box_emit [--rule] <titre> <ligne…>
  local _sep=0
  if [[ "${1:-}" == "--rule" ]]; then _sep=1; shift; fi
  local _title="$1"; shift
  local _w=57 _l _p _rule
  for _l in "$_title" "$@"; do _p="$(_prov_box_plain "$_l")"; (( ${#_p} > _w )) && _w=${#_p}; done
  _rule="$(printf '%*s' "$_w" '' | sed 's/ /─/g')"
  printf '%s  ┌%s┐\n' "$_PC" "$_rule"
  printf '  │%s%s%s│\n' "$_PG" "$(_prov_box_pad "$_title" "$_w")" "$_PC"
  if (( _sep )); then printf '  ├%s┤\n' "$_rule"; fi
  for _l in "$@"; do printf '  │%s%s%s│\n' "$_PN" "$(_prov_box_pad "$_l" "$_w")" "$_PC"; done
  printf '  └%s┘%s\n' "$_rule" "$_PN"
}

prov_print_credentials() { # lit des lignes « libellé<TAB>login<TAB>secret » sur stdin
  local lbl login secret
  local -a lignes=()
  while IFS=$'\t' read -r lbl login secret; do
    [[ -n "$secret" ]] || continue
    [[ "${#lignes[@]}" -eq 0 ]] || lignes+=("")
    lignes+=("  $lbl" "    login        : $login" "    mot de passe : $secret")
  done
  [[ "${#lignes[@]}" -gt 0 ]] || return 0
  echo ""
  prov_box_emit --rule "  IDENTIFIANTS — à noter maintenant, ils ne seront pas redits" "${lignes[@]}"
  echo ""
}

pkg_installed() { # pkg_installed <paquet> — 0 seulement s'il est REELLEMENT installe
  [[ "$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null)" == "installed" ]]
}

APT_ACQUIRE_OPTS=(-o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 -o Acquire::Retries=2)

apt_mirror_diag() {
  local u h
  while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    if curl -fsI -m 10 -o /dev/null "$u/" 2>/dev/null; then
      p_warn "apt: le miroir $u répond — l'échec est ailleurs (paquet, signature, espace disque) : la sortie d'apt ci-dessus le dit"
      continue
    fi
    case "$u" in
      http://*)
        h="https://${u#http://}"
        if curl -fsI -m 10 -o /dev/null "$h/" 2>/dev/null; then
          p_fail "apt: $u injoignable en http alors que $h répond — passer les sources apt en https (URIs: de /etc/apt/sources.list.d/*.sources) et relancer"
        else
          p_fail "apt: $u injoignable, en http comme en https — réseau, proxy ou DNS de cette machine"
        fi ;;
      *) p_fail "apt: $u injoignable — réseau, proxy ou DNS de cette machine" ;;
    esac
  done < <(apt-get indextargets --format '$(URI)' 2>/dev/null | sed -n 's|^\(https\?://[^/]*\)/.*|\1|p' | sort -u)
}

apt_ensure() {
  local missing=() pkg
  for pkg in "$@"; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  [[ "${#missing[@]}" -eq 0 ]] && return 0
  p_chg "apt: install ${missing[*]}"
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get update "${APT_ACQUIRE_OPTS[@]}" -qq \
    || { apt_mirror_diag; return 1; }
  run_quiet env DEBIAN_FRONTEND=noninteractive apt-get install "${APT_ACQUIRE_OPTS[@]}" -y --no-install-recommends "${missing[@]}" \
    || { apt_mirror_diag; return 1; }
  # apt-get install peut rendre 0 en ayant servi moins que la liste : le journal ne porte que ce que dpkg voit posé
  local rc=0 posed=()
  for pkg in "${missing[@]}"; do
    if pkg_installed "$pkg"; then
      posed+=("$pkg")
    else
      p_fail "apt: $pkg toujours absent après install"; rc=1
    fi
  done
  [[ "${#posed[@]}" -gt 0 ]] && prov_journal_note apt_installed "${posed[@]}"
  [[ "$rc" -eq 0 ]] && PROV_CHANGED=$((PROV_CHANGED + 1))
  return "$rc"
}

PROV_ADVERTISE=""
PROV_ADVERTISE_WHY=""
PROV_LAST_RC=0
PROV_LAST_OUT=""

wsl_networking_mode() {
  local m
  m="$(wslinfo --networking-mode 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$m" ]] && { echo "$m"; return 0; }
  echo nat
}

# ⚖ PHASE 6, ETAPE 2 : `lan_addr` a rejoint `lib/primitives.sh` — les deux corps etaient identiques
# OCTET POUR OCTET, et sa justification etait celle d.`advertise_addr`, heritee par voisinage.

# un conteneur de job tourne dans le daemon embarqué du runner : ni le nom de service de la forge, ni
# une adresse de loopback (la sienne) ne l'atteignent, seul le port publié sur une adresse de l'hôte
job_forge_url() { # job_forge_url <port publié> <adresse annoncée> → l'adresse de la forge vue d'un job CI ; rc 1 sans adresse qu'un job joigne
  local hote="$2"
  [[ "${PROV_SUBSTRATE:-$(detect_substrate)}" != wsl ]] || hote="host.docker.internal"
  case "$hote" in ""|127.*|localhost|::1) return 1 ;; esac
  printf 'http://%s:%s\n' "$hote" "$1"
}

advertise_addr() {
  local bind="${1:-0.0.0.0}"
  PROV_ADVERTISE=""; PROV_ADVERTISE_WHY=""
  case "$bind" in
    0.0.0.0|::|"*") ;;
    *) PROV_ADVERTISE="$bind"; return 0 ;;
  esac
  local _sub="${PROV_SUBSTRATE:-$(detect_substrate)}"
  if [[ "$_sub" == "wsl" && "$(wsl_networking_mode)" == "nat" ]]; then
    PROV_ADVERTISE="localhost"
    PROV_ADVERTISE_WHY="WSL2 en mode NAT (le défaut) — l'adresse de la VM n'est routée depuis aucune autre machine et change à chaque redémarrage de WSL ; localhost est le relais que Windows tient vers elle. Sous ce substrat, un déploiement est joignable de CETTE machine et pas du LAN : c'est du test/dev, et l'ouvrir demanderait de toucher au réseau Hyper-V du poste."
    return 0
  fi
  PROV_ADVERTISE="$(lan_addr)"
  if [[ -z "$PROV_ADVERTISE" ]]; then
    PROV_ADVERTISE="127.0.0.1"
    PROV_ADVERTISE_WHY="aucune adresse de sortie détectée — les liens ne valent que sur cette machine"
  fi
  return 0
}

port_taken() { # port_taken <port> -> 0 si quelque chose écoute sur la loopback
  timeout 2 bash -c "</dev/tcp/127.0.0.1/$1" 2>/dev/null
}

port_holder() {
  local port="$1" bin name proj
  bin="${PROV_DOCKER_BIN:-${DOCKER_BIN:-docker}}"
  if command -v "$bin" >/dev/null 2>&1 && timeout 2 "$bin" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
    name="$(timeout 5 "$bin" ps --filter "publish=$port" --format '{{.Names}}' 2>/dev/null | head -1)"
    if [[ -n "$name" ]]; then
      proj="$(timeout 5 "$bin" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)"
      printf '%s (projet %s)\n' "$name" "${proj:-<hors compose>}"
      return 0
    fi
  fi
  port_process "$port"
}

port_process() { # port_process <port> → le processus que ss nomme sur ce port (« nom (pid N, compte C) »), ou rien ; rc 0
  command -v ss >/dev/null 2>&1 || return 0
  local users compte
  users="$(ss -ltnp 2>/dev/null | awk -v p=":$1\$" '$4 ~ p { for (i=1;i<=NF;i++) if ($i ~ /users:/) { print $i; exit } }')" || return 0
  [[ "$users" =~ \(\(\"([^\"]*)\",pid=([0-9]+) ]] || return 0
  compte="$(ps -o user:32= -p "${BASH_REMATCH[2]}" 2>/dev/null | tr -d ' ')" || compte=""
  printf '%s (pid %s%s)\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${compte:+, compte $compte}"
}

port_state() {
  local port="$1" tenu own proj; shift
  tenu="$(port_holder "$port")"
  if [[ "$tenu" == *"(projet "* ]]; then
    proj="${tenu##*(projet }"; proj="${proj%)}"
    for own in "$@"; do [[ "$proj" == "$own" ]] && { printf 'nous %s\n' "$tenu"; return 0; }; done
  fi
  if [[ -n "$tenu" ]]; then printf 'pris par %s\n' "$tenu"
  elif port_taken "$port"; then echo pris
  else echo libre
  fi
  return 0
}

as_human() {
  local home
  home="$(getent passwd "$PROV_HUMAN" | cut -d: -f6 || true)"
  [[ -n "$home" ]] || { p_fail "as_human: user inconnu: $PROV_HUMAN"; return 1; }
  if [[ "$(id -un)" == "$PROV_HUMAN" ]]; then
    "$@"
  elif [[ "$EUID" -eq 0 ]]; then
    ( cd "$home" && runuser -u "$PROV_HUMAN" -- env HOME="$home" USER="$PROV_HUMAN" LOGNAME="$PROV_HUMAN" "$@" )
  else
    p_fail "as_human: appelé par $(id -un), ni root ni $PROV_HUMAN — à relancer en root"
    return 1
  fi
}

human_home() { getent passwd "$PROV_HUMAN" | cut -d: -f6 || true; }

PROV_UID_MIN="" PROV_UID_MAX="" PROV_UID_BOUNDS_WHY=""
prov_uid_bounds() { # pose PROV_UID_MIN et PROV_UID_MAX depuis login.defs — 0 si les deux se lisent ; 1 sinon, le remède dans PROV_UID_BOUNDS_WHY
  local defs manque=""; defs="$(prov_decor /etc/login.defs)"
  PROV_UID_MIN="$(awk '$1 == "UID_MIN" {print $2; exit}' "$defs" 2>/dev/null || true)"
  PROV_UID_MAX="$(awk '$1 == "UID_MAX" {print $2; exit}' "$defs" 2>/dev/null || true)"
  [[ "$PROV_UID_MIN" =~ ^[0-9]+$ ]] || manque=UID_MIN
  [[ -n "$manque" || "$PROV_UID_MAX" =~ ^[0-9]+$ ]] || manque=UID_MAX
  if [[ -z "$manque" ]]; then PROV_UID_BOUNDS_WHY=""; return 0; fi
  PROV_UID_MIN="" PROV_UID_MAX=""
  # phrase identique à celle du protocole du produit (module-protocol.sh), que ses témoins épinglent sans accents
  PROV_UID_BOUNDS_WHY="la frontiere systeme/humain n'est pas etablie ($manque illisible dans $defs) — la borne est declaree par le systeme, pas par ce processus : repare $defs"
  return 1
}

# LE JUMEAU DE `seat_uid` DU PROTOCOLE DU PRODUIT (runtime/services/lib/module-protocol.sh) : la
# politique de POPULATION — le fichier, puis `LCARS_SYSADMIN_UID`. L'installeur ne source pas le
# protocole du produit (il en importerait tous les défauts), d'où deux écritures ; leur accord est
# tenu par un témoin, pas par la mémoire de qui les lit. L'autre politique, celle des gardes qui
# REFUSENT un lancement, lit le fichier seul et ne s'écrit pas ici.
# Elle rend 1 quand rien n'établit le siège, là où le jumeau du produit rend 0 et une valeur vide :
# ici les appelants lisent le CODE (`prov_seat_uid || { … }`), là-bas la VALEUR, parce qu'un code non
# nul dans `v="$(…)"` tuerait le module sous `set -e`. Deux contrats, une seule politique.
prov_seat_uid() { # rend l'uid du siège, ou 1 si aucune source ne l'établit
  local v
  if [[ -r "$PROV_SEAT_UID_FILE" ]]; then
    v="$(head -n1 -- "$PROV_SEAT_UID_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  fi
  v="${LCARS_SYSADMIN_UID:-}"
  [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  return 1
}

fleet_humans() {
  local seat
  seat="$(prov_seat_uid)" || {
    echo "fleet_humans: siège non établi (ni $PROV_SEAT_UID_FILE, ni LCARS_SYSADMIN_UID) — population non mesurable" >&2
    return 1
  }
  prov_uid_bounds || { echo "fleet_humans: $PROV_UID_BOUNDS_WHY" >&2; return 1; }
  awk -F: -v m="$PROV_UID_MIN" -v M="$PROV_UID_MAX" -v s="$seat" \
      '$3+0 >= m && $3+0 <= M && $3+0 != s {print $1}' "$(prov_decor /etc/passwd)"
}

repo_root() { readlink -f "$_PROV_LIB_DIR/../.."; }
# le meme arbre, sous un nom que la table de transport peut lire (elle rend des variables, pas des appels)
PROV_SOURCE_DIR="$(repo_root)"
product_tree() { local r; r="$(repo_root)"; if [[ -d "$r/runtime" && ! -e "$r/services" ]]; then printf '%s' "$r/runtime"; else printf '%s' "$r"; fi; }

# la traduction unique : le nom que lit le produit (runtime/services), puis le nom de l'installeur
PROV_PRODUCT_NAMES=(
  FORGE_BASE_URL=PROV_FORGE_URL
  FORGE_PUBLIC_URL=PROV_FORGE_PUBLIC_URL
  LCARS_PRIVATE_DIR=PROV_TOKENS_DIR
  LCARS_MASTER_TOKEN_FILE=PROV_MASTER_TOKEN_FILE
  LCARS_FORGE_SEED_FILE=PROV_FORGE_SEED_FILE
  LCARS_SYSTEM_ACCOUNT=PROV_SYSTEM_ACCOUNT
  LCARS_SYSTEM_TOKEN_FILE=PROV_SYSTEM_TOKEN_FILE
  LCARS_SYSTEM_USER=PROV_SYSTEM_USER
  LCARS_AUTHORITY_USER=PROV_AUTHORITY_USER
  LCARS_FORGE_ORG=PROV_FORGE_ORG
  LCARS_OPS_REPO=PROV_OPS_REPO
  LCARS_LOGIN=PROV_HUMAN
  LCARS_BUILTIN_HUMAN=PROV_BUILTIN_HUMAN
  LCARS_CATALOGUES_DIR=PROV_CATALOGUES_DIR
  # L'ARBRE DONT CETTE MACHINE EST INSTALLEE : le geste de forge en fait le projet du systeme sur la
  # forge, et la porte du runtime en seme la face de code. Seul l'installeur sait ou il est.
  LCARS_SYSTEM_SOURCE=PROV_SOURCE_DIR
  LCARS_CATALOGUES_WORK=PROV_CATALOGUES_WORK
  LCARS_LANDING_PORT=PROV_DECK_PORT
  LCARS_DECK_OIDC_FILE=PROV_DECK_OIDC_FILE
  LCARS_ADVERTISE=PROV_ADVERTISE
  LCARS_ADVERTISE_WHY=PROV_ADVERTISE_WHY
)

prov_product_env() { # prov_product_env → PROV_PRODUCT_ENV, un « NOM=valeur » par ligne de la table, prêt pour env
  local p src
  PROV_PRODUCT_ENV=()
  for p in "${PROV_PRODUCT_NAMES[@]}"; do
    src="${p#*=}"
    PROV_PRODUCT_ENV+=("${p%%=*}=${!src}")
  done
}

# prov_geste <geste> <check|apply> [NOM=valeur…] — joue runtime/services/forge.d/<geste>.sh sous le protocole du
# produit et sort de son code. La garde du produit (LCARS_MODULE_RUN) rend 3 sur une mort avant verdict : le code
# qui remonte EST un verdict, quel qu'il soit, et le module ne le rejuge pas.
prov_geste() {
  local geste="$1" verbe="$2" rc=0 arbre protocole script; shift 2
  prov_product_env
  arbre="$(product_tree)"
  protocole="$arbre/services/lib/module-protocol.sh"
  script="$arbre/services/forge.d/$geste.sh"
  # Ce qui manque AVANT le lancement se dit ici : plus bas, un geste absent sort en 127 et un
  # protocole illisible en 1, deux codes qu'aucun verdict n'explique.
  if [[ ! -r "$script" || ! -r "$protocole" ]]; then
    p_fail "geste « $geste » injouable : $script ou $protocole illisible — la release n'est pas posée (checkout incomplet, ou module 60 non joué)"
    if [[ "$verbe" == apply ]]; then verdict_apply; else verdict_check; fi
  fi
  env "${PROV_PRODUCT_ENV[@]}" "$@" \
    LCARS_MODULE_PROTOCOL="$protocole" LCARS_MODULE_TAG="$PROV_MODULE_TAG" \
    LCARS_MODULE_RUN=1 \
    bash "$script" "$verbe" || rc=$?
  # Le vocabulaire du protocole va de 0 a 3 : ces codes-la SONT des verdicts (3 = la garde du geste
  # a parlé), et ce module les relaie. Au-delà, le geste est mort sans qu'aucune garde ne l'ait vu :
  # la garde de CE module rend 3 à sa place, plutôt qu'un code brut lu comme un échec.
  [[ "$rc" -le 3 ]] && PROV_VERDICT_RENDERED=1
  exit "$rc"
}

prov_source_rev() { # prov_source_rev [racine] — la révision de l'arbre, ou « inconnue »
  local root="${1:-$(repo_root)}" rev
  if rev="$(git -C "$root" rev-parse --short=8 HEAD 2>/dev/null)" && [[ -n "$rev" ]]; then
    git -C "$root" diff --quiet HEAD -- 2>/dev/null || rev="$rev+local"
    printf '%s\n' "$rev"
    return 0
  fi
  if [[ -r "$root/$PROV_SOURCE_STAMP" ]]; then
    printf '%s\n' "$(head -n1 "$root/$PROV_SOURCE_STAMP" | tr -d '[:space:]')"
    return 0
  fi
  printf 'inconnue\n'
}

PROV_REMEMBERED=(PROV_DECK_PORT PROV_FORGE_HOST_PORT PROV_SSH_PORT PROV_FORGE_BASE PROV_BUILTIN_HUMAN)

prov_params_line() { # la ligne `params` du journal : `NOM=valeur …`, les choix qui s'écartent de leur défaut
  local n d out=""
  for n in "${PROV_REMEMBERED[@]}"; do
    d="${n}_DEFAULT"
    [[ "${!n}" == "${!d}" ]] || out="$out ${n}=${!n}"
  done
  printf '%s\n' "${out# }"
}

prov_delivery() { # prov_delivery [racine] -> `binary` | `source`
  local root="${1:-$(repo_root)}"
  if [[ -f "$root/$PROV_SOURCE_STAMP" ]]; then printf 'binary\n'; else printf 'source\n'; fi
}

prov_delivery_is_binary() { [[ "$(prov_delivery "$@")" == "binary" ]]; }

# mix release --overwrite laisse les lib/lcars_fleet-<ancienne> d'une assemblée précédente : celle qui démarre est dans start_erl.data
release_app_dir() { # release_app_dir <racine de release> → lib/lcars_fleet-<vsn> de la version qui démarre
  local root="$1" vsn d
  vsn="$(awk '{print $2; exit}' "$root/releases/start_erl.data" 2>/dev/null || true)"
  if [[ -n "$vsn" && -d "$root/lib/lcars_fleet-$vsn" ]]; then printf '%s\n' "$root/lib/lcars_fleet-$vsn"; return 0; fi
  d=("$root"/lib/lcars_fleet-*)
  [[ "${#d[@]}" -eq 1 && -d "${d[0]}" ]] && { printf '%s\n' "${d[0]}"; return 0; }
  return 1
}

prov_channel() { # prov_channel → PROV_CHANNEL et stdout : source | kit | aucun (canal absent) ; rc 1 et un FAIL sur une autre valeur
  local v
  PROV_CHANNEL=""
  if [[ ! -e "$PROV_CHANNEL_FILE" ]]; then
    PROV_CHANNEL=aucun; printf 'aucun\n'
    return 0
  fi
  v="$(head -n1 "$PROV_CHANNEL_FILE" 2>/dev/null | tr -d '[:space:]' || true)"
  case "$v" in
    source|kit) PROV_CHANNEL="$v"; printf '%s\n' "$v"; return 0 ;;
  esac
  p_fail "canal d'installation illisible : $PROV_CHANNEL_FILE porte « $v », attendu source ou kit — à corriger à la main, ou à retirer si cette machine n'a jamais été posée"
  return 1
}

prov_channel_write() { # prov_channel_write <source|kit>
  local mode owner
  mode="$(prov_manifest_mode "$PROV_CHANNEL_FILE")"
  owner="$(prov_manifest_owner "$PROV_CHANNEL_FILE")"
  write_atomic "$PROV_CHANNEL_FILE" "$mode" "$owner" <<<"$1"
}

prov_channel_here() { if prov_delivery_is_binary "$@"; then printf 'kit\n'; else printf 'source\n'; fi; }

prov_rev_is_behind() { # prov_rev_is_behind <rev_source> <rev_posee> → 0 si la source est un ancêtre strict de ce qui est posé · 1 sinon · 2 indéterminable
  local a="${1%%+*}" b="${2%%+*}" root
  root="$(repo_root)"
  [[ -n "$a" && -n "$b" && "$a" != "inconnue" && "$b" != "inconnue" ]] || return 2
  [[ "$a" == "$b" ]] && return 1
  git -C "$root" cat-file -e "$a^{commit}" 2>/dev/null || return 2
  git -C "$root" cat-file -e "$b^{commit}" 2>/dev/null || return 2
  git -C "$root" merge-base --is-ancestor "$a" "$b" 2>/dev/null && return 0
  return 1
}

prov_seat_from_map() { # le login du siege enregistre, ou vide
  [[ -r "$PROV_UID_MAP_FILE" ]] || return 0
  awk -F'\t' '$1 == 1 { print $3; exit }' "$PROV_UID_MAP_FILE" 2>/dev/null
}

prov_seat_record() { # prov_seat_record <login> <uid> — la ligne du siège, sur une carte qui n'en porte pas
  printf '1\t%s\t%s\n' "$2" "$1" >> "$PROV_UID_MAP_FILE" 2>/dev/null || return 1
  chmod 0640 "$PROV_UID_MAP_FILE"
}


arch_tag() {
  local deb; deb="$(dpkg --print-architecture 2>/dev/null || true)"
  case "$1:$deb" in
    raw:*)                       echo "$deb" ;;
    debian:amd64|debian:arm64)   echo "$deb" ;;
    node:amd64)                  echo x64 ;;
    node:arm64)                  echo arm64 ;;
    *)                           echo "" ;;
  esac
}


# forge_api <méthode> <url> <sortie> [--token-file <f> | --basic <login> <f>] [--json <filtre jq> [--arg <nom> <valeur> | --rawfile <nom> <f>]…] [option curl…]
#   → le code HTTP sur stdout ; rend 0 pour un 2xx · 3 pour un 3xx · 4 pour un 4xx · 5 pour un 5xx · 1 sans réponse entière
# Aucun secret dans un argv ni dans l'environnement d'un enfant : un secret se lit dans un fichier ou
# un descripteur (<(printf '%s' "$pw")), l'en-tête d'authentification arrive à curl par son entrée
# (-H @-), le corps de --json sort de « jq -n ». Toute autre option va telle quelle à curl, après les défauts.
forge_api() {
  local method="$1" url="$2" out="$3" auth="" filtre="" code tok pw fd=""; shift 3
  local -a jq_args=() curl_args=(-sS -m 15) corps=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --token-file) tok="$(read_token "$2")"; [[ -z "$tok" ]] || auth="token $tok"; shift 2 ;;
      --basic)      pw=""; IFS= read -r pw < "$3" || true
                    auth="Basic $(printf '%s:%s' "$2" "$pw" | base64 -w0)"; shift 3 ;;
      --json)       filtre="$2"; shift 2 ;;
      --arg)        jq_args+=(--arg "$2" "$3"); shift 3 ;;
      --rawfile)    jq_args+=(--rawfile "$2" "$3"); shift 3 ;;
      *)            curl_args+=("$1"); shift ;;
    esac
  done
  # un <(…) affecté à une variable serait fermé avant que curl le lise : le descripteur s'ouvre par exec
  if [[ -n "$filtre" ]]; then
    exec {fd}< <(jq -cn "${jq_args[@]}" "$filtre")
    corps=(-H 'Content-Type: application/json' --data-binary "@/dev/fd/$fd")
  fi
  # un curl en échec (délai dépassé, sortie non inscriptible) peut rendre un 200 sur un corps tronqué : il vaut « sans réponse »
  code="$( { [[ -z "$auth" ]] || printf 'Authorization: %s\n' "$auth"; } \
    | curl "${curl_args[@]}" -H @- "${corps[@]}" -X "$method" -o "$out" -w '%{http_code}' "$url" 2>/dev/null)" || code=000
  [[ -z "$fd" ]] || exec {fd}<&-
  printf '%s\n' "${code:-000}"
  case "$code" in
    2??) return 0 ;;
    3??) return 3 ;;
    4??) return 4 ;;
    5??) return 5 ;;
    *)   return 1 ;;
  esac
}

forge_repond() { # forge_repond <url> <délai en s> → 0 si /api/v1/version rend une réponse 2xx ou 3xx (une redirection vers https est une forge vivante)
  local rc=0
  forge_api GET "$1/api/v1/version" /dev/null -m "$2" >/dev/null || rc=$?
  [[ "$rc" -eq 0 || "$rc" -eq 3 ]]
}

forge_up() { forge_repond "$PROV_FORGE_URL" 5; }   # la forge de cette installation répond

# prov_roster_conteneur <image> <exec…> — le roster dérivé de l'image, posé 0644 dans la recette d'un
# conteneur par <exec…>, qui joue en root et lit son entrée ; imprime la sortie de la dérivation
# EXIT 0 · 1 dérivation en échec · 2 dépôt refusé
# « install /dev/stdin » de uutils refuse un tube quand la destination existe : le dépôt passe par un temporaire voisin
prov_roster_conteneur() {
  local image="$1" dir out rc=0; shift
  dir="$(mktemp -d "${TMPDIR:-/tmp}/prov-roster.XXXXXX")"
  out="$("$_PROV_LIB_DIR/enroll-catalogue.sh" --tofu-dir "$dir" --image "$image")" || rc=1
  if [[ "$rc" -eq 0 ]]; then
    # shellcheck disable=SC2016 # $1 et $t sont ceux du shell du conteneur
    "$@" sh -c 't="$(mktemp "$1.XXXXXX")" && cat > "$t" && chmod 0644 "$t" && mv -f "$t" "$1" || { rm -f "$t"; exit 1; }' \
      sh "$(prov_canon "$PROV_ROOT")/services/forge-recipe/roles.auto.tfvars.json" < "$dir/roles.auto.tfvars.json" || rc=2
  fi
  rm -rf "$dir"
  [[ "$rc" -ne 0 ]] || printf '%s\n' "$out"
  return "$rc"
}

prov_forge_seat_login() {
  [[ -s "$PROV_MASTER_TOKEN_FILE" && -n "$PROV_FORGE_URL" ]] || return 0
  local body; body="$(mktemp "${TMPDIR:-/tmp}/prov-forge.XXXXXX")"
  if forge_api GET "$PROV_FORGE_URL/api/v1/admin/users?limit=50" "$body" --token-file "$PROV_MASTER_TOKEN_FILE" >/dev/null; then
    jq -r 'map(select(.id == 1)) | .[0].login // empty' "$body" 2>/dev/null || true
  fi
  rm -f "$body"
}

PROV_SEAT_BINDING=""
PROV_SEAT_LOGIN=""
PROV_SEAT_SOURCE=""
prov_seat_binding() { # prov_seat_binding <candidat unix> → PROV_SEAT_BINDING agree | diverge | seeded
  local candidat="$1" durable source=table
  durable="$(prov_seat_from_map)"
  if [[ -z "$durable" ]]; then
    durable="$(prov_forge_seat_login)"
    source=forge
  fi
  if [[ -z "$durable" ]]; then
    PROV_SEAT_LOGIN="$candidat"; PROV_SEAT_SOURCE=candidat; PROV_SEAT_BINDING=seeded
  else
    PROV_SEAT_LOGIN="$durable"; PROV_SEAT_SOURCE="$source"
    if [[ "$durable" == "$candidat" ]]; then PROV_SEAT_BINDING=agree; else PROV_SEAT_BINDING=diverge; fi
  fi
}

prov_dans_la_copie() { # prov_dans_la_copie -> 0 si ce rail tourne depuis la copie posée
  [[ "$(repo_root)" == "${PROV_ROOT}" ]]
}
