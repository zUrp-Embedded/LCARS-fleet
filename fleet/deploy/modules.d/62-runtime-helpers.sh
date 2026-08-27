#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/62-runtime-helpers.sh
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: PROTO-V2 — les auxiliaires runtime du rail POSTE : ce que le `COPY` du Dockerfile pose côté image
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
#
# ─── UN INSTALLEUR LIVRE UN SYSTÈME QUI FONCTIONNE ──────────────────────────────────────────────
#
# ⚖ USER 2026-08-21. Ce module existe parce que la moitié du produit n'était posée QUE par le
# Dockerfile. La console web, la landing, le convergeur d'humains et le convergeur de toolchain sont
# des `COPY` — donc sur une machine native ils n'existaient nulle part, et rien ne le disait.
#
# CE QUE ÇA DONNAIT, MESURÉ LE 2026-08-21 SUR UN POSTE NATIF FRAÎCHEMENT INSTALLÉ :
#   · la page LCARS s'ouvrait sur un CADRE NOIR — `ttyd` absent de la machine, aucun `console.sh`
#     pour le lancer, et le client de terminal (xterm.js) jamais récupéré ;
#   · un humain ajouté à la team `humans` de la forge n'obtenait AUCUN compte Unix — le convergeur
#     n'était pas sur le disque ;
#   · `sudo lcars-toolchain-converge`, dont `45-sudoers-toolchain` accorde l'exécution au groupe
#     `fleet`, était un « command not found » : la règle sudoers désignait un binaire absent.
#
# Aucun de ces trois-là ne se voyait dans un verdict : le provisionnement était VERT sur ses modules,
# et le produit était mort. Un module ne peut pas constater ce qu'aucun module ne pose.
#
# ─── LES DEUX RAILS POSENT LA MÊME CHOSE, PAR DEUX MÉCANISMES ───────────────────────────────────
#
# La liste ci-dessous est le miroir du bloc `COPY … /opt/lcars/` du Dockerfile, moins `entrypoint.sh`
# qui n'a de sens que dans un conteneur. `CHECK-ON: any` et `APPLY-ON` sans docker : le doctor sonde
# les deux rails, seul le rail poste a quelque chose à poser.
#
# ⚠ `ttyd` N'EST PAS DANS `10-packages`, ET C'EST DÉLIBÉRÉ. Cette liste-là est celle des paquets que
# les DEUX rails obtiennent par apt ; `ttyd` n'est pas empaqueté par Debian (l'image le récupère en
# binaire statique épinglé par sha256), il l'est par Ubuntu — mesuré le 2026-08-21 sur Launchpad :
# `ttyd 1.7.7-4build1`, `universe`, la version exacte que le Dockerfile épingle. Deux mécanismes pour
# un même outil, donc deux sites : les mélanger ferait mentir le témoin d'égalité des deux rails.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# Seams de test — l'emplacement des deux dépôts, la racine des sources, et le propriétaire à poser.
# Le dernier existe parce qu'un témoin ne peut pas `chown root` : sans lui, la POSE — le sujet même
# de ce module — ne serait épinglée par personne.
HELPERS_DIR="${LCARS_HELPERS_DIR:-/opt/lcars}"
TOOLCHAIN_BIN="${LCARS_TOOLCHAIN_CONVERGE_BIN:-/usr/local/bin/lcars-toolchain-converge}"
# Le client shell du service d'autorité, sur le PATH — et il y est pour la même raison que le
# convergeur de toolchain juste au-dessus : ses appelants vivent dans trois arbres qui ne se voient
# pas (la CLI `fleet/bin`, le skill du siège `deploy/admiral/skills`, et le release). Un nom sur le
# PATH est le seul point de rendez-vous qu'aucun des trois n'a à deviner.
AUTHORITY_ASK_BIN="${LCARS_AUTHORITY_ASK_BIN:-/usr/local/bin/lcars-authority-ask}"
HELPERS_OWNER="${LCARS_HELPERS_OWNER:-root:root}"
# ⚠ LA SOURCE EST `fleet/services/`, PAS `deploy/docker/`. Ces fichiers sont du RUNTIME — ils
# sont poses hors du checkout et tournent apres l'install, la plupart en root. Les ranger sous
# le nom de l'outil qui les transporte faisait chercher le code privilegie de cette machine
# dans un dossier appele `docker`, ou il n'y a pas de docker sur ce rail.
SRC_DIR="$(repo_root)/fleet/services"
# ⚠ LES BINAIRES DE PATH NE SONT PAS DES SERVICES, ET ILS NE VIVENT PLUS AVEC EUX. Ils portent leur
# nom DEFINITIF dans la source (`fleet/bin/lcars-*`), comme `lcars` et `fleet_v2` : plus aucun
# renommage a la pose, donc plus rien a lire entre le depot et le PATH.
BIN_SRC_DIR="$(repo_root)/fleet/bin"
# ⚠ SEAM SUR LE BINAIRE, ET IL EXISTE PARCE QU'UN TEMOIN NE PEUT PAS DESINSTALLER ttyd. Le temoin
# « le manque de ttyd se DIT » retirait sa doublure du PATH — ce qui ne prouve rien sur une machine
# ou le VRAI ttyd est installe, c'est-a-dire sur toute machine que ce module a deja convergee.
# Mesure du 2026-08-21, passe a froid : vert sur un poste de dev, ROUGE dans l'install, apres que
# `10-packages` a pose /usr/bin/ttyd trente lignes plus haut. Nommer le binaire rend la sonde
# epinglable sans toucher au systeme.
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
  # Les gestes de forge. Dans l'image, l'entrypoint les atteint par son verbe `forge-apply` ; sur un
  # poste, `48-forge-host` les appelle DIRECTEMENT, sans conteneur — le script n'a jamais eu la
  # moindre hypothèse de conteneur, son `PRIVATE_DIR` défaute même sur `/home/private`, un chemin
  # d'hôte. C'est l'appelant qui le forçait dans un `docker create`.
  forge-gestures.sh
  # L'exécuteur de catalogue : le seul process de la boîte qui tienne l'autorité de la forge. Il est
  # posé ICI et pas ailleurs parce qu'il APPELLE `forge-gestures.sh` — les deux doivent atterrir
  # ensemble, sur les deux rails, ou le service démarre et refuse chaque geste sur un fichier absent.
  catalogue-executor.py
  # Le cycle de vie d'une socket de service, ecrit UNE fois. Il est POSE et pas seulement ecrit :
  # `catalogue-executor.py` l'importe depuis SON PROPRE repertoire, donc les deux atterrissent
  # ensemble ou le service meurt sur un `ModuleNotFoundError` au demarrage.
  lcars_socket.py
  # L'unique service ROOT de la machine, et il ne detient rien. Il remplace la regle sudoers
  # `%fleet ALL=(root) NOPASSWD:` — le seul chemin `groupe -> root` qui restait. Pose ici parce
  # qu'il APPELLE `lcars-toolchain-converge`, comme l'executeur de catalogue appelle
  # `forge-gestures.sh` : les deux atterrissent ensemble, ou le service demarre et refuse chaque
  # demande sur un binaire absent.
  privileged-executor.py
  # LE SUPERVISEUR DE LA BOITE — ce que `Restart=` fait sur ce rail-ci. `entrypoint.sh` lancait
  # `setsid <cmd> &` et rien ne relancait un service mort : tini recolte les orphelins, il n'en
  # ressuscite aucun. Il est pose sur les DEUX rails alors que seul docker s'en sert : sur un poste,
  # systemd fait ce travail et ce fichier y dort. Ne le poser que d'un cote rouvrirait la divergence
  # de mecanisme que ce lot ferme — et le mur de correspondance avec l'image l'exige de toute facon.
  supervise.sh
)

# ─── LES DONNEES DU RAIL — NI EXECUTABLES, NI FORCEMENT DANS /opt/lcars ─────────────────────────
#
# ⚠ CE QUI SORT DE `/opt/lcars` ETAIT INVISIBLE AU MUR, ET UN FICHIER Y VIVAIT DEJA. Le temoin de
# correspondance avec l'image ne lit qu'un motif : `COPY fleet/services/X /opt/lcars/X`. Tout ce que
# le Dockerfile pose AILLEURS lui echappe par construction — pas par exemption, par angle mort.
#
# Mesure du 2026-08-26 : `Dockerfile` fait `COPY fleet/services/skel.bashrc /etc/skel/.bashrc`, et
# RIEN ne le posait sur le rail poste. Le convergeur cree les humains avec `useradd -m`, qui recopie
# `/etc/skel` — donc en boite un humain de fleet recoit le prompt LCARS, ses alias et
# `force_color_prompt` ; sur un poste il recoit le `.bashrc` de la distribution. Silencieux des deux
# cotes, et jamais le meme environnement selon le rail.
#
# `console.tmux.conf` etait, lui, exempte NOMMEMENT — « une config, pas un executable a deployer ».
# La phrase explique pourquoi il n'est pas dans `HELPERS` (qui pose en 0755), pas pourquoi le poste
# s'en passe : `console.sh` teste `[[ -r ]]` sur ce fichier et retombe sur le tmux par defaut, donc
# deux comportements de console selon le rail. La bonne reponse n'etait pas l'exemption, c'etait une
# SECONDE TABLE — meme regle, autre mode, autre destination.
#
# ⚠ LES DESTINATIONS SE DERIVENT, ELLES NE S'ECRIVENT PAS. Premiere version de cette table :
# `/opt/lcars/console.tmux.conf` en litteral — une SECONDE autorite sur un chemin que ce module
# tient deja dans `HELPERS_DIR`, et le jour ou la couture de test le deplace, la table pointe encore
# l'ancien. Elle l'a fait tout de suite : cinq temoins rouges sur un `mkdir refusé: /opt/lcars`.
#
# Format : <source dans fleet/services/> <destination> <mode>
SKEL_FILE="${LCARS_SKEL_FILE:-/etc/skel/.bashrc}"
DATA=(
  "console.tmux.conf $HELPERS_DIR/console.tmux.conf 0644"
  "skel.bashrc $SKEL_FILE 0644"
)

# ─── LE CLIENT DE TERMINAL : LA SEULE CHOSE ICI QU'AUCUNE DISTRIBUTION NE LIVRE ─────────────────
# Mêmes pins que le Dockerfile, calculés le 2026-08-14 sur ces URLs exactes. Le dépôt ne porte
# toujours aucun fichier JS tiers : ce qu'il porte est une référence vérifiée. Bump = changer la
# paire aux DEUX endroits, et le témoin épingle leur égalité.
XTERM_VERSION="${LCARS_XTERM_VERSION:-5.5.0}"
XTERM_FIT_VERSION="${LCARS_XTERM_FIT_VERSION:-0.10.0}"
XTERM_JS_SHA256=1f991ac3b4b283ebf96e60ae23a00a52765dd3a2e46fa6fdda9f1aab032f7495
XTERM_CSS_SHA256=ba8e6985669488981ccf40c0cefe3aba80722cb6c92de7ad628b0bd717faf2b6
XTERM_FIT_SHA256=bdaefa370b1bfc42ee88d46fe6072400902a4d4b2d45cd93438dda9b23c97089

deck_static_dir() { echo "$HELPERS_DIR/deck-static"; }

# ─── LA RÉVISION VOYAGE AVEC CE QU'ON POSE ──────────────────────────────────────────────────────
#
# `/opt/lcars/fleet` est un `cp -a`, pas un checkout : `git rev-parse` n'y répond rien. Un
# `provision` lancé depuis cette copie — c'est le cas du convergeur, dont l'unité systemd pointe
# `LCARS_PROVISION=/opt/lcars/fleet/deploy/provision` — n'aurait donc aucun moyen de nommer sa
# propre origine. Le tampon comble exactement ce trou : celui qui copie ÉCRIT la révision copiée.
#
# ⚠ LE TAMPON SE DÉRIVE DE L'EMPLACEMENT DE LA COPIE, PAS DE LA RACINE DES AUXILIAIRES. Les deux
# coïncident aujourd'hui — `repo_root()` remonte trois crans depuis `<copie>/fleet/deploy/lib`, et la
# copie est posée en `$HELPERS_DIR/fleet` — mais c'est une COÏNCIDENCE ARITHMÉTIQUE, pas une règle.
# Déplacer la copie d'un cran (`libexec/fleet`, proposition de regroupement sous préfixe du
# 2026-08-21) ferait pointer le lecteur sur `<prefix>/libexec` pendant que le tampon resterait à
# `<prefix>` : posé à côté, lu par personne, et le témoin qui épinglait le chemin LITTÉRAL serait
# resté vert.
#
# On dérive donc du même fait que le lecteur : le parent du `fleet/` embarqué.
EMBEDDED_FLEET="$HELPERS_DIR/fleet"
helpers_stamp() { echo "$(dirname "$EMBEDDED_FLEET")/${PROV_SOURCE_STAMP:-.source-revision}"; }

posed_rev() { # la révision d'où sort ce qui est actuellement posé, ou « inconnue »
  local f; f="$(helpers_stamp)"
  [[ -r "$f" ]] && head -n1 "$f" | tr -d '[:space:]' || echo inconnue
}

# <fichier> <url> <sha256> — la table, lue par le check ET par l'apply : une seule description.
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

# ── Sondes ──────────────────────────────────────────────────────────────────────────────────────

helper_current() { # <nom> — 0 si la copie posée est IDENTIQUE à la source
  cmp -s "$SRC_DIR/$1" "$HELPERS_DIR/$1"
}

sha_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

check() {
  local n f name url sha stale=0

  # ─── D'OÙ SORT CE QUI EST POSÉ, ET LA SOURCE EST-ELLE EN RETARD DESSUS ? ──────────────────────
  # C'est LA question que rien ne posait, et elle a coûté un compte utilisateur le 2026-08-21 : un
  # clone six commits en arrière a reposé l'ancienne allocation d'uid par-dessus la nouvelle, en
  # rendant vert, et le service systemd a tourné dessus jusqu'à la collision suivante.
  local src posed
  # shellcheck disable=SC2119 # argument OPTIONNEL : les args de fonction masquent ceux du script
  src="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  posed="$(posed_rev)"
  # ⚠ « ABSENT » ÉTAIT FAUX DANS LE CAS LE PLUS FRÉQUENT, ET IL ENVOYAIT CHERCHER LE MAUVAIS OBJET.
  #
  # `posed_rev` rend « inconnue » pour DEUX états distincts : le fichier n'est pas là, ou il est là
  # et il vaut littéralement `inconnue`. Le second est ce que produit toute install depuis un
  # tarball — `git archive` n'emporte pas `.git`, donc `prov_source_rev` ne trouve rien et ce module
  # estampille « inconnue ». Mesure du 2026-08-25 : `-rw-r--r-- 9 octets`, contenu `inconnue`, et le
  # message disait « absent ». L'opérateur cherche un fichier manquant, le trouve, et reste bloqué.
  #
  # La cause est fermée en amont — `pack.sh` écrit désormais `.source-revision` dans l'archive — mais
  # les deux états restent distinguables ici, parce qu'un tarball d'avant ce correctif existe encore
  # et qu'un message doit nommer ce qu'il voit, pas ce qu'il suppose.
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

  for n in "${HELPERS[@]}"; do
    if [[ ! -x "$HELPERS_DIR/$n" ]]; then
      p_drift "$HELPERS_DIR/$n absent"
      stale=1
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

  # ⚠ SON ABSENCE NE SE VOIT QUE SOUS UID HUMAIN, ET C'EST POURQUOI ELLE SE DIT ICI. Les services
  # tournent en root et lisent encore les jetons directement ; ce qui casse sans ce binaire, ce sont
  # les gestes d'OPÉRATEUR — `lcars publish run`, `lcars approve`, la boîte de réception du siège —
  # et ils ne cassent qu'au moment où quelqu'un les tape. Un check qui ne le nomme pas laisse la
  # panne se découvrir au pire moment, avec « commande introuvable » pour tout diagnostic.
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

  # ⚠ LE RETOUR EN ARRIÈRE SE DIT AVANT DE L'ÉCRIRE, PAS APRÈS. C'est le seul instant où l'opérateur
  # peut encore l'empêcher : trois secondes plus tard, l'ancien code est en place et le service qui
  # tourne dessus ne dira plus rien. On ne REFUSE pas — un retour en arrière délibéré est un geste
  # légitime — mais il ne peut plus être silencieux.
  local src posed
  # shellcheck disable=SC2119 # argument OPTIONNEL : les args de fonction masquent ceux du script
  src="${PROV_SOURCE_REV:-$(prov_source_rev)}"
  posed="$(posed_rev)"
  if prov_rev_is_behind "$src" "$posed"; then
    p_warn "RETOUR EN ARRIÈRE : $HELPERS_DIR sort de $posed, cet arbre est $src, qui en est un ANCÊTRE — ce qui suit REMPLACE du code par du code plus ancien (convergeur d'humains compris). Si ce n'est pas voulu : git pull, puis relance"
  fi

  # ttyd : APT, et rien d'autre. Ubuntu le livre en 1.7.7, la version que l'image épingle.
  if command -v "$TTYD_BIN" >/dev/null; then
    p_ok "ttyd présent ($("$TTYD_BIN" --version 2>&1 | head -1))"
  else
    apt_ensure ttyd || { p_fail "ttyd introuvable par apt — le dépôt « universe » est-il activé ? (sans lui, la console web n'a aucun serveur)"; verdict_apply; }
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

  # Le provisionnement embarqué. On RECOPIE à chaque apply : c'est la même règle que la release —
  # ce qui est posé date de l'apply, pas d'un clone qui a pu bouger ou disparaître depuis.
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
  #
  # `fetch_verify` ne télécharge JAMAIS vers la destination : un curl tronqué laisserait un bundle
  # cassé en place, et une page blanche est plus difficile à lire qu'une page noire — celle-ci au
  # moins laisse un motif dans les logs du deck.
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
