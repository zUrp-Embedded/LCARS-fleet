#!/usr/bin/env bash
# SOURCE: fleet/services/lib/module-protocol.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: actif — le protocole des MODULES DU PRODUIT : gestes de forge (`forge.d`) et modules per-humain (`human.d`)
#
# ⚖ user 2026-09-04 (Q3 du chantier deploy-independance) : « la frontiere, c'est : joue uniquement
# a l'install, ou utilise en prod ? ». Les gestes de forge — le cache des catalogues, la branche
# ops, le client OAuth2 du deck — sont joues par la BOITE a l'init de son instance et a chaque boot
# pour reconverger, donc en prod ; le poste les joue a l'install. Ils etaient des modules de
# l'installeur, ecrits dans son dialecte (`p_*`, `verdict_*`, `PROV_*`) et sources sur sa lib. Ils
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

: "${PROV_MODULE_TAG:=module}"
PROV_DRIFT=0
PROV_FAILED=0
# shellcheck disable=SC2034  # les modules le comptent (un geste pose) ; le verdict ne le lit pas
PROV_CHANGED=0
: "${PROV_DUMP_LINES:=40}"
: "${PROV_MODE:=apply}"

# ─── Les defauts que les modules lisent ────────────────────────────────────────────────────────
: "${PROV_PREFIX:=/opt/lcars/runtime}"
: "${PROV_LINK_DIR:=/usr/local/bin}"
: "${PROV_FLEET_GROUP:=fleet}"
: "${PROV_TOKENS_DIR:=/opt/lcars/var/tokens}"
: "${PROV_AUTHORITY_USER:=lcars-authority}"
: "${PROV_SYSTEM_USER:=lcars-system}"
: "${PROV_SYSTEM_GROUP:=$PROV_SYSTEM_USER}"
: "${PROV_SYSTEM_ACCOUNT:=${LCARS_SYSTEM_ACCOUNT:-system_starfleet}}"
: "${PROV_SYSTEM_TOKEN_FILE:=$PROV_TOKENS_DIR/$PROV_SYSTEM_ACCOUNT.gitea_token}"
: "${PROV_MASTER_TOKEN_FILE:=$PROV_TOKENS_DIR/forge-master.token}"
: "${PROV_FORGE_SEED_FILE:=$PROV_TOKENS_DIR/forge-seed.pass}"
: "${PROV_FORGE_ORG:=fleet}"
: "${PROV_HUMANS_TEAM:=humans}"
: "${PROV_CATALOGUES_DIR:=/opt/lcars/var/catalogues}"
: "${PROV_LEGACY_CATALOGUES_DIR:=/home/catalogues}"
# L'adresse de la forge : celle de l'hote (`FORGE_BASE_URL`), sinon celle que l'install a gravee.
# Vide reste vide — les modules lisent « pas de forge » et le disent, ils n'inventent pas.
: "${PROV_FORGE_URL:=${FORGE_BASE_URL:-$(cat "$PROV_TOKENS_DIR/forge.url" 2>/dev/null || true)}}"
: "${PROV_FORGE_PUBLIC_URL:=${FORGE_PUBLIC_URL:-$(cat "$PROV_TOKENS_DIR/forge.public.url" 2>/dev/null || true)}}"
: "${PROV_FORGE_PUBLIC_URL:=$PROV_FORGE_URL}"
: "${PROV_DECK_PORT:=${LCARS_LANDING_PORT:-20999}}"
: "${PROV_DECK_BIND:=0.0.0.0}"
: "${PROV_DECK_OIDC_FILE:=/etc/lcars/deck-oidc.json}"
: "${PROV_DECK_ORIGINS:=${LCARS_DECK_ORIGINS:-}}"

# ─── Le vocabulaire ────────────────────────────────────────────────────────────────────────────
p_step() { printf '>>    %s: %s\n' "$PROV_MODULE_TAG" "$*"; }
p_ok()   { printf 'OK    %s: %s\n' "$PROV_MODULE_TAG" "$*"; return 0; }
p_chg()  { printf 'POSÉ  %s: %s\n' "$PROV_MODULE_TAG" "$*"; return 0; }
p_drift(){ printf 'DRIFT %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; PROV_DRIFT=$((PROV_DRIFT + 1)); }
p_warn() { printf 'WARN  %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; }
p_fail() { printf 'FAIL  %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; PROV_FAILED=$((PROV_FAILED + 1)); }
p_die()  { printf 'FATAL %s: %s\n' "$PROV_MODULE_TAG" "$*" >&2; exit 1; }

# `apply` rend 1 des qu'un geste a echoue ; 2 = applique avec drift residuel (un geste manque, pas
# une panne). `check` rend 2 sur un echec et 1 sur un drift — le code du doctor, lu comme tel par
# celui qui appelle (l'installeur, ou le boot de la boite).
verdict_apply() { [[ "$PROV_FAILED" -gt 0 ]] && exit 1; [[ "$PROV_DRIFT" -gt 0 ]] && exit 2; exit 0; }
verdict_check() { [[ "$PROV_FAILED" -gt 0 ]] && exit 2; [[ "$PROV_DRIFT" -gt 0 ]] && exit 1; exit 0; }

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
ensure_mode() { # ensure_mode <chemin> <mode> [proprietaire]
  local path="$1" mode="$2" owner="${3:-}"
  local cur_mode cur_owner changed=0
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
    [[ "$owner" == *: ]] && cur_owner="$(stat -c '%U' "$path"):"
    if [[ "$cur_owner" != "$owner" ]]; then
      chown "$owner" "$path" || { p_fail "ensure_mode: chown $owner refusé: $path"; return 1; }
      changed=1
    fi
  fi
  [[ "$(stat -c '%a' "$path")" == "$want_mode" ]] || { p_fail "ensure_mode: mode ≠ $want_mode après chmod: $path"; return 1; }
  if [[ "$changed" -eq 1 ]]; then PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "perms $mode ${owner:+$owner }$path"; fi
  return 0
}
ensure_dir() { # ensure_dir <chemin> <mode> [proprietaire]
  local path="$1" mode="$2" owner="${3:-}"
  prov_refuse_symlink_path "$path" || return 1
  if [[ ! -d "$path" ]]; then
    mkdir -p "$path" || { p_fail "ensure_dir: mkdir refusé: $path"; return 1; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "dir $path"
  fi
  ensure_mode "$path" "$mode" "$owner"
}
# Un fichier s'ecrit ENTIER puis bascule : personne ne lit un tampon a moitie ecrit, et un contenu
# identique ne compte pas pour un changement.
write_atomic() { # write_atomic <dest> <mode> [proprietaire]  < contenu
  local dest="$1" mode="$2" owner="${3:-}"
  local dir tmp
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
  PROV_CHANGED=$((PROV_CHANGED + 1))
  p_chg "$dest"
}

# ─── L'adresse annoncee ────────────────────────────────────────────────────────────────────────
# L'adresse que les liens et les retours OAuth doivent porter : celle du bind s'il en nomme une,
# sinon l'adresse de sortie de la machine. L'appelant qui en sait plus (l'installeur, qui connait
# WSL et son mode NAT) la POSE dans `PROV_ADVERTISE` avant d'appeler : ici on ne la recalcule pas.
lan_addr() { ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1 || true; }
advertise_addr() { # advertise_addr <bind>
  local bind="${1:-0.0.0.0}"
  if [[ -n "${PROV_ADVERTISE:-}" ]]; then
    : "${PROV_ADVERTISE_WHY:=}"
    return 0
  fi
  PROV_ADVERTISE=""; PROV_ADVERTISE_WHY=""
  case "$bind" in
    0.0.0.0|::|"*") ;;
    *) PROV_ADVERTISE="$bind"; return 0 ;;
  esac
  PROV_ADVERTISE="$(lan_addr)"
  if [[ -z "$PROV_ADVERTISE" ]]; then
    PROV_ADVERTISE="127.0.0.1"
    PROV_ADVERTISE_WHY="aucune adresse de sortie détectée — les liens ne valent que sur cette machine"
  fi
  return 0
}
