#!/usr/bin/env bash
# SOURCE: fleet/services/lib/human-protocol.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: actif — le protocole des modules per-humain (`human.d`), cote PRODUIT
#
# ⚖ user 2026-09-04 (Q3 du chantier deploy-independance) : « la frontiere, c'est : joue uniquement
# a l'install, ou utilise en prod ? ». Les modules `human.d` sont joues EN PROD, a chaque humain
# que la forge inscrit, par le convergeur — jamais par l'installeur. Ils sourcaient pourtant
# `deploy/lib/provision-lib.sh`, par une garde `${PROVISION_LIB:?}` que leur seul hote reel ne
# pose pas : mesure du 2026-09-04 sur les deux bancs, chaque humain cree mourait a la ligne 1 de
# ses trois modules, rc=1, et la boite annoncait « converge ». Un humain sans `~/.lcars`, sans
# `claude`, sans projets — qui ne peut pas lancer de fleet.
#
# CE FICHIER EST LE VOCABULAIRE QUE CES MODULES ATTENDENT, ET RIEN D'AUTRE : sept fonctions
# d'impression, deux verdicts, quatre lectures (home, humain de fleet, champ d'env, forge
# authentifiee), une execution silencieuse, et les defauts des variables qu'ils lisent. Il est
# source par le convergeur (l'hote) ET par les temoins (`test/services/human.d`) — une copie, un
# contrat. L'installeur garde sa propre lib pour ses propres modules : ce ne sont plus deux copies
# d'un meme contrat, ce sont deux contrats, chacun chez celui qui le joue.
#
# ⚠ SOURCE, JAMAIS EXECUTE : aucun `set -e` ici (un fichier source ne pose pas les drapeaux de son
# hote), aucune sortie. Les modules font leur `set -euo pipefail` eux-memes, avant de le charger.

# ─── Le sujet ──────────────────────────────────────────────────────────────────────────────────
# `PROV_HUMAN` est pose par l'hote (le convergeur : le login qu'il converge). Sans lui, un module
# agirait sur l'utilisateur courant — root, sous le convergeur. On ne devine pas : on refuse.
: "${PROV_HUMAN:?PROV_HUMAN non pose — le convergeur nomme le login converge}"
: "${PROV_MODULE_TAG:=human}"
PROV_DRIFT=0
PROV_FAILED=0
# shellcheck disable=SC2034  # les modules le comptent (un geste pose) ; le verdict ne le lit pas
PROV_CHANGED=0

# ─── Les defauts que les modules lisent ────────────────────────────────────────────────────────
# Les memes valeurs que l'installeur pose sur la machine — par CONVENTION de layout, pas par
# partage : `/opt/lcars/runtime` est l'install RO du runtime, `/usr/local/bin` ses liens PATH,
# `/opt/lcars/var/tokens` les jetons. Un poste passe `services.env` au convergeur, une boite
# l'env du compose ; ce qui n'y est pas prend ces defauts.
: "${PROV_PREFIX:=/opt/lcars/runtime}"
: "${PROV_LINK_DIR:=/usr/local/bin}"
: "${PROV_FLEET_GROUP:=fleet}"
: "${PROV_TOKENS_DIR:=/opt/lcars/var/tokens}"
: "${PROV_SYSTEM_ACCOUNT:=${LCARS_SYSTEM_ACCOUNT:-system_starfleet}}"
: "${PROV_SYSTEM_TOKEN_FILE:=$PROV_TOKENS_DIR/$PROV_SYSTEM_ACCOUNT.gitea_token}"
# L'adresse de la forge : celle de l'hote (`FORGE_BASE_URL`), sinon celle que l'install a gravee.
# Vide reste vide — les modules lisent « pas de forge » et le disent, ils n'inventent pas.
: "${PROV_FORGE_URL:=${FORGE_BASE_URL:-$(cat "$PROV_TOKENS_DIR/forge.url" 2>/dev/null || true)}}"

# ─── Le vocabulaire ────────────────────────────────────────────────────────────────────────────
p_step() { printf '>>    %s: %s\n' "$PROV_MODULE_TAG" "$*"; }
p_ok()   { printf 'OK    %s: %s\n' "$PROV_MODULE_TAG" "$*"; return 0; }
p_chg()  { printf 'POSÉ  %s: %s\n' "$PROV_MODULE_TAG" "$*"; return 0; }
p_drift(){ printf 'DRIFT %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; PROV_DRIFT=$((PROV_DRIFT + 1)); }
p_warn() { printf 'WARN  %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; }
p_fail() { printf 'FAIL  %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; PROV_FAILED=$((PROV_FAILED + 1)); }
p_die()  { printf 'FATAL %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; exit 1; }

# `apply` rend 1 des qu'un geste a echoue ; 2 = applique avec drift residuel, qui est le cas
# NOMINAL d'un humain frais (il lui manque ses credentials `claude`, geste d'identite). `check`
# rend 2 sur un echec et 1 sur un drift — le code du doctor, que l'hote lit comme tel.
verdict_apply() { [[ "$PROV_FAILED" -gt 0 ]] && exit 1; [[ "$PROV_DRIFT" -gt 0 ]] && exit 2; exit 0; }
verdict_check() { [[ "$PROV_FAILED" -gt 0 ]] && exit 2; [[ "$PROV_DRIFT" -gt 0 ]] && exit 1; exit 0; }

# ─── Les lectures ──────────────────────────────────────────────────────────────────────────────
human_home() { getent passwd "$PROV_HUMAN" | cut -d: -f6 || true; }

# Un humain de fleet : un uid au-dessus du plancher des humains de la machine, et qui n'est pas le
# SIEGE — le siege est le sysadmin, converge par l'installeur, jamais par ces modules.
# Le plancher se lit dans `login.defs` (`PASSWD_DEFS`, le meme nom que le convergeur) ; le siege
# dans son fichier (`LCARS_SEAT_UID_FILE`), sinon dans `LCARS_SYSADMIN_UID` — la meme lecture, dans
# le meme ordre, que l'installeur : un seul siege sur la machine, quel que soit celui qui le lit.
seat_uid() { # rend l'uid du siege, ou rien
  local f v
  f="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
  if [[ -r "$f" ]]; then
    v="$(head -n1 -- "$f" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  fi
  v="${LCARS_SYSADMIN_UID:-}"
  [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
  return 0
}
is_fleet_human() { # [login] (defaut : PROV_HUMAN) — 0 si oui
  local login="${1:-$PROV_HUMAN}" uid uid_min seat
  uid="$(id -u -- "$login" 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  uid_min="$(awk '/^UID_MIN/{print $2}' "${PASSWD_DEFS:-/etc/login.defs}" 2>/dev/null | head -n1 || true)"
  [[ "$uid_min" =~ ^[0-9]+$ ]] || uid_min=1000
  seat="$(seat_uid)"
  (( uid >= uid_min )) && [[ "$uid" != "$seat" ]]
}

# Un champ d'un fichier d'environnement (`CLE=valeur`, la derniere occurrence gagne) — jamais un
# `source` : un fichier d'env de l'humain n'est pas du code qu'on execute sous root.
env_field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | tail -n1 || true; }

# Un jeton se lit sans blancs, ou rien : jamais un message, jamais un echec (un module qui lit un
# jeton absent doit pouvoir dire « pas de jeton » lui-meme).
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

# Une commande dont la sortie ne compte que si elle echoue.
run_quiet() {
  local o
  if ! o="$("$@" 2>&1)"; then printf '%s\n' "$o" >&2; return 1; fi
}
