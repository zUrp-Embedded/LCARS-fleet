#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/00-preflight.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — préflight fail-fast : plancher OS/arch/RAM/disque/WSL2, messages actionnables
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: root
#
# ⚠ `root` PARCE QU'IL MESURE LA MACHINE, PAS UN HUMAIN. Ce module ne lit que des faits systeme
# (OS, bash, arch, RAM, disque, WSL2, userns, curl, git, docker) ; aucun d'eux n'appartient a
# quelqu'un. Il a declare `human` tant que le runner ignorait la declaration — le jour ou elle a
# commence a poser l'identite, sa sonde docker est passee sous un uid qui n'a pas le droit sur la
# socket du daemon, et il a rendu « aucun daemon ne repond » sur une machine ou le daemon repond.
# La regle : un module declare l'identite de ce qu'il MESURE, pas celle qui se trouvait la.
#
# AUCUNE mutation — ce module ne fait que sonder (apply = check). Chaque échec dit : le problème
# précis, l'état DÉTECTÉ, et le geste pour réparer — jamais un « failed » nu.
# Doctrine plancher (leçon mail-in-a-box, leur faiblesse #3) : des contraintes `>=`, jamais une
# égalité de version exacte qui casse au premier bump distro.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

check() {
  # ── Famille OS : il nous faut dpkg/apt (les modules paquets sont apt-only, assumé) ──────────────
  if command -v dpkg >/dev/null && command -v apt-get >/dev/null; then
    p_ok "OS famille Debian/Ubuntu (dpkg + apt présents)"
  else
    p_drift "OS non-Debian : dpkg/apt absents — ce provisioning cible Debian/Ubuntu (WSL, Docker, natif)"
  fi

  # ── bash plancher 4.4 (arrays vides sous set -u, ${var@Q}…) ─────────────────────────────────────
  if [[ "${BASH_VERSINFO[0]}" -gt 4 || ( "${BASH_VERSINFO[0]}" -eq 4 && "${BASH_VERSINFO[1]}" -ge 4 ) ]]; then
    p_ok "bash ${BASH_VERSION} (plancher 4.4)"
  else
    p_drift "bash ${BASH_VERSION} < 4.4 — détecté : $(command -v bash) ; installe un bash récent"
  fi

  # ── Arch ────────────────────────────────────────────────────────────────────────────────────────
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|aarch64) p_ok "arch $arch" ;;
    *) p_drift "arch non supportée : $arch (détecté par uname -m) — cibles : x86_64, aarch64" ;;
  esac

  # ── RAM 3 paliers (le build mix release est le pic ; le BEAM au run est modeste) ────────────────
  local ram_mb
  ram_mb="$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
  if [[ "$ram_mb" -lt 1536 ]]; then
    p_drift "RAM ${ram_mb}MB < 1536MB — le build de la release échouera ; ajoute de la RAM (WSL: .wslconfig [wsl2] memory=)"
  elif [[ "$ram_mb" -lt 3072 ]]; then
    p_warn "RAM ${ram_mb}MB < 3072MB — build lent possible (pas bloquant)"
    p_ok "RAM ${ram_mb}MB (plancher dur 1536MB)"
  else
    p_ok "RAM ${ram_mb}MB"
  fi

  # ── Disque sur le FS de PROV_PREFIX (release ~100MB, _build ~2GB au build) ──────────────────────
  local disk_mb probe_dir
  probe_dir="$(dirname "$PROV_PREFIX")"
  [[ -d "$probe_dir" ]] || probe_dir="/"
  disk_mb="$(df -Pm "$probe_dir" | awk 'NR==2 {print $4}')"
  if [[ "$disk_mb" -lt 2048 ]]; then
    p_drift "disque ${disk_mb}MB libres sur $probe_dir < 2048MB — libère de l'espace avant le deploy"
  elif [[ "$disk_mb" -lt 5120 ]]; then
    p_warn "disque ${disk_mb}MB libres sur $probe_dir < 5120MB — juste (pas bloquant)"
    p_ok "disque ${disk_mb}MB libres ($probe_dir)"
  else
    p_ok "disque ${disk_mb}MB libres ($probe_dir)"
  fi

  # ── LA CIBLE DU POSTE DE TRAVAIL EST WSL2, ET C'EST LA SEULE ──────────────────────────────────
  #
  # ⚖ ARBITRAGE USER 2026-08-18, deux phrases : « jamais on s'installe sur le poste de l'user
  # directement — ou alors c'est l'user qui fait un clone à la main et se démerde pour le reste »,
  # et « tu fais le script pour installer sur WSL, avec docker dispo, exactement comme ici, et tu
  # arrêtes de vouloir gérer toutes les configs de la terre ».
  #
  # POURQUOI WSL ET RIEN D'AUTRE. Sous Windows il existe exactement UNE façon d'avoir une VM Linux,
  # tout le monde l'a déjà, et LCARS ne tourne pas ailleurs : le substrat est donc garanti, donc
  # mesurable, donc promettable. Sous Linux il y a cinq façons (libvirt, multipass, VirtualBox,
  # Proxmox, LXC), l'utilisateur a déjà son avis, et celle qu'on choisirait serait la mauvaise pour
  # la majorité — quelqu'un qui tourne sur du Linux natif maintient sa machine et se fera son poste
  # tout seul. Ce n'est pas une restriction de capacité, c'est une restriction de PROMESSE.
  #
  # CE QUE CE PROVISIONNEMENT VA FAIRE S'IL SE TAIT : `30-wsl` possède `/etc/wsl.conf` en entier,
  # `20-groups` crée un groupe système, `25-directories` pose `/opt/lcars`, et
  # `60-deploy` verrouille un préfixe en root:fleet. Sur une machine de travail ce n'est pas une
  # installation, c'est un dégât — et il n'existe aucun désinstalleur.
  #
  # ⚠ LE REFUS EST CONTOURNABLE, DÉLIBÉRÉMENT. Un refus qu'on ne peut pas lever se contourne
  # autrement : par un clone à la main et des commandes recopiées une par une, c'est-à-dire sans
  # aucune des gardes de ce module. Nommer l'échappatoire la rend visible.
  # ⚠ LE CONSENTEMENT A DEUX SOURCES, ET LA SECONDE EXISTE PARCE QU'UN DAEMON N'A PAS D'ENV.
  # `LCARS_ALLOW_ANY_HOST` est ce que tape l'humain à l'install ; le marqueur est ce que
  # `05-host-consent` en garde. Tout ce qui rejoue le provisionnement plus tard — le convergeur
  # d'humains, une unité systemd, un doctor lancé par cron — tourne SANS cet environnement, et se
  # faisait refuser ici sur un consentement DÉJÀ donné (mesure du 2026-08-21 : compte Unix créé,
  # `~/.lcars` absent, et un motif qui parle de choix de plateforme à un programme).
  #
  # Le refus, lui, ne bouge pas d'un pouce : sans AUCUNE des deux sources, c'est non.
  local consent_file="${LCARS_HOST_CONSENT_FILE:-/etc/lcars/host-consent}"
  if [[ "$PROV_SUBSTRATE" == "linux" ]]; then
    if [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
      p_warn "Linux natif, et tu l'as explicitement accepté (LCARS_ALLOW_ANY_HOST) — hors cible : rien ici n'est mesuré sur ce substrat, et il n'y a pas de désinstalleur"
    elif [[ -s "$consent_file" ]]; then
      p_warn "Linux natif, accepté une fois sur cette machine ($consent_file) — hors cible : rien ici n'est mesuré sur ce substrat, et il n'y a pas de désinstalleur"
    else
      p_fail "HORS CIBLE : le poste de travail LCARS, c'est WSL2 (substrat mesuré : linux). Ce provisionnement possède /etc, crée un groupe système, pose /opt/lcars, et n'a aucun désinstalleur — on ne le lâche pas sur une machine dont on ne sait pas si c'est celle de quelqu'un. Sous Windows : « wsl --install -d Ubuntu-24.04 », puis relance ici. Sur du Linux natif, clone le dépôt et sers-toi de ce que tu veux — ou LCARS_ALLOW_ANY_HOST=1 si tu sais ce que tu fais"
    fi
  fi

  # ── DOCKER : C'EST LUI QUI PORTE LA FORGE, IL FAIT PARTIE DE LA CIBLE ──────────────────────────
  #
  # Il n'existe AUCUNE forge non-conteneurisée dans ce dépôt : `bench-up.sh` démarre un Gitea en
  # conteneur, et `50-forge` ne fait que SONDER une URL qu'on lui donne. Un poste de travail sans
  # docker installe donc un runtime parfaitement fonctionnel — et aucune forge, ce qui laisse
  # `50-forge` et `55-deck-oidc` en dérive avec des consignes qui nomment `box`, injouables.
  # Mesuré le 2026-08-18 sur une Ubuntu neuve sans docker : exactement ces deux dérives, et le
  # lecteur n'avait aucun moyen de savoir d'avance que c'était attendu. On le dit AVANT.
  if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
    # ⚠ ON SONDE UN ENDPOINT QUI RÉPOND, PAS UN BINAIRE. `command -v docker` se trompait DANS LES
    # DEUX SENS : sa présence ne prouve pas que Docker Desktop tourne (cas fréquent après un reboot
    # Windows), et son absence ne prouve pas que docker manque — sur WSL le donné est le montage
    # `/mnt/wsl/docker-desktop`, CLI comprise, présent pour toute distro même sans intégration
    # activée. Mesuré sur une instance VIERGE (la seule mesure qui vaille — un poste de travail
    # porte des années de câblage à la main) : aucun binaire dans le PATH, et le daemon répond.
    # `docker_endpoint` rend la paire CLI+socket qui marche, ou dit ce qui manque.
    if docker_endpoint; then
      p_ok "docker répond ($PROV_DOCKER_BIN) — la forge du poste peut être montée (fleet/deploy/docker/bench/bench-up.sh)"
    else
      # ⚖ ARBITRAGE USER 2026-08-18 : « ça, on refuse. docker-desktop c'est un clic. »
      #
      # ET C'EST UN REFUS, PAS UNE DÉRIVE, parce que les deux mots ne disent pas la même chose. Une
      # dérive, c'est « l'état-cible n'est pas tenu ET ce rail peut le tenir » — on l'annonce, un
      # apply le converge. Ici il ne le peut pas : la forge est un CONTENEUR, il n'en existe aucune
      # autre forme dans ce dépôt, donc `50-forge` et `55-deck-oidc` ne convergeront JAMAIS sur
      # cette machine. Mesuré le 2026-08-18 : 11 modules sur 13, et les deux manquants étaient
      # exactement ceux-là.
      #
      # Installer un runtime qui ne peut pas travailler, c'est livrer un objet qui a l'air posé et
      # qui n'aboutit nulle part — et le remède tient en un clic, sur cette machine, avant de
      # relancer. Un refus qui coûte un relancement vaut mieux qu'une install qui coûte une enquête.
      #
      # ⚠ LE MESSAGE PORTE LE MOTIF DE LA SONDE, PAS UNE SUPPOSITION. Il disait « docker absent […]
      # intégration WSL activée pour cette distro » : deux affirmations fausses dans le cas le plus
      # fréquent. Docker peut être là et éteint ; et l'intégration n'est PAS nécessaire — le montage
      # suffit. `PROV_DOCKER_WHY` dit ce qui a été essayé et ce qui n'a pas répondu ; on l'imprime au
      # lieu de le paraphraser, sinon la sonde mesure une chose et le refus en raconte une autre.
      p_fail "$PROV_DOCKER_WHY — et sans docker la forge de LCARS n'a AUCUNE autre forme (c'est un conteneur) : 50-forge et 55-deck-oidc ne convergeront JAMAIS sur cette machine, le poste aurait un runtime qui ne peut pas travailler"
    fi
  fi

  # ── WSL : version 2 obligatoire (WSL1 = pas de vrai kernel → pas de namespaces → pas de bwrap) ──
  if [[ "$PROV_SUBSTRATE" == "wsl" ]]; then
    if grep -qi 'WSL2\|microsoft-standard' /proc/version 2>/dev/null; then
      p_ok "WSL2 (kernel $(uname -r))"
    else
      p_drift "WSL1 détecté ($(uname -r)) — bwrap exige WSL2 : « wsl --set-version <distro> 2 » côté Windows"
    fi
  fi

  # ── Namespaces user non-privilégiés (le substrat du sandbox bwrap) ──────────────────────────────
  # Sonde des KNOBS ici (info early) ; la sonde RÉELLE (bwrap qui tourne) vit dans 10-packages,
  # une fois bwrap installé. Ubuntu ≥23.10 restreint les userns par AppArmor — dit explicitement.
  local knob
  knob="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo absent)"
  case "$knob" in
    0)      p_ok "kernel.apparmor_restrict_unprivileged_userns=0" ;;
    absent) p_ok "pas de restriction AppArmor userns (knob absent)" ;;
    *)      p_warn "kernel.apparmor_restrict_unprivileged_userns=$knob — bwrap peut être bloqué ; la sonde réelle est dans 10-packages (fix : sysctl kernel.apparmor_restrict_unprivileged_userns=0 ou profil AppArmor bwrap)" ;;
  esac

  # ── Outils de bootstrap (avant même 10-packages : il faut de quoi l'exécuter) ───────────────────
  local tool
  for tool in curl git; do
    if command -v "$tool" >/dev/null; then
      p_ok "$tool présent"
    else
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
