#!/usr/bin/env bash
# SOURCE: runtime/services/container/init.sh
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: actif — l'INIT DE L'INSTANCE du conteneur, cote produit : le siege, les zones, le layout du volume
#
# Ce qu'une instance neuve doit avoir sur son volume, et rien de plus, en un geste idempotent. Pas de
# `mix`, pas de table de l'installeur, pas de `deploy/`.
#
# CE QUE CE GESTE POSE (et d'ou chaque ligne vient) :
#   - le SIEGE : le sysadmin du conteneur — resolu (table `forge-uid.map`, sinon le #1 de la forge
#     par le jeton master, sinon la semence `LCARS_ADMIRAL`), cree a l'uid `LCARS_UID`, sudoer,
#     `authorized_keys` s'il y en a une.
#   - `/etc/lcars/seat.uid` : ce que GUARD B lit pour refuser une fleet sous le siege.
#   - les zones de FACE : `/home/projects`, `.ops`, `.workshop` (2775 root:fleet).
#   - la SOURCE et le corpus ops, si l'appelant les nomme (`LCARS_SOURCE_REMOTE`).
#   - les cles d'hote SSH, PERSISTANTES dans le volume `/home`.
#   - `forge.url` du repertoire des jetons, depuis `FORGE_BASE_URL` : l'adresse qu'une session ssh
#     du siege lit, puisqu'elle n'herite pas de l'environnement du service.
#   - le LAYOUT du volume : ce que `25-directories` pose dans l'image et sur un poste, repose ici
#     sur les volumes du conteneur — les repertoires de `/opt/lcars/var`, du magasin, de `/run/lcars`, la
#     skill du siege, `pilot.assignee`. Les memes chemins, modes et proprietaires que la table de
#     l'installeur declare (`deploy/system.manifest`, substrat `any`) — par CONVENTION, pas par
#     lecture : c'est le contrat entre les deux rails, et `verify` le mesure au build.
#
# CE QU'IL NE FAIT PAS : les gestes de FORGE (jetons, cache des catalogues, depot du systeme, client
# OAuth2) — ce sont `forge.d/` et le minteur, joues par le boot APRES ce geste ; les humains — c'est
# le convergeur ; les services — c'est le boot.
#
# VERDICT : le protocole des modules. `apply` rend 0 converge, 2 drift residuel, 1 echec ; `secrets`
# et `store` rejouent une seule de ses parts (l'import des secrets, le magasin) avec le meme verdict.
# `seat` seul resout et enregistre le siege, ecrit `/run/lcars-seat.login`, et rend 4 quand le conteneur
# n'a rien pour le determiner — l'etat « en attente de configuration ».

set -euo pipefail
: "${LCARS_MODULE_TAG:=container-init}"
# L'adresse de la forge TELLE QUE L'ENVIRONNEMENT LA DONNE, lue AVANT le protocole : celui-ci la
# complete depuis `forge.url`, le fichier que `forge_url_file` pose.
FORGE_URL_ENV="${FORGE_BASE_URL:-}"
# shellcheck source=../lib/module-protocol.sh
. "${LCARS_MODULE_PROTOCOL:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/module-protocol.sh}"

LCARS_UID="${LCARS_UID:-1000}"
SEAT_UID_FILE="${LCARS_SEAT_UID_FILE:-/etc/lcars/seat.uid}"
SEAT_LOGIN_FILE="${LCARS_SEAT_LOGIN_FILE:-/run/lcars-seat.login}"
UID_MAP_FILE="${LCARS_UID_MAP_FILE:-$LCARS_PRIVATE_DIR/forge-uid.map}"
HOST_KEYS_DIR="${LCARS_HOST_KEYS_DIR:-/home/.lcars-container/ssh}"
STORE_ROOT="${LCARS_STORE_ROOT:-}"
SKILL_SRC="${LCARS_ADMIRAL_SKILLS_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/admiral/skills}"

# ─── LE SIEGE ──────────────────────────────────────────────────────────────────────────────────
seat_from_map() { # le login du siege enregistre, ou vide
  [[ -r "$UID_MAP_FILE" ]] || return 0
  awk -F'\t' '$1 == 1 { print $3; exit }' "$UID_MAP_FILE" 2>/dev/null
}
seat_from_forge() { # le #1 de la forge, par le jeton master, ou vide
  [[ -s "$LCARS_MASTER_TOKEN_FILE" && -n "${FORGE_BASE_URL:-}" ]] || return 0
  forge_curl "$LCARS_MASTER_TOKEN_FILE" -sS -m 15 "${FORGE_BASE_URL%/}/api/v1/admin/users?limit=50" 2>/dev/null \
    | jq -r 'map(select(.id == 1)) | .[0].login // empty' 2>/dev/null || true
}
seat_record() { # seat_record <login> <uid>
  [[ -n "$(seat_from_map)" ]] && return 0
  mkdir -p "$(dirname "$UID_MAP_FILE")" 2>/dev/null || true
  printf '1\t%s\t%s\n' "$2" "$1" >> "$UID_MAP_FILE" 2>/dev/null || return 1
  chmod 0640 "$UID_MAP_FILE" 2>/dev/null || true
}
# Trois sources, dans l'ordre de leur durabilite : la table (ce que ce conteneur a deja enregistre),
# la forge (le #1, celui qui l'a installee), la semence de l'appelant (`LCARS_ADMIRAL`, le cas
# from-scratch). Une semence qui CONTREDIT une source durable est une divergence, pas un choix :
# le home du siege vit sous UN nom, et on ne le renomme pas en silence.
seat_resolve() { # -> SEAT_LOGIN pose ; rc 0 resolu · 3 indeterminable · 1 divergence
  local durable source candidat="${LCARS_ADMIRAL:-}"
  durable="$(seat_from_map)"; source=table
  if [[ -z "$durable" ]]; then durable="$(seat_from_forge)"; source=forge; fi
  if [[ -n "$durable" && -n "$candidat" && "$durable" != "$candidat" ]]; then
    p_fail "siege : DIVERGENCE — la semence dit « $candidat », $source dit « $durable »"
    return 1
  fi
  if [[ -n "$durable" ]]; then
    SEAT_LOGIN="$durable"
    p_ok "siege : « $SEAT_LOGIN » ($source)"
  elif [[ -n "$candidat" ]]; then
    SEAT_LOGIN="$candidat"
    p_ok "siege : « $SEAT_LOGIN » seme par l'appelant (LCARS_ADMIRAL) — cas from-scratch"
  else
    local pourquoi="jeton master illisible : $LCARS_MASTER_TOKEN_FILE"
    [[ -s "$LCARS_MASTER_TOKEN_FILE" ]] && pourquoi="forge muette (${FORGE_BASE_URL:-FORGE_BASE_URL absente})"
    p_warn "siege : IMPOSSIBLE a determiner — ni semence (LCARS_ADMIRAL), ni ligne forge_id=1 dans $UID_MAP_FILE, ni #1 lisible ($pourquoi)"
    return 3
  fi
  seat_record "$SEAT_LOGIN" "$LCARS_UID" || p_warn "siege : nom NON enregistre dans $UID_MAP_FILE — le boot suivant le re-derivera"
  # Le nom du siege est lu par le boot juste apres : un echec d'ecriture ici se COMPTE, il ne se
  # laisse pas rattraper trois etapes plus loin par un « incoherent » qui ne dit pas d'ou il vient.
  if mkdir -p "$(dirname "$SEAT_LOGIN_FILE")" 2>/dev/null \
     && printf '%s\n' "$SEAT_LOGIN" > "$SEAT_LOGIN_FILE" && chmod 0644 "$SEAT_LOGIN_FILE"; then
    return 0
  fi
  p_fail "$SEAT_LOGIN_FILE NON pose — le boot ne saura pas sous quel nom jouer les gestes de forge"
  return 0
}
seat_uid_file() {
  if mkdir -p "$(dirname "$SEAT_UID_FILE")" && printf '%s\n' "$LCARS_UID" > "$SEAT_UID_FILE"; then
    chmod 0644 "$SEAT_UID_FILE" 2>/dev/null || true
    chown root:root "$SEAT_UID_FILE" 2>/dev/null || true   # hors root (un temoin), le fichier suffit
  else
    p_fail "$SEAT_UID_FILE NON pose — GUARD B refusera tout « fleet start »"
  fi
}
seat_create() {
  if ! getent passwd "$SEAT_LOGIN" >/dev/null; then
    useradd -m -u "$LCARS_UID" -s /bin/bash "$SEAT_LOGIN" || { p_fail "siege : useradd $SEAT_LOGIN (uid $LCARS_UID) refuse"; return 1; }
    LCARS_CHANGED=$((LCARS_CHANGED + 1)); p_chg "sysadmin $SEAT_LOGIN cree (uid $LCARS_UID)"
  fi
  if getent group sudo >/dev/null 2>&1 && [[ " $(id -nG "$SEAT_LOGIN" 2>/dev/null) " != *" sudo "* ]]; then
    usermod -aG sudo "$SEAT_LOGIN" && p_chg "$SEAT_LOGIN ∈ sudo" || p_warn "« $SEAT_LOGIN » n'a PAS ete ajoute au groupe sudo — il n'aura pas d'elevation"
  fi
  if [[ " $(id -nG "$SEAT_LOGIN" 2>/dev/null) " != *" $LCARS_FLEET_GROUP "* ]]; then
    usermod -aG "$LCARS_FLEET_GROUP" "$SEAT_LOGIN" && p_chg "$SEAT_LOGIN ∈ $LCARS_FLEET_GROUP" || p_fail "$SEAT_LOGIN ∉ $LCARS_FLEET_GROUP"
  fi
  local home; home="$(getent passwd "$SEAT_LOGIN" | cut -d: -f6)"
  if [[ -n "${LCARS_SSH_AUTHORIZED_KEYS:-}" ]]; then
    install -d -m 0700 -o "$SEAT_LOGIN" -g "$SEAT_LOGIN" "$home/.ssh"
    local tmp; tmp="$(mktemp "$home/.ssh/.authk.XXXXXX")"
    printf '%s\n' "$LCARS_SSH_AUTHORIZED_KEYS" > "$tmp"
    chmod 0600 "$tmp" && chown "$SEAT_LOGIN:$SEAT_LOGIN" "$tmp"
    if [[ -f "$home/.ssh/authorized_keys" ]] && cmp -s "$tmp" "$home/.ssh/authorized_keys"; then
      rm -f "$tmp"; p_ok "authorized_keys de $SEAT_LOGIN inchangee"
    else
      mv -f "$tmp" "$home/.ssh/authorized_keys"; p_chg "authorized_keys posee pour $SEAT_LOGIN"
    fi
  else
    p_ok "pas de LCARS_SSH_AUTHORIZED_KEYS — acces par « docker exec -it -u $SEAT_LOGIN <ctr> bash » seulement"
  fi
}

# ─── LES ZONES DE FACE, LA SOURCE, LES CLES D'HOTE ─────────────────────────────────────────────
# ⚠ UNE SEULE LIGNE, ET C'EST UNE ANCRE : le contrat `layout.face_roots_provisioned` la lit telle
# quelle (`install -d -m 2775 -g fleet <zones>`) et la compare aux faces que `Fleet.Layout` declare.
# Une face declaree sans zone sur la machine tue le premier onboard qui en a besoin.
faces() {
  install -d -m 2775 -g fleet /home/projects /home/projects.ops /home/projects.workshop \
    && p_ok "zones de face : /home/projects /home/projects.ops /home/projects.workshop (2775 root:fleet)" \
    || p_fail "zones de face NON posees"
}
source_trees() {
  local src="${LCARS_SOURCE_DIR:-/home/projects/LCARS}" remote="${LCARS_SOURCE_REMOTE:-}" ref="${LCARS_SOURCE_REF:-}"
  if [[ ! -d "$src/.git" && -n "$remote" ]]; then
    local -a args=(--depth 1); [[ -n "$ref" ]] && args+=(--branch "$ref")
    rm -rf "${src}.part"
    if git clone "${args[@]}" "$remote" "${src}.part" 2>&1 | sed 's/^/[git] /' && mv "${src}.part" "$src"; then
      chown -R "$SEAT_LOGIN:$LCARS_FLEET_GROUP" "$src"; p_chg "source clonee : $remote${ref:+ ($ref)} → $src"
    else
      rm -rf "${src}.part"; p_drift "CLONAGE ECHOUE ($remote) — le conteneur demarre sans source (la fleet ne pourra pas se maintenir)"
    fi
  fi
  local work; work="/home/projects.ops/$(basename "$src")"
  if [[ ! -d "$work/.git" && -n "$remote" ]]; then
    if git ls-remote --exit-code --heads "$remote" ops >/dev/null 2>&1; then
      rm -rf "${work}.part"
      if git clone --depth 1 --branch ops "$remote" "${work}.part" 2>&1 | sed 's/^/[git] /' && mv "${work}.part" "$work"; then
        chown -R "$SEAT_LOGIN:$LCARS_FLEET_GROUP" "$work"; p_chg "corpus ops pose → $work"
      else
        rm -rf "${work}.part"; p_warn "CLONAGE ops ECHOUE — dual-dir absent (adoptable plus tard, rien de fatal)"
      fi
    else
      p_ok "pas de branche ops sur le remote — dual-dir non pose (le corpus arrive par l'adopt)"
    fi
  fi
  if [[ -d "$src/.git" ]]; then
    git config --system --replace-all safe.directory "$src" 2>/dev/null || true
    local src_rev img_rev; src_rev="$(git -C "$src" rev-parse --short=8 HEAD 2>/dev/null || echo '?')"
    img_rev="${LCARS_IMAGE_REVISION:-unknown}"
    if [[ "$img_rev" == "unknown" ]]; then p_ok "source LCARS : $src ($src_rev) — revision de l'image INCONNUE, ecart inverifiable"
    elif [[ "$src_rev" != "$img_rev" ]]; then p_ok "source LCARS : $src ($src_rev) — l'image tourne sur $img_rev (lire la source ne renseigne pas sur le binaire)"
    else p_ok "source LCARS : $src — image et source sur la meme revision ($img_rev)"; fi
  else
    p_ok "PAS de source LCARS sous $src — la fleet ne peut pas se maintenir elle-meme (LCARS_SOURCE_REMOTE=<url> au demarrage, ou « deploy/container source-push »)"
  fi
}
host_keys() {
  install -d -m 0700 "$HOST_KEYS_DIR"
  if ls "$HOST_KEYS_DIR"/ssh_host_*_key >/dev/null 2>&1; then
    cp "$HOST_KEYS_DIR"/ssh_host_* /etc/ssh/ && chmod 0600 /etc/ssh/ssh_host_*_key
    p_ok "cles d'hote SSH restaurees depuis le volume"
  else
    ssh-keygen -A >/dev/null
    cp /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub "$HOST_KEYS_DIR/" && chmod 0600 "$HOST_KEYS_DIR"/ssh_host_*_key
    LCARS_CHANGED=$((LCARS_CHANGED + 1)); p_chg "cles d'hote SSH generees → $HOST_KEYS_DIR (persistantes)"
  fi
}

# ─── LE LAYOUT DU VOLUME ───────────────────────────────────────────────────────────────────────
# Les memes chemins, modes et proprietaires que `deploy/system.manifest` declare en substrat `any`
# ou `docker` — c'est le contrat entre les deux rails ; `verify` le mesure au build de l'image.
# UNE TABLE, ET UN SEUL `|| true`. Le protocole COMPTE les echecs (`p_fail`), mais ce module tourne
# sous `set -e` : sans `|| true`, errexit emporte le module au premier dossier refuse, et c'est lui
# qui decide a la place du compteur. La regle etait recopiee a chaque ligne — treize fois, et la
# quatorzieme oubliee ne se serait vue qu'en production.
layout_table() { # chemin mode proprietaire — les memes que deploy/system.manifest declare
  printf '%s\n' \
    "/opt/lcars/var 0755 root:root" \
    "$LCARS_PRIVATE_DIR 0710 $LCARS_AUTHORITY_USER:$LCARS_FLEET_GROUP" \
    "$LCARS_CATALOGUES_DIR 0750 $LCARS_AUTHORITY_USER:$LCARS_FLEET_GROUP" \
    "${LCARS_CATALOGUES_WORK:-/opt/lcars/var/tofu} 0700 $LCARS_AUTHORITY_USER:$LCARS_AUTHORITY_USER" \
    "/var/lib/lcars 0755 root:root" \
    "/var/tmp/lcars 0755 root:root" \
    "/var/tmp/lcars/toolchain-work 0700 root:root" \
    "/etc/lcars 0755 root:root" \
    "/run/lcars 0755 root:root" \
    "/run/lcars/toolchain 2775 root:$LCARS_FLEET_GROUP" \
    "/run/lcars/authority 0750 $LCARS_AUTHORITY_USER:$LCARS_FLEET_GROUP" \
    "/run/lcars/privileged 0750 root:$LCARS_FLEET_GROUP" \
    "/run/lock/lcars 0700 root:root"
}
layout() {
  local path mode owner
  while read -r path mode owner; do
    ensure_dir "$path" "$mode" "$owner" || true   # p_fail a deja compte : errexit ne decide de rien
  done < <(layout_table)
  store
}
# ─── LE MAGASIN ────────────────────────────────────────────────────────────────────────────────
# Les quatre arbres sont des VOLUMES que l'hote monte sous `LCARS_STORE_ROOT` (`deploy/lib/store.sh`,
# `LCARS_STORE_TREES`, la source des volumes externes du compose). Un arbre absent est un volume
# NON MONTE : il se dit (drift), il ne se fabrique pas — un repertoire du conteneur a sa place se
# prendrait pour un volume, et l'etat partirait avec l'instance. Ce qui se pose ici est le mode et
# le proprietaire d'un point de montage PRESENT. Relecture hostile 2026-09-04 (S3) : le bloc faisait
# `ensure_dir` (fabriquait l'arbre) et disait `p_warn` sans STORE_ROOT (aucun verdict).
store_tree() { # store_tree <nom> <mode> <proprietaire>
  local d="$STORE_ROOT/$1"
  [[ -d "$d" ]] || { p_drift "magasin : arbre « $1 » absent ($d) — volume non monte ?"; return 0; }
  # un echec de pose est COMPTE par ensure_mode (p_fail) : on continue vers l'arbre suivant, le
  # verdict final le porte — cf. le temoin « un arbre remplace par un lien » d'init_layout.bats
  ensure_mode "$d" "$2" "$3" || return 0
}
store() {
  if [[ -z "$STORE_ROOT" ]]; then
    p_drift "LCARS_STORE_ROOT absent — le compose ne l'a pas pose, le magasin n'est pas converge"
    return 0
  fi
  [[ -d "$STORE_ROOT" ]] || { p_drift "magasin $STORE_ROOT absent — volumes non montes ?"; return 0; }
  store_tree cache      2775 "root:$LCARS_FLEET_GROUP"
  store_tree toolchains 0755 root:root
  store_tree sysroots   0755 root:root
  store_tree state      2775 "root:$LCARS_FLEET_GROUP"
}
# ─── L'ADRESSE DE LA FORGE, LISIBLE PAR LE SIEGE ───────────────────────────────────────────────
# Une session ouverte par ssh n'herite pas de l'environnement du service : sshd ne transmet pas
# `FORGE_BASE_URL`. Le skill du siege (`system-issues`) lit alors `forge.url` du repertoire des
# jetons, le fichier que l'installeur pose sur un poste : 0644, dans un dossier 0710 que le groupe
# fleet traverse, et le siege est dans fleet (`seat_create`). L'init le pose ici depuis
# l'environnement. Sans adresse, il le retire : le protocole des gestes le lirait sinon comme
# l'adresse courante, et une forge retiree de la configuration resterait visee.
forge_url_file() {
  local f="$LCARS_PRIVATE_DIR/forge.url"
  if [[ -n "$FORGE_URL_ENV" ]]; then
    write_atomic "$f" 0644 "root:$LCARS_FLEET_GROUP" <<<"$FORGE_URL_ENV" || true   # un echec est deja compte
  elif [[ -e "$f" || -L "$f" ]]; then
    if rm -f -- "$f"; then
      p_chg "$f retiré — FORGE_BASE_URL n'est plus posé, aucune adresse de forge n'est gardée"
    else
      p_fail "$f NON retiré — les gestes de forge viseraient encore l'adresse qu'il porte"
    fi
  fi
  return 0
}

# `pilot.assignee` : a qui le pilote assigne ce que personne ne prend.
seat_extras() {
  local home; home="$(getent passwd "$SEAT_LOGIN" | cut -d: -f6)"
  if [[ -d "$SKILL_SRC/system-issues" && -n "$home" && -d "$home" ]]; then
    local dst="$home/.claude/skills/system-issues"
    if ensure_dir "$dst" 0755 "$SEAT_LOGIN:"; then
      write_atomic "$dst/SKILL.md" 0644 "$SEAT_LOGIN:" < "$SKILL_SRC/system-issues/SKILL.md" || p_fail "skill system-issues: SKILL.md"
      write_atomic "$dst/list.sh"  0755 "$SEAT_LOGIN:" < "$SKILL_SRC/system-issues/list.sh"  || p_fail "skill system-issues: list.sh"
      chown -h "$(prov_owner "$SEAT_LOGIN:")" "$home/.claude" "$home/.claude/skills" 2>/dev/null || true
    fi
  else
    p_drift "skill system-issues : source absente ($SKILL_SRC) ou home du siege introuvable"
  fi
  if [[ -n "$STORE_ROOT" && -d "$STORE_ROOT/state" ]]; then
    write_atomic "$STORE_ROOT/state/pilot.assignee" 0644 <<<"$SEAT_LOGIN" || p_fail "projection du siege : ecriture impossible"
  fi
}

cmd_seat() {
  local rc=0; seat_resolve || rc=$?
  # 3 appartient a la garde du protocole (mort avant verdict) : l'attente de configuration, qui est
  # un etat de ce module, sort en 4 — le meme code que l'apply rend pour le meme etat.
  LCARS_VERDICT_RENDERED=1
  [[ "$rc" -ne 3 ]] || exit 4
  [[ "$rc" -eq 0 ]] || exit "$rc"
  seat_uid_file
  # ET C'EST LE COMPTEUR QUI CONCLUT : un siege resolu dont le NOM ou l'UID n'a pas pu etre publie
  # sortait en 0, et le boot enchainait sur des fichiers qui n'existent pas.
  verdict_apply
}
# ⚖ user 2026-09-04 (Q1) : « container config » pose les secrets COTE HOTE ; le compose les monte sous
# /run/secrets ; l'instance les IMPORTE dans son repertoire prive au boot — une fois, et a nouveau
# seulement s'ils changent (rotation). Le siege se derive ensuite du jeton master, donc l'import
# precede tout. Un secret absent du montage n'est pas une faute : la voie d'avant (le geste
# `config-token` dans le conteneur) reste jouable, et le drift se dit plus loin (tokens, seat).
# Le montage compose est en LECTURE SEULE (chmod y echoue) et arrive avec l'uid de l'hote — souvent
# celui du siege. Une fois importe, on le DEMONTE (le conteneur a SYS_ADMIN pour bwrap) : il ne reste
# qu'un fichier vide ; hors conteneur (les temoins), on le ferme par le mode.
close_secret_mount() { umount "$1" 2>/dev/null || chmod 0000 "$1" 2>/dev/null || true; }

secrets_import() {
  local dir="${LCARS_SECRETS_DIR:-/run/secrets}" pair src dst name
  for pair in "forge_master_token:$LCARS_MASTER_TOKEN_FILE" "forge_seed_password:$LCARS_FORGE_SEED_FILE"; do
    name="${pair%%:*}"; src="$dir/$name"; dst="${pair#*:}"
    [[ -e "$src" ]] || continue
    # Le montage arrive avec l'uid et le mode de l'HOTE (l'operateur, uid 1000 = souvent le siege) :
    # une fois importe dans le prive (0600 autorite), il se FERME (0000) — root le relit au boot
    # suivant, le siege ne le lit plus (relecture hostile du 2026-09-04 : LISIBLE sous le siege).
    if [[ ! -r "$src" ]]; then p_ok "secret $name : montage ferme, deja importe"; continue; fi
    if [[ ! -s "$src" ]]; then p_ok "secret $name : montage vide (retire a un boot precedent, ou aucun secret pose)"; continue; fi
    if [[ -s "$dst" ]] && cmp -s "$src" "$dst"; then
      close_secret_mount "$src"
      p_ok "secret $name : deja en place ($dst) — montage retire"; continue
    fi
    ensure_dir "$LCARS_PRIVATE_DIR" 0710 "$LCARS_AUTHORITY_USER:$LCARS_FLEET_GROUP" || true
    if write_atomic "$dst" 0600 "$LCARS_AUTHORITY_USER:$LCARS_AUTHORITY_USER" < "$src"; then
      close_secret_mount "$src"
      p_chg "secret $name importe du compose → $dst ($LCARS_AUTHORITY_USER seul) — montage retire"
    else
      p_fail "secret $name : import impossible → $dst"
    fi
  done
}

cmd_apply() {
  secrets_import
  local rc=0; seat_resolve || rc=$?
  case "$rc" in
    0) : ;;
    # L'ATTENTE DE CONFIGURATION EST UN ETAT DE CE MODULE, PAS UN VERDICT DU PROTOCOLE, et elle a
    # son code a elle : 3 appartient a la garde (mort avant verdict), et les confondre ferait dormir
    # le conteneur sur un init qui a plante. Le verdict se marque : la garde n'a rien a rattraper.
    3) LCARS_VERDICT_RENDERED=1; exit 4 ;;
    *) verdict_apply ;;
  esac
  seat_uid_file
  seat_create || verdict_apply
  faces
  source_trees
  host_keys
  layout
  forge_url_file
  seat_extras
  verdict_apply
}

case "${1:?usage: init.sh <seat|secrets|store|apply>}" in
  seat)    cmd_seat ;;
  secrets) secrets_import; verdict_apply ;;
  store)   store; verdict_apply ;;
  apply)   cmd_apply ;;
  *) p_die "mode inconnu: $1 (seat|secrets|store|apply)" ;;
esac
