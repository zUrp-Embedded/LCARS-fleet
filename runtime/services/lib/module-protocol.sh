#!/usr/bin/env bash
# SOURCE: runtime/services/lib/module-protocol.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: actif — le protocole des MODULES DU PRODUIT : gestes de forge (`forge.d`) et modules per-humain (`human.d`)
#
# ⚖ user 2026-09-04 (Q3 du chantier deploy-independance) : « la frontiere, c'est : joue uniquement
# a l'install, ou utilise en prod ? ». Les gestes de forge — le cache des catalogues, la branche
# ops, le client OAuth2 du deck — sont joues par le CONTENEUR a l'init de son instance et a chaque boot
# pour reconverger, donc en prod ; le poste les joue a l'install. Ils etaient des modules de
# l'installeur, ecrits dans son dialecte (`p_*`, `verdict_*`, `PROV_*` — devenus `LCARS_*` au lot 8 : un seul vocabulaire cote produit, l'installeur traduit) et sources sur sa lib. Ils
# sont ici, dans le meme dialecte, sur CE protocole — et l'installeur les APPELLE (le sens permis).
#
# CE FICHIER EST LE VOCABULAIRE QUE CES MODULES ATTENDENT, ET RIEN D'AUTRE : les sept fonctions
# d'impression, les deux verdicts, les lectures (fichier d'env, jeton, forge authentifiee, etat
# d'un fichier), les mutations (repertoire, fichier atomique, mode), l'adresse annoncee, et les
# defauts des variables qu'ils lisent — les MEMES valeurs que l'installeur pose sur la machine, par
# CONVENTION de layout, pas par partage : `/opt/lcars/runtime`, `/opt/lcars/var/tokens`…
# Une copie, un contrat, source par le module (`LCARS_MODULE_PROTOCOL`) et par ses temoins.
# `human-protocol.sh` le source et y ajoute ce qui n'a de sens que pour une PERSONNE.
#
# ⚠ SOURCE, JAMAIS EXECUTE : aucun `set -e` ici, aucune sortie. Les modules font leur
# `set -euo pipefail` eux-memes, avant de le charger.

: "${LCARS_MODULE_TAG:=module}"
LCARS_DRIFT=0
LCARS_FAILED=0
# shellcheck disable=SC2034  # les modules le comptent (un geste pose) ; le verdict ne le lit pas
LCARS_CHANGED=0
: "${LCARS_DUMP_LINES:=40}"
: "${LCARS_MODULE_MODE:=apply}"

# ─── Les faits, puis ce qui s'en derive ────────────────────────────────────────────────────────
# ⚠ LES FAITS NE SONT PLUS ECRITS ICI : ils vivent dans `etc/facts.env`, que le Python, l'Elixir et
# l'installeur lisent aussi (⚖ decision 3), et `lib/facts.sh` est l'unique lecteur du shell.
# Ce qui suit se DERIVE d'un fait — une regle, pas un fait — et se derive donc chez le lecteur.
# shellcheck source=facts.sh
. "${LCARS_FACTS_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/facts.sh}"

: "${LCARS_SYSTEM_GROUP:=$LCARS_SYSTEM_USER}"
: "${LCARS_SYSTEM_TOKEN_FILE:=$LCARS_PRIVATE_DIR/$LCARS_SYSTEM_ACCOUNT.gitea_token}"
: "${LCARS_MASTER_TOKEN_FILE:=$LCARS_PRIVATE_DIR/forge-master.token}"
: "${LCARS_FORGE_SEED_FILE:=$LCARS_PRIVATE_DIR/forge-seed.pass}"
# Le depot du systeme vit dans l'org systeme : derive, pour qu'une org renommee par l'installeur
# emmene son depot. L'installeur le transporte aussi (services.env) pour les daemons qui ne
# sourcent pas ce protocole ; le runtime le lit dans `runtime.exs`.
: "${LCARS_OPS_REPO:=${LCARS_FORGE_ORG}/_ops}"
# L'adresse de la forge : celle de l'hote (`FORGE_BASE_URL`), sinon celle que l'install a gravee.
# Vide reste vide — les modules lisent « pas de forge » et le disent, ils n'inventent pas.
: "${FORGE_BASE_URL:=$(cat "$LCARS_PRIVATE_DIR/forge.url" 2>/dev/null || true)}"
: "${FORGE_PUBLIC_URL:=$(cat "$LCARS_PRIVATE_DIR/forge.public.url" 2>/dev/null || true)}"
: "${FORGE_PUBLIC_URL:=$FORGE_BASE_URL}"
: "${LCARS_DECK_ORIGINS:=}"

# ─── Le vocabulaire ────────────────────────────────────────────────────────────────────────────
p_step() { printf '>>    %s: %s\n' "$LCARS_MODULE_TAG" "$*"; }
p_ok()   { printf 'OK    %s: %s\n' "$LCARS_MODULE_TAG" "$*"; return 0; }
p_chg()  { printf 'POSÉ  %s: %s\n' "$LCARS_MODULE_TAG" "$*"; return 0; }
p_drift(){ printf 'DRIFT %s: %s\n' "$LCARS_MODULE_TAG" "$*" >&2; LCARS_DRIFT=$((LCARS_DRIFT + 1)); }
p_warn() { printf 'WARN  %s: %s\n' "$LCARS_MODULE_TAG" "$*" >&2; }
p_fail() { printf 'FAIL  %s: %s\n' "$LCARS_MODULE_TAG" "$*" >&2; LCARS_FAILED=$((LCARS_FAILED + 1)); }
p_die()  { LCARS_VERDICT_RENDERED=1; printf 'FATAL %s: %s\n' "$LCARS_MODULE_TAG" "$*" >&2; exit 1; }

# `apply` rend 1 des qu'un geste a echoue ; 2 = applique avec drift residuel (un geste manque, pas
# une panne). `check` rend 2 sur un echec et 1 sur un drift — le code du doctor, lu comme tel par
# celui qui appelle (l'installeur, ou le boot du conteneur).
verdict_apply() { LCARS_VERDICT_RENDERED=1; [[ "$LCARS_FAILED" -gt 0 ]] && exit 1; [[ "$LCARS_DRIFT" -gt 0 ]] && exit 2; exit 0; }
verdict_check() { LCARS_VERDICT_RENDERED=1; [[ "$LCARS_FAILED" -gt 0 ]] && exit 2; [[ "$LCARS_DRIFT" -gt 0 ]] && exit 1; exit 0; }

# ─── LES CODES DU PROTOCOLE, ET LA MORT AVANT VERDICT ──────────────────────────────────────────
# 0, 1 et 2 sont des VERDICTS, rendus par `verdict_apply` ou `verdict_check` ; 1 l'est aussi par
# `p_die`. 3 N'EST LE VERDICT DE PERSONNE : c'est la mort avant verdict. Un module qui meurt sous
# `set -e` sort du code de la commande qui a echoue, et 1 ou 2 se liraient « echec » ou « drift
# residuel » alors que RIEN n'a ete conclu. AU-DESSUS DE 3, un module peut nommer un etat qui lui
# appartient (`container/init.sh` rend 4 : « en attente de configuration ») — jamais 3, jamais un
# code de verdict.
#
# Celui qui LANCE le module arme la garde (LCARS_MODULE_RUN) ; elle se desarme aussitot, pour
# qu'aucun processus enfant qui sourcerait ce protocole n'en herite. L'installeur a la sienne, de
# meme forme (`deploy/lib/provision-lib.sh`, PROVISION_RUN) : elle couvre ce qui meurt AVANT que le
# geste ait source ce fichier — le geste absent, le protocole illisible.
LCARS_VERDICT_RENDERED=0
_lcars_exit_guard() {
  local rc=$?
  [[ "$LCARS_VERDICT_RENDERED" -eq 1 ]] && return 0
  printf 'ERREUR %s: mort avant de rendre son verdict (rc=%d)\n' "$LCARS_MODULE_TAG" "$rc" >&2
  exit 3
}
if [[ -n "${LCARS_MODULE_RUN:-}" ]]; then
  trap _lcars_exit_guard EXIT
  unset LCARS_MODULE_RUN
fi

# ─── LE SIEGE : DEUX POLITIQUES ASSUMEES, ET CELLE-CI EST LA SECONDE ───────────────────────────
#
# Qui REFUSE UN LANCEMENT lit le fichier SEUL et meurt sans lui (`bin/fleet`, GUARD B du BEAM) :
# reposer une variable d'environnement suffirait sinon a desarmer la garde.
#
# Qui decide d'une POPULATION lit le fichier, puis `LCARS_SYSADMIN_UID` — c'est cette fonction. Le
# repli sert la ou le fichier n'est pas encore pose : l'installeur avant la fin de sa passe, et le
# boot du conteneur, qui exporte l'uid du siege qu'il vient de creer. Une population mesuree sans
# siege compterait l'administrateur de la machine parmi les humains de la fleet.
#
# Elle vit ICI et pas chez chaque lecteur : le convergeur, les gestes de forge et le protocole des
# personnes la lisent tous du meme endroit. L'installeur en tient le jumeau (`prov_seat_uid`), que
# son mur compare a celle-ci.
# ⚠ ELLE REND TOUJOURS 0, LA OU LE JUMEAU DE L'INSTALLEUR (`prov_seat_uid`) REND 1 QUAND RIEN
# N'ETABLIT LE SIEGE. Ce n'est pas un oubli : ici les appelants ecrivent `v="$(seat_uid)"` sous
# `set -e`, ou un code non nul tuerait le module au lieu de lui laisser dire pourquoi. Le fait
# « pas de siege » se lit donc a la valeur VIDE, et l'appelant en decide.
# LE CHEMIN DU SIEGE, ECRIT UNE FOIS. Ses lecteurs le nomment dans leurs refus — « ce fichier est
# absent » n'aide personne si le message invente un autre chemin que celui qu'on a lu.
seat_uid_file() { printf '%s' "${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"; }

seat_uid() { # -> l'uid du siege, ou rien (l'appelant dit ce que « rien » lui fait)
  local f v
  f="$(seat_uid_file)"
  if [[ -r "$f" ]]; then
    v="$(head -n1 -- "$f" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  fi
  v="${LCARS_SYSADMIN_UID:-}"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v"
  return 0
}

# ─── Les lectures ──────────────────────────────────────────────────────────────────────────────
# Un champ d'un fichier d'environnement (`CLE=valeur`, la derniere occurrence gagne) — jamais un
# `source` : un fichier d'env n'est pas du code qu'on execute sous root.
env_field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | tail -n1 || true; }

# Un jeton se lit sans blancs, ou rien : jamais un message, jamais un echec.
read_token() { # read_token <fichier>
  [[ -n "${1:-}" && -r "$1" ]] && tr -d '[:space:]' < "$1"
  return 0
}

# La forge, authentifiee par un fichier de jeton : l'en-tete arrive par STDIN (`-K -`), jamais par
# argv — un `ps` ne doit pas le voir. Sans jeton lisible, la requete part nue : c'est a la forge de
# refuser, et au module de lire le code.
forge_curl() { # forge_curl <fichier de jeton> <args curl…>
  local tokfile="$1" tok=""; shift
  tok="$(read_token "$tokfile")"
  { [[ -n "$tok" ]] && printf 'header = "Authorization: token %s"\n' "$tok" || true; } \
    | curl -K - "$@"
}

# L'etat d'un fichier, en QUATRE mots et pas deux : « absent » n'est vrai que si l'on a PU regarder.
prov_file_state() { # prov_file_state <chemin> -> present | unreadable | absent | unmeasurable
  local p="$1" d
  if [[ -e "$p" ]]; then
    [[ -r "$p" ]] && { printf 'present\n'; return 0; }
    printf 'unreadable\n'; return 0
  fi
  d="$(dirname "$p")"
  while [[ "$d" != "/" && ! -e "$d" ]]; do d="$(dirname "$d")"; done
  if [[ -x "$d" ]]; then printf 'absent\n'; else printf 'unmeasurable\n'; fi
}
prov_state_why() { # prov_state_why <etat> <chemin>
  case "$1" in
    unreadable)   printf 'présent, mais illisible pour %s — rien n'"'"'est conclu sur son contenu (relance sous sudo pour le mesurer)\n' "$(id -un 2>/dev/null || echo '?')" ;;
    unmeasurable) printf 'NON MESURABLE ici : un répertoire du chemin (%s) n'"'"'est pas traversable par %s — ni présent ni absent, on ne sait pas\n' "$(dirname "$2")" "$(id -un 2>/dev/null || echo '?')" ;;
  esac
}

# Une commande dont la sortie ne compte que si elle echoue.
run_quiet() {
  local o
  if ! o="$("$@" 2>&1)"; then printf '%s\n' "$o" >&2; return 1; fi
}

# ─── Les mutations ─────────────────────────────────────────────────────────────────────────────
# Aucune mutation privilegiee ne traverse un symlink : un chemin qu'on n'a pas pose ne se suit pas.
prov_refuse_symlink_path() {
  local path="$1" cur="" part
  local -a parts
  [[ "$path" == /* ]] || { p_fail "mutation privilegiee REFUSEE — chemin relatif: $path"; return 1; }
  IFS='/' read -ra parts <<< "${path#/}"
  for part in "${parts[@]}"; do
    [[ -z "$part" ]] && continue
    cur="$cur/$part"
    if [[ -L "$cur" ]]; then
      p_fail "mutation privilegiee REFUSEE — composant symlink: $cur -> $(readlink "$cur")"
      return 1
    fi
  done
  return 0
}
prov_owner() { # prov_owner <user[:group]> → user:group — « user: » prend le groupe de connexion de user ; les coreutils uutils (Ubuntu 26.04) ignorent la forme nue
  local o="$1" g
  [[ "$o" == *: ]] || { printf '%s' "$o"; return 0; }
  g="$(id -gn -- "${o%:}" 2>/dev/null)" || { printf '%s' "$o"; return 0; }
  printf '%s:%s' "${o%:}" "$g"
}
ensure_mode() { # ensure_mode <chemin> <mode> [proprietaire]
  local path="$1" mode="$2" owner="${3:-}"
  local cur_mode cur_owner changed=0
  owner="$(prov_owner "$owner")"
  prov_refuse_symlink_path "$path" || return 1
  [[ -e "$path" ]] || { p_fail "ensure_mode: absent: $path"; return 1; }
  cur_mode="$(stat -c '%a' "$path")"
  local want_mode="${mode#0}"
  if [[ "$cur_mode" != "$want_mode" ]]; then
    chmod u-s,g-s,o-t "$path" 2>/dev/null || true
    chmod "$mode" "$path" || { p_fail "ensure_mode: chmod $mode refusé: $path"; return 1; }
    changed=1
  fi
  if [[ -n "$owner" ]]; then
    cur_owner="$(stat -c '%U:%G' "$path")"
    if [[ "$cur_owner" != "$owner" ]]; then
      chown "$owner" "$path" || { p_fail "ensure_mode: chown $owner refusé: $path"; return 1; }
      changed=1
    fi
  fi
  [[ "$(stat -c '%a' "$path")" == "$want_mode" ]] || { p_fail "ensure_mode: mode ≠ $want_mode après chmod: $path"; return 1; }
  if [[ "$changed" -eq 1 ]]; then LCARS_CHANGED=$((LCARS_CHANGED + 1)); p_chg "perms $mode ${owner:+$owner }$path"; fi
  return 0
}
ensure_dir() { # ensure_dir <chemin> <mode> [proprietaire]
  local path="$1" mode="$2" owner="${3:-}"
  prov_refuse_symlink_path "$path" || return 1
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" || { p_fail "ensure_dir: mkdir refusé: $path"; return 1; }
    LCARS_CHANGED=$((LCARS_CHANGED + 1)); p_chg "dir $path"
  fi
  ensure_mode "$path" "$mode" "$owner"
}
# Un fichier s'ecrit ENTIER puis bascule : personne ne lit un tampon a moitie ecrit, et un contenu
# identique ne compte pas pour un changement.
write_atomic() { # write_atomic <dest> <mode> [proprietaire]  < contenu
  local dest="$1" mode="$2" owner="${3:-}"
  local dir tmp
  owner="$(prov_owner "$owner")"
  prov_refuse_symlink_path "$dest" || return 1
  dir="$(dirname "$dest")"
  [[ -d "$dir" ]] || { p_fail "write_atomic: dossier absent: $dir"; return 1; }
  tmp="$(mktemp "$dir/.prov.XXXXXX")" || { p_fail "write_atomic: tmp impossible dans $dir"; return 1; }
  cat > "$tmp" || { rm -f "$tmp"; p_fail "write_atomic: ecriture du tampon RATEE (disque plein ? quota ?): $dest"; return 1; }
  if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
    rm -f "$tmp"
    ensure_mode "$dest" "$mode" "$owner"
    return $?
  fi
  chmod "$mode" "$tmp" || { rm -f "$tmp"; p_fail "write_atomic: chmod $mode: $dest"; return 1; }
  if [[ -n "$owner" ]]; then
    chown "$owner" "$tmp" || { rm -f "$tmp"; p_fail "write_atomic: chown $owner: $dest"; return 1; }
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; p_fail "write_atomic: mv final: $dest"; return 1; }
  LCARS_CHANGED=$((LCARS_CHANGED + 1))
  p_chg "$dest"
}

# ─── L'adresse annoncee ────────────────────────────────────────────────────────────────────────
# L'adresse que les liens et les retours OAuth doivent porter : celle du bind s'il en nomme une,
# sinon l'adresse de sortie de la machine. L'appelant qui en sait plus (l'installeur, qui connait
# WSL et son mode NAT) la POSE dans `LCARS_ADVERTISE` avant d'appeler : ici on ne la recalcule pas.
lan_addr() { ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true; }
advertise_addr() { # advertise_addr <bind>
  local bind="${1:-0.0.0.0}"
  if [[ -n "${LCARS_ADVERTISE:-}" ]]; then
    : "${LCARS_ADVERTISE_WHY:=}"
    return 0
  fi
  LCARS_ADVERTISE=""; LCARS_ADVERTISE_WHY=""
  case "$bind" in
    0.0.0.0|::|"*") ;;
    *) LCARS_ADVERTISE="$bind"; return 0 ;;
  esac
  LCARS_ADVERTISE="$(lan_addr)"
  if [[ -z "$LCARS_ADVERTISE" ]]; then
    LCARS_ADVERTISE="127.0.0.1"
    LCARS_ADVERTISE_WHY="aucune adresse de sortie détectée — les liens ne valent que sur cette machine"
  fi
  return 0
}

# ⚠ LA CLI DU RELEASE, CHERCHEE UNE FOIS. Trois gestes la cherchaient chacun de leur cote, avec le
# meme corps : ce que l'appelant designe, puis le PATH, puis la voisine de cet arbre.
lcars_cli() {
  [[ -n "${LCARS_CLI:-}" ]] && { printf '%s' "$LCARS_CLI"; return 0; }
  if command -v lcars >/dev/null 2>&1; then command -v lcars; return 0; fi
  printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/lcars"
}

# ⚠ LES ROLES SONT UN FAIT DU PRODUIT, PAS UN PLANCHER DE L'APPELANT (⚖ decision 2 du plan runtime).
# Ils se demandent au release : le catalogue embarque, puis chaque catalogue installe. Une liste
# ecrite a la main est une seconde verite qui derive — elle l'etait cinq fois dans cet arbre.
#
# ⚠ ET L'ECHEC EST UN ECHEC, jamais une liste vide. Un appelant qui confondrait les deux prendrait
# « aucun compte de role » pour une machine sans roles, alors qu'il n'a rien pu lire : rend 1, et
# c'est a l'appelant de decider ce que « je ne sais pas » lui fait.
lcars_roles() { # -> la liste des logins de role, ou 1 si la release ne repond pas
  local cli root brut=""
  cli="$(lcars_cli)"
  [[ -r "$cli" ]] || return 1
  brut="$(bash "$cli" tool roles 2>/dev/null || true)"
  if [[ -d "${LCARS_CATALOGUES_DIR:-}" ]]; then
    for root in "$LCARS_CATALOGUES_DIR"/*/; do
      [[ -f "${root}catalogue.yaml" ]] || continue
      brut+=$'\n'"$(bash "$cli" tool roles "${root%/}" 2>/dev/null || true)"
    done
  fi
  brut="$(printf '%s\n' "$brut" | awk 'NF' | sort -u | tr '\n' ' ' | sed 's/ $//')"
  [[ -n "$brut" ]] || return 1
  printf '%s' "$brut"
}
