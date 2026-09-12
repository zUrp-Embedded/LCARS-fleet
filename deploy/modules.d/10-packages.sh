#!/usr/bin/env bash
# SOURCE: deploy/modules.d/10-packages.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — paquets runtime (apt) + sonde bwrap RÉELLE (le sandbox tourne, pas « le paquet est là »)
# APPLY-ON: wsl linux docker
# CHECK-ON: any
# NEEDS: root
# AFTER: 00-preflight
# (CHECK-ON any, APPLY-ON sans docker : les paquets sont des layers de l'image — mais bwrap
# opérationnel et l'outillage présent doivent être VRAIS en conteneur, et le doctor les y sonde.)
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
  # `python3-venv` N'EST PAS UN CONFORT : PEP 668 est ACTIF (les stdlib Debian/Ubuntu livrent
  # `EXTERNALLY-MANAGED`), donc un `pip install` hors venv ÉCHOUE PAR CONCEPTION. `python3-pip`
  # seul ne suffit pas.
  #
  # build-essential + python3-dev + pkg-config + libssl-dev sont pour la QUEUE : la plupart des
  # paquets python populaires livrent des wheels manylinux et ne compilent rien ; ceux qui restent
  # compilent des extensions C, les modules npm natifs veulent node-gyp, et les crates rust en
  # `-sys` veulent cc + pkg-config + le `-dev` de la lib C visée.
  # ⚠ LE SOCLE DE COMPILATION (build-essential…) est plus bas, dans la baseline des pods — il a vecu
  # dans une seconde liste « livraison SOURCE seulement » (mesure 2004, 2026-09-05, du temps des
  # .deb : six drifts « absent » sur un poste installe par paquet), partie le 2026-09-11.
  # ⚠ `sudo` A PERDU SA JUSTIFICATION ECRITE AVEC LA REGLE QU'ELLE CITAIT. Elle disait que ce paquet
  # est « ce que la regle etroite de 45-sudoers-toolchain designe » — cette regle est retiree, et la
  # phrase est partie avec elle. Ce qui reste vrai, et qui n'etait ecrit nulle part : c'est le RAIL
  # lui-meme qui en depend. `install.sh` refuse de continuer sans lui (« sudo est absent, et ce rail
  # en a besoin pour provisionner ce systeme »), et `workstation` s'escalade par `exec sudo`. Une
  # ligne sans raison finit par etre retiree par quelqu'un qui cherche a alleger.
  util-linux-extra sudo
  # procps : `pgrep`/`pkill` — lus par 60-deploy (fleet debout ?), le convergeur d'humains (revocation)
  # et les sondes de 64. Il vivait dans l'outillage du GATE de 60 ; le gate ne se joue plus a
  # l'install (DI-07), le besoin runtime, lui, reste.
  procps
  # ⚠ `universe`, pas `main` : sur une image serveur où ce composant serait fermé, `apt_ensure`
  # échoue en le disant. C'est le bon endroit pour l'apprendre — avant la console noire.
  ttyd
  # ─── LA BASELINE D'OUTILLAGE DES PODS — un besoin RUNTIME, sur CHAQUE terrain ─────────────────
  # Sans ces paquets un pod ne produit que du bash, du HTML et du python NU : ni venv, ni pip, ni
  # compilateur — chaque dépendance de projet passerait par une approbation humaine. python3-venv
  # n'est pas un confort, c'est le seul chemin (PEP 668 actif sur ubuntu 26.04 : pip hors venv
  # ÉCHOUE par conception). build-essential + python3-dev + pkg-config + libssl-dev sont pour la
  # QUEUE : le paquet sans wheel qui compile ses extensions C, node-gyp, les crates -sys.
  # ⚠ ILS VIVAIENT DANS BUILD_PACKAGES, « livraison SOURCE seulement » — et l'image les posait à la
  # main pour ses pods (le jumeau Dockerfile, retiré le 2026-09-11). Deux rails, deux vérités : un
  # poste installé par kit n'avait pas de venv pour ses pods. Une seule liste, ici.
  python3-venv python3-pip build-essential pkg-config python3-dev libssl-dev
  # le confort de shell d'un humain dans le conteneur (l'image les posait, le poste les a par sa distro)
  less bash-completion
)

# docker-ce vit dans 12-docker-engine, sur le substrat linux seul.
effective_packages() {
  printf '%s\n' "${PACKAGES[@]}"
  return 0
}

probe_bwrap() {
  # stderr NON étouffé : l'échec réel de bwrap doit être verbeux (doctrine), et surtout un
  # as_human impossible (doctor lancé par un user tiers) doit dire SA cause — le 2>/dev/null
  # transformait « je ne peux pas sonder » en faux « le sandbox échoue ».
  as_human bwrap --ro-bind / / --unshare-all --die-with-parent /bin/true
}

check() {
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
    # ⚠ LA SONDE bwrap MESURE LE NOYAU, PAS L'IMAGE. Dans le stage `verify` du Dockerfile (le doctor
    # joué au BUILD sur le système de fichiers de l'image), le noyau est celui de BuildKit, sans
    # userns : la sonde échoue là où le conteneur, une fois booté, réussit. Vu au premier build avec verify.
    # `PROV_KERNEL_PROBES=0` dit « pas de vérité ici » ; le check le DIT au lieu
    # de rendre un drift qui n'en est pas un — et au boot, sans la variable, la sonde se joue.
    if [[ "${PROV_KERNEL_PROBES:-1}" == "0" ]]; then
      p_warn "sonde bwrap NON jouée (PROV_KERNEL_PROBES=0 : ce noyau n'est pas celui de la cible) — elle se joue au boot"
    elif probe_bwrap; then
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
  if [[ "${PROV_KERNEL_PROBES:-1}" == "0" ]]; then
    p_warn "sonde bwrap NON jouée (PROV_KERNEL_PROBES=0 : ce noyau n'est pas celui de la cible) — elle se joue au boot"
  elif probe_bwrap; then
    p_ok "bwrap sandbox opérationnel (sonde réelle, user $PROV_HUMAN)"
  else
    p_fail "bwrap installé mais le sandbox minimal ÉCHOUE (user $PROV_HUMAN) — arbitrage requis : sysctl kernel.apparmor_restrict_unprivileged_userns=0 OU profil AppArmor pour bwrap ; re-lance ensuite"
  fi
  verdict_apply
}

case "${1:?usage: 10-packages.sh <check|apply>}" in
  check) check ;;
  apply) apply ;;
  *) p_die "mode inconnu: $1 (check|apply)" ;;
esac
