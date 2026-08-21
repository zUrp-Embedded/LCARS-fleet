#!/usr/bin/env bash
# SOURCE: fleet/deploy/modules.d/10-packages.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — paquets runtime (apt) + sonde bwrap RÉELLE (le sandbox tourne, pas « le paquet est là »)
# APPLY-ON: wsl linux
# CHECK-ON: any
# NEEDS: root
# (CHECK-ON any, APPLY-ON sans docker : les paquets sont des layers de l'image — mais bwrap
# opérationnel et l'outillage présent doivent être VRAIS en conteneur, et le doctor les y sonde.)
#
# Le strict nécessaire au RUNTIME v2 (le contrat vit dans fleet/etc/README.md) :
#   tmux        — sessions pod (host_launch/bwrap_launch) + le daemon fleet_v2
#   bubblewrap  — containment des pods (bwrap_launch.sh, sanctuaire)
#   git         — push per-step-run vers la forge
#   curl, jq    — clients HTTP forge + parse JSON (deps dures des scripts bin/ et etc/)
#   unzip       — dépose du précompilé Elixir (module 15-toolchain)
#   ca-certificates — TLS sortant (installer claude, forge https éventuelle)
#   socat       — LE RELAIS D'EGRESS DU POD, et il est load-bearing : le sanctuaire n'a AUCUN
#                 namespace réseau, donc `localhost:<port>` n'existe DANS le bac que parce que socat
#                 y écoute et porte le flux vers la socket unix du proxy CONNECT. Absent, le pod est
#                 scellé et `bwrap_launch.sh:478` REFUSE — « the pod would be sealed with no way to
#                 reach its vendor », exit 2.
#
#                 ⚠ MESURE DU 2026-08-21, POSTE NATIF INSTALLÉ À FROID : la fleet démarre, le BEAM
#                 vit, les credentials sont là — et AUCUN pod ne naît. Le warden respawne le pod
#                 permanent `starfleet` cinq fois (5 s, 10 s, 20 s, 40 s, 80 s) puis abandonne, avec
#                 pour seule trace « exited before submitting result (exit=2) ». Le produit était
#                 mort dans sa fonction centrale, sur une installation dont les 23 modules étaient
#                 verts, parce qu'un paquet que SEUL le Dockerfile posait manquait.
#   git-filter-repo — la réécriture d'historique de `bin/publish-transform.sh` : le script la
#                     REFUSE si elle est absente (exit 1) et imprime une recette de venv à taper.
#                     Une dépendance qu'on sait nommer est une dépendance qu'on installe.
#   gh              — le geste de publication vers GitHub, celui que `publish-transform.sh` IMPRIME
#                     pour l'humain : le script ne pousse jamais lui-même (contrainte dure du
#                     projet), donc l'outil du dernier pas doit être dans la boîte.
# En Docker ces paquets sont des LAYERS de l'image (docker/Dockerfile) — même liste, autre
# mécanisme, ISO vérifiée par le même doctor sur place (d'où APPLY-ON sans docker, CHECK-ON any).
#
# PAS de yq (la donnée v2 est plate : env + listes — le blueprint YAML v1 meurt avec les
# users-par-rôle). python3 EST requis — pas pour du patch-json (mort), mais comme interpréteur du
# bridge MCP des pods (fleet_mcp_stdio_bridge.py) : l'ancien « PAS de python » ici mentait au
# sanctuaire.
#
# ⚠ « PAS de gh (la forge est Gitea, parlée en curl) » était écrit ici, et la moitié qui parle de la
# forge reste VRAIE : aucun appel à la forge ne passe par `gh`, et aucun ne le doit. Ce qui était
# faux, c'est d'en conclure que la boîte n'en a pas l'emploi — `gh` n'est pas un client de forge
# ici, c'est l'outil de l'EXPORT vers un miroir externe, un chemin que Gitea ne couvre pas.
#
# LES DEUX VIENNENT D'APT, ET RIEN N'EST PINNÉ — ⚖ ARBITRAGE USER (2026-08-21) : *« la cible c'est
# la dernière Ubuntu LTS, et on pin rien, on laisse faire Canonical. »* La distribution de référence
# n'est ni Debian ni un dérivé Mint : c'est l'Ubuntu LTS courante, aujourd'hui **26.04 (resolute)**,
# et sa version d'un paquet EST la version. Le pin version+sha256 reste réservé à ce qu'aucune
# distribution ne livre (ttyd) ou dont la version est load-bearing (le précompilé Elixir) — pas à
# un outil que l'archive tient à jour pour nous.
#
# ⚠ LES DEUX SONT DANS `universe`, PAS DANS `main` (mesuré sur Launchpad, resolute : `gh` 2.46.0-4,
# `git-filter-repo` 2.47.0-3). Une image ou un cloud-init qui n'active que `main` ne les trouvera
# pas — et `apt_ensure` dira « paquet absent », pas « dépôt absent ». C'est le seul piège de cette
# ligne, et il ne se voit qu'à l'install.

set -euo pipefail
# shellcheck source=../lib/provision-lib.sh
. "${PROVISION_LIB:?PROVISION_LIB non posé — lance via ./provision, pas le module nu}"

PACKAGES=(
  tmux bubblewrap git curl jq unzip ca-certificates python3 socat
  git-filter-repo gh
  # ─── LE SOCLE D'OUTILLAGE DES PODS (lot 1 du rail toolchain) ─────────────────────────────────
  # ⚠ IL N'ÉTAIT QUE DANS L'IMAGE, ET LE RAIL POSTE LIVRAIT DONC DES PODS INFIRMES. Le Dockerfile
  # dit le coût : « sans ces paquets un pod ne produit que du bash, du HTML et du python NU : ni
  # venv, ni pip, ni compilateur. Chaque dépendance de projet devrait alors passer par une
  # approbation humaine — six mois à faire signer ce qui aurait dû être dans l'image. »
  #
  # `python3-venv` N'EST PAS UN CONFORT : PEP 668 est ACTIF (les stdlib Debian/Ubuntu livrent
  # `EXTERNALLY-MANAGED`), donc un `pip install` hors venv ÉCHOUE PAR CONCEPTION. `python3-pip`
  # seul ne suffit pas.
  #
  # build-essential + python3-dev + pkg-config + libssl-dev sont pour la QUEUE : la plupart des
  # paquets python populaires livrent des wheels manylinux et ne compilent rien ; ceux qui restent
  # compilent des extensions C, les modules npm natifs veulent node-gyp, et les crates rust en
  # `-sys` veulent cc + pkg-config + le `-dev` de la lib C visée.
  build-essential pkg-config python3-dev libssl-dev python3-venv python3-pip
  # ─── ET CE QUI EST PRÉSENT PAR CHANCE N'EST PAS PRÉSENT PAR LE RAIL ──────────────────────────
  # Mesuré le 2026-08-21 sur une Ubuntu Server 26.04 fraîche : les quatre ci-dessous étaient déjà
  # là, par défaut de la distribution. Aucun ne l'est par contrat, et deux sont load-bearing :
  #   · `util-linux-extra` fournit `setpriv` — TOUTE la console en dépend (`console.sh`,
  #     `console-landing.sh`), et une image minimale ne l'a pas ;
  #   · `sudo` est ce que la règle étroite de `45-sudoers-toolchain` désigne — sans lui, ce module
  #     écrit une permission que personne ne peut exercer.
  # `less` et `bash-completion` sont du confort de shell, et ils sont dans l'image : les garder
  # alignés coûte deux mots et évite deux consoles qui ne se comportent pas pareil.
  util-linux-extra sudo less bash-completion
)

# ─── CE QUE SEUL LE LINUX NATIF DOIT SE FAIRE POSER ─────────────────────────────────────────────
#
# ⚖ USER 2026-08-21 : « docker, ça me choque pas que ça soit un pré-requis […] tu peux toujours
# l'installer si tu trouves pas. »
#
# SUR UNE MACHINE DÉDIÉE, LCARS MONTE SA FORGE LUI-MÊME — `48-forge-host` fait `compose up -d` sur
# un Gitea, et il refuse en disant « la forge du poste est un CONTENEUR, il n'en existe aucune
# autre forme ». Docker n'est donc pas un confort : c'est une dépendance dure de la chaîne, et
# aucun module ne la posait. Sur une Ubuntu vierge, l'install mourait au module 48 et TOUT ce qui
# suit — jetons de rôle, OIDC du deck, branche ops — sortait en dérive pour une cause qui n'était
# pas la leur. Une passe à froid qui s'arrête là ne mesure presque rien.
#
# ⚠ `linux` SEULEMENT, ET LES DEUX AUTRES SUBSTRATS SONT DES REFUS RAISONNÉS :
#   · `wsl`    — le daemon vient de Docker Desktop côté Windows, monté dans `/mnt/wsl/docker-desktop`.
#                `docker-endpoint.sh` le trouve sans qu'aucun paquet ne soit installé ici ; poser
#                `docker.io` dans la distro y fabriquerait un SECOND daemon, concurrent du premier.
#   · `docker` — on est DANS le conteneur ; il n'y a rien à installer et rien à monter.
#
# Mesuré sur Launchpad, resolute : `docker.io 27.5.1+dfsg4-2ubuntu1` et `docker-compose-v2
# 2.40.3+ds1-0ubuntu1`, tous deux dans `universe`. Chez Canonical, donc pas de dépôt tiers et pas
# de pin — la même règle que pour `gh` et `git-filter-repo` juste au-dessus.
LINUX_PACKAGES=(docker.io docker-compose-v2)

# La liste EFFECTIVE de ce passage — une seule fonction, lue par `check` ET par `apply`, pour que
# les deux ne puissent pas répondre différemment sur le même substrat.
effective_packages() {
  printf '%s\n' "${PACKAGES[@]}"
  [[ "${PROV_SUBSTRATE:-}" == "linux" ]] && printf '%s\n' "${LINUX_PACKAGES[@]}"
  return 0
}

# Sonde RÉELLE du containment : un bwrap minimal DOIT tourner sous un user NON-root (les pods
# tournent comme l'humain). Lire une config ou un dpkg -s ne prouve rien — Ubuntu ≥23.10 peut
# avoir bwrap installé ET bloqué par AppArmor (userns restreints). On sonde en tant que
# PROV_HUMAN : c'est LUI qui spawnera des pods.
probe_bwrap() {
  # stderr NON étouffé : l'échec réel de bwrap doit être verbeux (doctrine), et surtout un
  # as_human impossible (doctor lancé par un user tiers) doit dire SA cause — le 2>/dev/null
  # transformait « je ne peux pas sonder » en faux « le sandbox échoue ».
  as_human bwrap --ro-bind / / --unshare-all --die-with-parent /bin/true
}

check() {
  # (nommé pkg_absent, pas « missing » : la lib a un array `missing` dans apt_ensure, et
  # l'analyse -x confond les deux scopes — SC2178 parasite.)
  local pkg pkg_absent=0
  while IFS= read -r pkg; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
      p_ok "paquet $pkg"
    else
      p_drift "paquet $pkg absent"
      pkg_absent=1
    fi
  done < <(effective_packages)
  if [[ "$pkg_absent" -eq 0 ]]; then
    if probe_bwrap; then
      p_ok "bwrap sandbox opérationnel (sonde réelle, user $PROV_HUMAN)"
    else
      p_drift "bwrap installé mais un sandbox minimal ÉCHOUE (user $PROV_HUMAN) — userns restreints ? (sysctl kernel.apparmor_restrict_unprivileged_userns, profil AppArmor bwrap) ; sans ça, AUCUN pod ne spawnera"
    fi
  fi
  verdict_check
}

apply() {
  local -a pkgs; mapfile -t pkgs < <(effective_packages)
  apt_ensure "${pkgs[@]}" || verdict_apply
  if probe_bwrap; then
    p_ok "bwrap sandbox opérationnel (sonde réelle, user $PROV_HUMAN)"
  else
    # On n'auto-flippe PAS un sysctl de sécurité système : c'est un arbitrage humain
    # (assouplir AppArmor vs poser un profil dédié). On échoue en le disant précisément.
    p_fail "bwrap installé mais le sandbox minimal ÉCHOUE (user $PROV_HUMAN) — arbitrage requis : sysctl kernel.apparmor_restrict_unprivileged_userns=0 OU profil AppArmor pour bwrap ; re-lance ensuite"
  fi
  verdict_apply
}

case "${1:?usage: 10-packages.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
