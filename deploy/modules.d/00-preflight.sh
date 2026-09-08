#!/usr/bin/env bash
# SOURCE: deploy/modules.d/00-preflight.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — préflight fail-fast des DEUX rails : plancher OS/arch/RAM/disque, substrat, docker, forge
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# ─── UNE SEULE VOIX, DEUX LECTURES ──────────────────────────────────────────────────────────────
#
# Ce module était le préflight du rail POSTE : il ne mesurait docker que sous WSL, et tout le reste
# vivait en double dans `install.sh`. Deux mesures du même fait dérivent — c'est la règle que le
# canon de la porte pose en premier (« le préflight dupliqué : une seule mesure »).
#
# Il mesure donc pour les DEUX rails, et rend ses résultats deux fois :
#   · en lignes `OK/DRIFT/WARN/FAIL` pour un humain, comme tout module ;
#   · en faits `nom=valeur` (`p_fact`) pour un appelant qui doit DÉCIDER — la porte, qui restreint
#     son menu selon ce que la machine permet.
#
# ⚠ MESURER N'EST PAS REFUSER, et c'est ce qui rend les deux lectures compatibles. Un fait défavorable
# ne devient un refus que là où il en était déjà un : le rail conteneur a besoin de savoir que docker
# manque, il n'a pas besoin qu'on abatte le provisionnement pour autant. Les verdicts de ce module
# n'ont pas bougé d'un cran ; ce qui est neuf, ce sont les faits POSÉS à côté.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

# ⚠ CHAQUE FAIT SE POSE AU MOMENT OÙ IL EST MESURÉ, jamais dans un bloc récapitulatif à la fin. Un
# récapitulatif est une seconde copie : il dérive dès qu'une branche de mesure change, et il ment
# précisément sur le cas rare — celui où la branche qu'on a oubliée s'exécute.

check() {
  # ─── LE SYSTÈME ───────────────────────────────────────────────────────────────────────────────
  if command -v dpkg >/dev/null && command -v apt-get >/dev/null; then
    p_fact os debian
    p_ok "OS famille Debian/Ubuntu (dpkg + apt présents)"
  else
    p_fact os autre
    p_drift "OS non-Debian : dpkg/apt absents — ce provisioning cible Debian/Ubuntu (WSL, Docker, natif)"
  fi

  # ── bash plancher 4.4 (arrays vides sous set -u, ${var@Q}…) ─────────────────────────────────────
  p_fact bash "$BASH_VERSION"
  if [[ "${BASH_VERSINFO[0]}" -gt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 4 ) ]]; then
    p_ok "bash ${BASH_VERSION} (plancher 4.4)"
  else
    p_drift "bash ${BASH_VERSION} < 4.4 — détecté : $(command -v bash) ; installe un bash récent"
  fi

  local arch; arch="$(uname -m)"
  p_fact arch "$arch"
  case "$arch" in
    x86_64|aarch64) p_ok "arch $arch" ;;
    *) p_drift "arch non supportée : $arch (détecté par uname -m) — cibles : x86_64, aarch64" ;;
  esac

  local ram_mb
  ram_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  p_fact ram_mb "$ram_mb"
  if [[ "$ram_mb" -lt 1536 ]]; then
    p_drift "RAM ${ram_mb}MB < 1536MB — le build de la release échouera ; ajoute de la RAM (WSL: .wslconfig [wsl2] memory=)"
  elif [[ "$ram_mb" -lt 3072 ]]; then
    p_warn "RAM ${ram_mb}MB < 3072MB — build lent possible (pas bloquant)"
    p_ok "RAM ${ram_mb}MB (plancher dur 1536MB)"
  else
    p_ok "RAM ${ram_mb}MB"
  fi

  local disk_mb probe_dir
  probe_dir="$(dirname "$PROV_PREFIX")"
  [[ -d "$probe_dir" ]] || probe_dir="/"
  disk_mb="$(df -Pm "$probe_dir" | awk 'NR==2 {print $4}')"
  p_fact disque_mb "$disk_mb"
  if [[ "$disk_mb" -lt 2048 ]]; then
    p_drift "disque ${disk_mb}MB libres sur $probe_dir < 2048MB — libère de l'espace avant le deploy"
  elif [[ "$disk_mb" -lt 5120 ]]; then
    p_warn "disque ${disk_mb}MB libres sur $probe_dir < 5120MB — juste (pas bloquant)"
    p_ok "disque ${disk_mb}MB libres ($probe_dir)"
  else
    p_ok "disque ${disk_mb}MB libres ($probe_dir)"
  fi

  # ─── LE SUBSTRAT, ET CE QU'IL AUTORISE ────────────────────────────────────────────────────────
  p_fact substrat "$PROV_SUBSTRATE"

  local consent_file="${LCARS_HOST_CONSENT_FILE:-/etc/lcars/host-consent}"
  if [[ "$PROV_SUBSTRATE" == "linux" ]]; then
    if [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
      p_fact consent env
      p_warn "Linux natif, et tu l'as explicitement accepté (LCARS_ALLOW_ANY_HOST) — hors cible : rien ici n'est mesuré sur ce substrat, et il n'y a pas de désinstalleur"
    elif [[ -s "$consent_file" ]]; then
      p_fact consent fichier
      p_warn "Linux natif, accepté une fois sur cette machine ($consent_file) — hors cible : rien ici n'est mesuré sur ce substrat, et il n'y a pas de désinstalleur"
    else
      # ⚠ CE `p_fail` NE BOUGE PAS, et c'est lui qui fait les deux lectures. À l'`apply`, il refuse
      # une machine dont personne n'a dit qu'elle était dédiée. Au `doctor` que la porte joue, il
      # rend le verdict du module non conforme — mais la porte ne lit pas le verdict, elle lit le
      # fait `consent=none`, qui rend le rail POSTE impossible sans toucher au rail CONTENEUR.
      p_fact consent none
      # ⚠ LE MESSAGE NOMME LES TROIS TERRAINS, ET IL N'EN NOMMAIT QU'UN. Il disait « le poste de
      # travail LCARS, c'est WSL2 » — vrai jusqu'au 2026-09-08, faux depuis : ⚖ user, « on s'installe
      # QUE dans des environnements contrôlés : docker, WSL et incus ». Un refus qui ne nomme qu'une
      # issue sur trois envoie l'opérateur vers la plus coûteuse.
      p_fail "HORS CIBLE : LCARS s'installe sur un terrain qu'on peut DÉTRUIRE — une distro WSL2, une instance Incus, un conteneur (substrat mesuré : linux). Ce provisionnement possède /etc, crée un groupe système, pose /opt/lcars, et n'a aucun désinstalleur — on ne le lâche pas sur une machine dont on ne sait pas si c'est celle de quelqu'un. Sous Windows : « wsl --install -d Ubuntu-24.04 ». Sur un hôte Linux : « incus launch images:ubuntu/24.04 <nom> », puis relance dedans. Sur cette machine-ci, si elle est dédiée : LCARS_ALLOW_ANY_HOST=1"
    fi
  else
    p_fact consent sans-objet
  fi

  if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
    if grep -qi 'WSL2\|microsoft-standard' /proc/version 2>/dev/null; then
      p_fact wsl2 oui
      p_ok "WSL2 (kernel $(uname -r))"
    else
      p_fact wsl2 non
      p_drift "WSL1 détecté ($(uname -r)) — bwrap exige WSL2 : « wsl --set-version <distro> 2 » côté Windows"
    fi

    # `/etc/wsl.conf` : le rail poste le REMPLACE en entier (c'est la frontière de sécurité du
    # conteneur). Un fichier étranger n'est pas un refus — c'est un avertissement que la porte doit
    # pouvoir afficher AVANT que quiconque valide, pas découvrir après.
    if [[ ! -f /etc/wsl.conf ]]; then
      p_fact wslconf absent
    elif grep -q "LCARS" /etc/wsl.conf 2>/dev/null; then
      p_fact wslconf notre
    else
      p_fact wslconf etranger
      p_warn "/etc/wsl.conf existe et n'est pas le nôtre — le rail poste le REMPLACE en entier ; sauvegarde ce qui compte"
    fi
  else
    p_fact wsl2 sans-objet
    p_fact wslconf sans-objet
  fi

  local knob
  knob="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent)"
  p_fact userns_knob "$knob"
  case "$knob" in
    0)      p_ok "kernel.apparmor_restrict_unprivileged_userns=0" ;;
    absent) p_ok "pas de restriction AppArmor userns (knob absent)" ;;
    *)      p_warn "kernel.apparmor_restrict_unprivileged_userns=$knob — bwrap peut être bloqué ; la sonde réelle est dans 10-packages (fix : sysctl kernel.apparmor_restrict_unprivileged_userns=0 ou profil AppArmor bwrap)" ;;
  esac

  # ─── DOCKER, SUR TOUT SUBSTRAT ────────────────────────────────────────────────────────────────
  #
  # ⚠ IL N'ÉTAIT MESURÉ QUE SOUS WSL, et c'était le trou du préflight. Le rail CONTENEUR tourne sur
  # n'importe quel substrat et docker y est sa seule condition d'existence : ne pas le mesurer
  # ailleurs, c'était laisser la porte deviner — ou reproduire la sonde de son côté, ce qu'elle
  # faisait. Mesurer partout ne coûte rien et ferme les deux.
  #
  # Le REFUS, lui, ne s'étend pas : il reste là où il était (WSL, où la forge du poste n'a aucune
  # autre forme). Sur linux natif le rail POSE docker, sur docker on est déjà dedans.
  local docker_repond=0
  if docker_endpoint; then
    docker_repond=1
    p_fact docker oui
    p_fact docker_bin "$PROV_DOCKER_BIN"
    p_ok "docker répond ($PROV_DOCKER_BIN)"
  else
    # Deux raisons de ne pas répondre, et la porte a besoin de les distinguer : un daemon absent se
    # pose, un daemon qui REFUSE cet utilisateur se règle par un groupe. Le fait les sépare.
    if [[ "${PROV_DOCKER_DENIED:-0}" == "1" ]]; then p_fact docker refuse; else p_fact docker absent; fi
    p_fact docker_why "$PROV_DOCKER_WHY"
    # ⚠ LE VERDICT NE BOUGE PAS D'UN CRAN, et il est le même pour les deux raisons — c'est celui
    # qu'écrivait ce module avant d'être étendu (`if docker_endpoint; then p_ok; else p_fail`, et
    # `docker_endpoint` rend 1 dans les DEUX cas). Séparer les faits sans séparer les verdicts est
    # tout l'objet de ce module : mesurer plus finement n'autorise pas à refuser autrement.
    if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
      p_fail "$PROV_DOCKER_WHY — et sans docker la forge de LCARS n'a AUCUNE autre forme (c'est un conteneur) : 63-forge-tokens et 66-deck-oidc ne convergeront JAMAIS sur cette machine, le poste aurait un runtime qui ne peut pas travailler"
    else
      # Hors WSL le refus n'a jamais existé : le rail poste POSE docker sur un linux déclaré, et sur
      # docker on est déjà dedans. Le fait suffit, la porte en tire ce qu'elle doit.
      p_warn "$PROV_DOCKER_WHY"
    fi
  fi

  # `compose` : le rail conteneur monte un compose, le poste monte sa forge avec. Sans daemon la
  # question n'a pas d'objet — on ne la pose donc pas plutôt que d'inventer une réponse.
  if [[ "$docker_repond" -eq 0 ]]; then
    p_fact compose sans-objet
  elif docker_compose_cmd "$PROV_DOCKER_BIN"; then
    p_fact compose oui
    p_ok "docker compose répond ($PROV_COMPOSE_CMD)"
  else
    p_fact compose non
    p_fact compose_why "$PROV_COMPOSE_WHY"
    p_warn "$PROV_COMPOSE_WHY"
  fi

  # ─── LA FORGE : MONTÉE PAR LE RAIL, OU FOURNIE ────────────────────────────────────────────────
  #
  # `FORGE_BASE_URL` posée = « j'ai déjà une forge, consomme-la ». C'est l'axe forge du § 13 de
  # `40-RAILS.md`, et le rail conteneur l'exige aujourd'hui hors `--bench`. Le fait sert à la porte pour
  # dire, AVANT la validation, si ce qu'on lui a donné répond.
  if [[ -n "${FORGE_BASE_URL:-}" ]]; then
    p_fact forge_fournie "$FORGE_BASE_URL"
    if curl -fsS -m 5 -o /dev/null "${FORGE_BASE_URL%/}/api/v1/version" 2>/dev/null; then
      p_fact forge_joignable oui
      p_ok "forge fournie et joignable ($FORGE_BASE_URL)"
    else
      p_fact forge_joignable non
      p_warn "FORGE_BASE_URL est posée ($FORGE_BASE_URL) mais l'API ne répond pas — le rail conteneur s'y raccrochera et échouera au premier geste"
    fi
  else
    p_fact forge_fournie ""
    p_fact forge_joignable sans-objet
  fi

  # ─── SUDO ─────────────────────────────────────────────────────────────────────────────────────
  #
  # Le rail poste en a besoin ; le conteneur, jamais. Ce n'est PAS un refus ici : ce module tourne déjà
  # sous root à l'`apply`. C'est un fait pour la porte, qui doit pouvoir dire « ce rail te demandera
  # un mot de passe » avant qu'on choisisse, et refuser proprement si sudo manque.
  if [[ "$EUID" -eq 0 ]]; then
    p_fact sudo root
  elif command -v sudo >/dev/null 2>&1; then
    p_fact sudo oui
  else
    p_fact sudo absent
  fi

  # ─── LE CANAL : QUI A POSÉ LE PRODUIT SUR CETTE MACHINE, ET CE QUE CET ARBRE POSERAIT ────────
  #
  # `channel` est le fait de la MACHINE (`prov_channel` : source, kit, deb, aucun) ; `channel_tree`
  # est ce que CET arbre écrirait s'il posait (kit si c'est un paquet, source sinon — `prov_channel_here`).
  # La porte et `workstation` les comparent : un canal sur un autre est un REFUS qui nomme le
  # geste, jamais une conversion. Le même canal est une mise à jour ; `aucun`, une première pose.
  p_fact channel_tree "$(prov_channel_here)"
  # ⚠ APPEL NU : le p_fail d'un canal illisible doit COMPTER ici — un `$( )` l'imprimerait sans le
  # compter, et ce module rendrait vert une machine dont personne ne sait qui la possède.
  if prov_channel >/dev/null; then
    p_fact channel "$PROV_CHANNEL"
    if [[ "$PROV_CHANNEL" == "aucun" ]]; then
      p_ok "aucun canal d'installation ($PROV_CHANNEL_FILE absent) — cette machine n'a jamais été posée ; cet arbre poserait « $(prov_channel_here) »"
    elif [[ "$PROV_CHANNEL" == "inconnu" ]]; then
      p_warn "canal d'installation INCONNU : un produit est posé ($PROV_PREFIX) sans tampon ($PROV_CHANNEL_FILE) — posé avant le tampon ; un kit ou une source le reprend et l'écrit, un paquet .deb ne se pose PAS dessus"
    else
      p_ok "canal d'installation : $PROV_CHANNEL ($PROV_CHANNEL_FILE) — cet arbre poserait « $(prov_channel_here) »"
    fi
  else
    p_fact channel invalide
  fi

  # ─── Outils de bootstrap (avant même 10-packages : il faut de quoi l'exécuter) ───────────────
  local tool
  for tool in curl git; do
    if command -v "$tool" >/dev/null; then
      p_fact "$tool" oui
      p_ok "$tool présent"
    else
      p_fact "$tool" absent
      p_drift "$tool absent — installe-le d'abord : apt-get install -y $tool"
    fi
  done

  verdict_check
}

case "${1:?usage: 00-preflight.sh <check|apply>}" in
  check) check ;;
  apply) check ;;   # module read-only : converger = constater (aucune mutation à faire ici)
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
