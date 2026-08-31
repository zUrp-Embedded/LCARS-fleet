#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/62-runtime-helpers.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: PROTO-V2 — les auxiliaires runtime du rail POSTE : ce que le `COPY` du Dockerfile pose côté image
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

HELPERS_DIR="${LCARS_HELPERS_DIR:-$PROV_ROOT}"
TOOLCHAIN_BIN="${LCARS_TOOLCHAIN_CONVERGE_BIN:-/usr/local/bin/lcars-toolchain-converge}"
AUTHORITY_ASK_BIN="${LCARS_AUTHORITY_ASK_BIN:-/usr/local/bin/lcars-authority-ask}"
HELPERS_OWNER="${LCARS_HELPERS_OWNER:-root:root}"
SRC_DIR="$(repo_root)/fleet/services"
BIN_SRC_DIR="$(repo_root)/fleet/bin"
TTYD_BIN="${LCARS_TTYD_BIN:-ttyd}"

owner_args() { printf '%s\n%s\n%s\n%s\n' -o "${HELPERS_OWNER%%:*}" -g "${HELPERS_OWNER##*:}"; }

# Le miroir du `COPY` de l'image. `entrypoint.sh` en est absent : il n'a pas de sens hors conteneur.
HELPERS=(
  console.sh
  console-humans.sh
  console-status.sh
  console-landing.sh
  console-deck.py
  console-pod.sh
  human-converger.sh
  forge-gestures.sh
  catalogue-executor.py
  lcars_socket.py
  privileged-executor.py
  supervise.sh
)

SKEL_FILE="${LCARS_SKEL_FILE:-/etc/skel/.bashrc}"
DATA=(
  "console.tmux.conf $HELPERS_DIR/console.tmux.conf 0644"
  "skel.bashrc $SKEL_FILE 0644"
)

XTERM_VERSION="${LCARS_XTERM_VERSION:-5.5.0}"
XTERM_FIT_VERSION="${LCARS_XTERM_FIT_VERSION:-0.10.0}"
XTERM_JS_SHA256=1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495
XTERM_CSS_SHA256=ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6
XTERM_FIT_SHA256=bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089

deck_static_dir() { echo "$HELPERS_DIR/deck-static"; }

# ⚠ LE TAMPON SE DÉRIVE DE L'EMPLACEMENT DE LA COPIE, PAS DE LA RACINE DES AUXILIAIRES. Les deux
# coïncident aujourd'hui — `repo_root()` remonte trois crans depuis `<copie>/fleet/deploy/lib`, et la
# copie est posée en `$HELPERS_DIR/fleet` — mais c'est une COÏNCIDENCE ARITHMÉTIQUE, pas une règle.
EMBEDDED_FLEET="$HELPERS_DIR/fleet"
helpers_stamp() { echo "$(dirname "$EMBEDDED_FLEET")/${PROV_SOURCE_STAMP:-.source-revision}"; }

posed_rev() { # la révision d'où sort ce qui est actuellement posé, ou « inconnue »
  local f; f="$(helpers_stamp)"
  if [[ -r "$f" ]]; then head -n1 "$f" | tr -d '[:space:]' || echo inconnue; else echo inconnue; fi
}

deck_static_table() {
  printf '%s\t%s\t%s\n' \
    xterm.js "https://cdn.jsdelivr.net/npm/@xterm/xterm@${XTERM_VERSION}/lib/xterm.js" "$XTERM_JS_SHA256" \
    xterm.css "https://cdn.jsdelivr.net/npm/@xterm/xterm@${XTERM_VERSION}/css/xterm.css" "$XTERM_CSS_SHA256" \
    addon-fit.js "https://cdn.jsdelivr.net/npm/@xterm/addon-fit@${XTERM_FIT_VERSION}/lib/addon-fit.js" "$XTERM_FIT_SHA256"
}

# LE PROVISIONNEMENT EN FORME DE REPO, comme dans l'image : `repo_root()` de la lib résout ses
# chemins inter-arbre depuis `<racine>/fleet/deploy/lib/`, donc le convergeur qui appelle
# `/opt/lcars/fleet/deploy/provision` retrouve `fleet/etc` sans rien savoir de la machine.
EMBEDDED=(deploy etc)

helper_current() { # <nom> — 0 si la copie posée est IDENTIQUE à la source
  cmp -s "$SRC_DIR/$1" "$HELPERS_DIR/$1"
}

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

check() {
  local n f name url sha stale=0

  local src posed
  # shellcheck disable=SC2119 # argument OPTIONNEL : les args de fonction masquent ceux du script
  src="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  posed="$(posed_rev)"
  if [[ "$posed" == "inconnue" ]]; then
    if [[ -r "$(helpers_stamp)" ]]; then
      p_drift "$(helpers_stamp) existe mais vaut « inconnue » — les auxiliaires ont été posés depuis un arbre SANS révision lisible (install depuis une archive : « git archive » n'emporte pas .git). Rien ne permet de comparer ce qui est posé à cette source"
    else
      p_drift "$(helpers_stamp) absent — impossible de dire de quelle révision sortent les auxiliaires posés"
    fi
  elif [[ "$posed" == "$src" ]]; then
    p_ok "auxiliaires posés depuis $posed (identique à la source)"
  else
    # ⚠ `cmd; case "$?"` EST UN PIÈGE SOUS `set -e` : une commande NUE qui rend non-zéro tue le
    # script avant le `case`. Ici les trois codes sont des RÉPONSES, pas des échecs — la troisième
    # (« je ne peux pas dire ») étant précisément celle qu'on veut pouvoir énoncer.
    local rc=0; prov_rev_is_behind "$src" "$posed" || rc=$?
    case "$rc" in
      0) p_fail "LA SOURCE EST EN RETARD : posé depuis $posed, cet arbre est $src, qui en est un ANCÊTRE. Un apply REMPLACERAIT du code par du code plus ancien, sans rien casser d'apparent. Mets ce checkout à jour (git pull) avant de converger" ;;
      1) p_drift "auxiliaires posés depuis $posed, cet arbre est $src — l'apply les mettra à jour" ;;
      *) p_warn "auxiliaires posés depuis $posed, cet arbre est $src — parenté indéterminable (pas de git, ou révision inconnue de ce clone)" ;;
    esac
  fi

  if command -v "$TTYD_BIN" >/dev/null; then
    p_ok "ttyd présent ($("$TTYD_BIN" --version 2>&1 | head -1))"
  else
    p_drift "ttyd absent — la console web n'a AUCUN serveur derrière sa socket (page noire)"
  fi

  # ⚠ « PAS EXECUTABLE » N'EST PAS « ABSENT », et confondre les deux envoie chercher un fichier qui
  # est la. L'apply pose tout en `install -m 0755` ; une IMAGE, elle, copie le mode de la source —
  # `lcars_socket.py` est 100644 dans git et arrivait donc non executable. Le module rendait
  # « absent », mesure du 2026-08-30, sur un fichier de 5130 octets parfaitement present.
  for n in "${HELPERS[@]}"; do
    if [[ ! -e "$HELPERS_DIR/$n" ]]; then
      p_drift "$HELPERS_DIR/$n absent"
      stale=1
    elif [[ ! -x "$HELPERS_DIR/$n" ]]; then
      p_drift "$HELPERS_DIR/$n présent mais PAS exécutable (mode $(stat -c '%a' "$HELPERS_DIR/$n" 2>/dev/null || echo '?')) — l'apply pose 0755"
      stale=1
    elif [[ ! -r "$SRC_DIR/$n" ]]; then
      # ⚠ « DIVERGE » EST UNE CONCLUSION, ET ELLE EXIGE DEUX COTES. `helper_current` est un `cmp -s
      # src dst` : source absente, `cmp` echoue, et l'appelant lisait cet echec comme une
      # divergence. Mesure du 2026-09-01 sur le banc 2004 : ONZE drifts « diverge de la source »
      # alors que `/opt/lcars/fleet/services` n'existait pas du tout. Onze verdicts faux par
      # passage, dont aucun ne portait sur l'auxiliaire qu'il nommait.
      p_warn "$HELPERS_DIR/$n : rien n'est conclu — la SOURCE est absente ou illisible ici ($SRC_DIR/$n). « diverge » demande deux côtés"
    elif ! helper_current "$n"; then
      p_drift "$HELPERS_DIR/$n diverge de la source ($SRC_DIR/$n)"
      stale=1
    fi
  done
  [[ "$stale" -eq 0 ]] && p_ok "${#HELPERS[@]} auxiliaires à jour dans $HELPERS_DIR"

  while IFS=$'\t' read -r name url sha; do
    f="$(deck_static_dir)/$name"
    if [[ ! -s "$f" ]]; then
      p_drift "client de terminal absent ($f) — la console s'ouvre sur un cadre noir, et rien à l'écran ne le dit"
    elif [[ "$(sha_of "$f")" != "$sha" ]]; then
      p_drift "$f ne correspond pas à son pin sha256"
    fi
  done < <(deck_static_table)

  if [[ -x "$TOOLCHAIN_BIN" ]]; then
    p_ok "convergeur de toolchain posé ($TOOLCHAIN_BIN)"
  else
    p_drift "$TOOLCHAIN_BIN absent — la règle sudoers de 45-sudoers-toolchain désigne un binaire qui n'existe pas"
  fi

  if [[ -x "$AUTHORITY_ASK_BIN" ]]; then
    p_ok "client d'autorité posé ($AUTHORITY_ASK_BIN)"
  else
    p_drift "$AUTHORITY_ASK_BIN absent — « lcars publish run », « lcars approve » et le skill system-issues n'ont aucun moyen d'obtenir un jeton de forge"
  fi

  for n in "${EMBEDDED[@]}"; do
    [[ -x "$EMBEDDED_FLEET/deploy/provision" ]] && break
    p_drift "provisionnement embarqué absent ($EMBEDDED_FLEET/$n) — le convergeur ne pourra pas converger un humain"
    break
  done
  [[ -x "$EMBEDDED_FLEET/deploy/provision" ]] && p_ok "provisionnement embarqué posé ($EMBEDDED_FLEET/deploy/provision)"

  verdict_check
}

apply() {
  local n name url sha f

  local src posed
  # shellcheck disable=SC2119 # argument OPTIONNEL : les args de fonction masquent ceux du script
  src="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  posed="$(posed_rev)"
  if prov_rev_is_behind "$src" "$posed"; then
    p_warn "RETOUR EN ARRIÈRE : $HELPERS_DIR sort de $posed, cet arbre est $src, qui en est un ANCÊTRE — ce qui suit REMPLACE du code par du code plus ancien (convergeur d'humains compris). Si ce n'est pas voulu : git pull, puis relance"
  fi

  if command -v "$TTYD_BIN" >/dev/null; then
    p_ok "ttyd présent ($("$TTYD_BIN" --version 2>&1 | head -1))"
  else
    p_fail "ttyd absent — la console web n'aura AUCUN serveur derrière sa socket (page noire). Il est dans \`PACKAGES\` (10-packages) : ce module-là a-t-il convergé, et le dépôt « universe » est-il activé ?"
    verdict_apply
  fi

  local -a own; mapfile -t own < <(owner_args)

  ensure_dir "$HELPERS_DIR" 0755 "$HELPERS_OWNER" || verdict_apply
  for n in "${HELPERS[@]}"; do
    [[ -f "$SRC_DIR/$n" ]] || { p_fail "source absente: $SRC_DIR/$n (arbre incomplet)"; verdict_apply; }
    helper_current "$n" && continue
    install -m 0755 "${own[@]}" "$SRC_DIR/$n" "$HELPERS_DIR/$n" \
      || { p_fail "pose ratée: $HELPERS_DIR/$n"; verdict_apply; }
    PROV_CHANGED=$((PROV_CHANGED + 1)); p_chg "$HELPERS_DIR/$n"
  done

  # LES DONNEES, apres les executables : meme source, autre mode, autre destination. `write_atomic`
  # et pas `install` — il compare le contenu avant d'ecrire, donc une repasse ne compte pas de
  # mutation, et le fichier n'est jamais a moitie ecrit sous un lecteur.
  local spec d_src d_dst d_mode
  for spec in "${DATA[@]}"; do
    read -r d_src d_dst d_mode <<<"$spec"
    [[ -f "$SRC_DIR/$d_src" ]] || { p_fail "source absente: $SRC_DIR/$d_src (arbre incomplet)"; verdict_apply; }
    ensure_dir "$(dirname "$d_dst")" 0755 || verdict_apply
    write_atomic "$d_dst" "$d_mode" < "$SRC_DIR/$d_src" \
      || { p_fail "pose ratée: $d_dst"; verdict_apply; }
  done

  ensure_dir "$(dirname "$TOOLCHAIN_BIN")" 0755 "$HELPERS_OWNER" || verdict_apply
  install -m 0755 "${own[@]}" "$BIN_SRC_DIR/lcars-toolchain-converge" "$TOOLCHAIN_BIN" \
    || { p_fail "pose ratée: $TOOLCHAIN_BIN"; verdict_apply; }

  # 0755 : LISIBLE ET EXÉCUTABLE PAR TOUS, ET CE N'EST PAS UN RELÂCHEMENT. Ce script ne détient
  # rien — il DEMANDE, et c'est la socket qui décide, sur un uid que le noyau atteste. Le fermer à
  # un groupe rejouerait exactement le défaut que ce chantier retire : une autorisation lue dans
  # `/etc/group` au lieu d'être demandée à la forge.
  ensure_dir "$(dirname "$AUTHORITY_ASK_BIN")" 0755 "$HELPERS_OWNER" || verdict_apply
  install -m 0755 "${own[@]}" "$BIN_SRC_DIR/lcars-authority-ask" "$AUTHORITY_ASK_BIN" \
    || { p_fail "pose ratée: $AUTHORITY_ASK_BIN"; verdict_apply; }

  ensure_dir "$EMBEDDED_FLEET" 0755 "$HELPERS_OWNER" || verdict_apply
  for n in "${EMBEDDED[@]}"; do
    [[ -d "$(repo_root)/fleet/$n" ]] || { p_fail "source absente: $(repo_root)/fleet/$n"; verdict_apply; }
    rm -rf "${EMBEDDED_FLEET:?}/$n.new"
    cp -a "$(repo_root)/fleet/$n" "$EMBEDDED_FLEET/$n.new" \
      || { p_fail "copie ratée: fleet/$n"; verdict_apply; }
    rm -rf "${EMBEDDED_FLEET:?}/$n"
    mv "$EMBEDDED_FLEET/$n.new" "$EMBEDDED_FLEET/$n" \
      || { p_fail "bascule ratée: fleet/$n"; verdict_apply; }
  done
  p_chg "provisionnement embarqué ($HELPERS_DIR/fleet/{${EMBEDDED[*]}})"

  # LE TAMPON S'ÉCRIT APRÈS LA POSE, JAMAIS AVANT : il atteste ce qui EST là. Posé d'avance, il
  # certifierait une copie qu'un échec deux lignes plus bas aurait laissée à moitié faite.
  write_atomic "$(helpers_stamp)" 0644 "$HELPERS_OWNER" <<<"$src" \
    || { p_fail "révision de source non tamponnée ($(helpers_stamp)) — la prochaine passe ne saura pas d'où sort ce qui est ici"; verdict_apply; }

  # ⚠ LE RÉSEAU EN DERNIER, ET C'EST UN ORDRE, PAS UN RANGEMENT. Tout ce qui précède se pose depuis
  # l'arbre local et ne peut échouer que sur un disque. Le client de terminal, lui, dépend d'un CDN :
  # le mettre plus haut ferait qu'une coupure réseau priverait la machine du convergeur et du
  # binaire de toolchain, qui n'ont rien demandé à personne. Ici, une coupure coûte exactement ce
  # qu'elle doit coûter — la console s'ouvre sur un cadre noir, et le check le NOMME.
  ensure_dir "$(deck_static_dir)" 0755 "$HELPERS_OWNER" || verdict_apply
  while IFS=$'\t' read -r name url sha; do
    f="$(deck_static_dir)/$name"
    [[ -s "$f" && "$(sha_of "$f")" == "$sha" ]] && continue
    fetch_verify "$url" "$sha" "$f" 0644 || verdict_apply
  done < <(deck_static_table)

  verdict_apply
}

case "${1:?usage: 62-runtime-helpers.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
