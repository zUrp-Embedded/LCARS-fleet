#!/usr/bin/env bash
# SOURCE: deploy/modules.d/10-packages.sh
# AUTHOR: DrDree
# STARDATE: 2026-07-05
# STATUS: PROTO-V2 — paquets runtime (apt) + sonde bwrap RÉELLE (le sandbox tourne, pas « le paquet est là »)
# APPLY-ON: wsl linux
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
  build-essential pkg-config python3-dev libssl-dev python3-venv python3-pip
  # ⚠ `sudo` A PERDU SA JUSTIFICATION ECRITE AVEC LA REGLE QU'ELLE CITAIT. Elle disait que ce paquet
  # est « ce que la regle etroite de 45-sudoers-toolchain designe » — cette regle est retiree, et la
  # phrase est partie avec elle. Ce qui reste vrai, et qui n'etait ecrit nulle part : c'est le RAIL
  # lui-meme qui en depend. `install.sh` refuse de continuer sans lui (« sudo est absent, et ce rail
  # en a besoin pour provisionner ce systeme »), et `workstation` s'escalade par `exec sudo`. Une
  # ligne sans raison finit par etre retiree par quelqu'un qui cherche a alleger.
  util-linux-extra sudo less bash-completion
  # procps : `pgrep`/`pkill` — lus par 60-deploy (fleet debout ?), le convergeur d'humains (revocation)
  # et les sondes de 64. Il vivait dans l'outillage du GATE de 60 ; le gate ne se joue plus a
  # l'install (DI-07), le besoin runtime, lui, reste.
  procps
  # ⚠ `universe`, pas `main` : sur une image serveur où ce composant serait fermé, `apt_ensure`
  # échoue en le disant. C'est le bon endroit pour l'apprendre — avant la console noire.
  ttyd
)

# ⚠ `linux` SEULEMENT, ET LES DEUX AUTRES SUBSTRATS SONT DES REFUS RAISONNÉS :
#   · `wsl`    — le daemon vient de Docker Desktop côté Windows, monté dans `/mnt/wsl/docker-desktop`.
#                `docker-endpoint.sh` le trouve sans qu'aucun paquet ne soit installé ici ; poser
#                un paquet docker dans la distro y fabriquerait un SECOND daemon, concurrent du premier.
#   · `docker` — on est DANS le conteneur ; il n'y a rien à installer et rien à monter.
LINUX_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

DOCKER_KEYRING="${LCARS_DOCKER_KEYRING:-/etc/apt/keyrings/docker.asc}"
DOCKER_LIST="${LCARS_DOCKER_LIST:-/etc/apt/sources.list.d/docker.list}"
# La MÊME clé sert les deux dépôts (ubuntu et debian) — vérifié : même sha256 aux deux URL. Un pin
# par distro serait deux vérités pour un fait.
DOCKER_GPG_SHA256="${LCARS_DOCKER_GPG_SHA256:-1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570}"

os_field() { # os_field <clef de /etc/os-release>
  [[ -r /etc/os-release ]] || return 1
  ( . /etc/os-release 2>/dev/null; printf '%s' "${!1:-}" )
}

ensure_docker_repo() {
  local id codename arch url
  id="$(os_field ID || true)"; codename="$(os_field VERSION_CODENAME || true)"
  case "$id" in
    ubuntu|debian) ;;
    *) p_fail "dépôt docker : distro « ${id:-inconnue} » — l'upstream ne publie que pour ubuntu et debian"; return 1 ;;
  esac
  [[ -n "$codename" ]] || { p_fail "dépôt docker : /etc/os-release ne donne pas VERSION_CODENAME — la suite apt est indérivable"; return 1; }

  # ⚠ ON SONDE LA SUITE AVANT DE POSER QUOI QUE CE SOIT. Sans ça, la source part sur le disque, et
  # c'est `apt-get update` qui échoue — sur un message de dépôt introuvable que personne ne
  # rattachera à ce choix, deux modules plus loin.
  url="https://download.docker.com/linux/$id"
  local rc=0 cerr; cerr="$(mktemp)"
  curl -fsIL --max-redirs 3 -m 20 -o /dev/null "$url/dists/$codename/Release" 2>"$cerr" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 22 ]]; then
      p_fail "dépôt docker : la suite « $codename » n'existe pas chez Docker ($url/dists/) — rien n'est posé ; installe docker toi-même, le rail s'y branchera (il sonde un daemon, pas un paquet)"
    else
      p_fail "dépôt docker : $url INJOIGNABLE (curl rc=$rc — $(tr -d '\n' < "$cerr")) — réseau, proxy ou DNS ; ce n'est PAS un manque côté Docker, rien n'est posé"
    fi
    rm -f "$cerr"; return 1
  fi
  rm -f "$cerr"

  # ⚠ CE QUI EXISTAIT AVANT NOUS SE CONSTATE AVANT D'ECRIRE, JAMAIS APRES. Deux gestes en dependent
  # et ils tirent en sens opposes : le journal (qui revendique la pose, donc autorise le retrait) et
  # le rollback ci-dessous (qui efface). Les deux etaient inconditionnels — sur une machine qui
  # portait deja le depot docker, le premier faisait revendiquer a LCARS le depot d'un operateur, et
  # le second l'effacait en annoncant « la machine repart comme avant ». C'etait l'inverse exact.
  local list_avant=0 key_avant=0 sauve=""
  [[ -f "$DOCKER_LIST" ]]    && list_avant=1
  [[ -f "$DOCKER_KEYRING" ]] && key_avant=1
  if [[ "$list_avant" -eq 1 || "$key_avant" -eq 1 ]]; then
    # Un rollback qui EFFACE ce qu'il n'a pas cree n'est pas un rollback. On garde de quoi remettre
    # la machine dans l'etat qu'elle avait — la seule lecture honnete de « repart comme avant ».
    sauve="$(mktemp -d)"
    [[ "$list_avant" -eq 1 ]] && cp -p "$DOCKER_LIST"    "$sauve/list" 2>/dev/null
    [[ "$key_avant"  -eq 1 ]] && cp -p "$DOCKER_KEYRING" "$sauve/key"  2>/dev/null
    prov_journal_note found_apt_repo \
      "$([[ "$list_avant" -eq 1 ]] && echo "$DOCKER_LIST")" \
      "$([[ "$key_avant"  -eq 1 ]] && echo "$DOCKER_KEYRING")"
  fi

  ensure_dir "$(dirname "$DOCKER_KEYRING")" 0755 root:root || return 1
  if [[ "$(sha256sum "$DOCKER_KEYRING" 2>/dev/null | awk '{print $1}')" != "$DOCKER_GPG_SHA256" ]]; then
    fetch_verify "$url/gpg" "$DOCKER_GPG_SHA256" "$DOCKER_KEYRING" 0644 || return 1
  fi

  arch="$(arch_tag debian)"
  [[ -n "$arch" ]] || { p_fail "arch non épinglée pour le dépôt docker : « $(arch_tag raw) » (attendu amd64 ou arm64)"; return 1; }
  write_atomic "$DOCKER_LIST" 0644 "root:root" <<EOF || return 1
deb [arch=$arch signed-by=$DOCKER_KEYRING] $url $codename stable
EOF
  # `update` ciblé : la source vient d'apparaître, `apt_ensure` ne trouverait rien sans lui.
  # LE JOURNAL TRANCHE, ET C'EST LE MECANISME QUI EXISTE DEJA POUR EXACTEMENT CETTE QUESTION. Il ne
  # decrit pas ce qu'on a le DROIT de poser (c'est le metier de la table) mais ce que CETTE passe A
  # pose sur CETTE machine. `uninstall` ne retire donc que ce que le journal revendique — jamais le
  # depot d'un operateur qui l'avait avant nous.
  # ⚠ SEULEMENT CE QU'ON A CREE. Le journal autorise le retrait ; y inscrire un fichier qui etait
  # deja la ferait retirer par `uninstall` le depot docker d'un operateur — un objet que LCARS n'a
  # jamais pose et dont d'autres choses sur sa machine dependent.
  local -a poses=()
  [[ "$list_avant" -eq 0 ]] && poses+=("$DOCKER_LIST")
  [[ "$key_avant"  -eq 0 ]] && poses+=("$DOCKER_KEYRING")
  [[ "${#poses[@]}" -gt 0 ]] && prov_journal_note posed_apt_repo "${poses[@]}"

  if ! run_quiet apt-get update -o Dir::Etc::sourcelist="$DOCKER_LIST" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"; then
    # Le rollback rend la machine a son etat d'AVANT — ce qui veut dire restaurer ce qui existait et
    # n'effacer que ce qu'on a cree. La version precedente effacait les deux fichiers dans tous les
    # cas, en annoncant « la machine repart comme avant » : sur une machine qui les portait deja,
    # c'etait la phrase qui decrivait le moins bien ce qui venait de se passer.
    local restaure=""
    if [[ "$list_avant" -eq 1 && -f "$sauve/list" ]]; then
      cp -p "$sauve/list" "$DOCKER_LIST" && restaure="$DOCKER_LIST"
    else
      rm -f "$DOCKER_LIST"
    fi
    if [[ "$key_avant" -eq 1 && -f "$sauve/key" ]]; then
      cp -p "$sauve/key" "$DOCKER_KEYRING" && restaure="${restaure:+$restaure }$DOCKER_KEYRING"
    else
      rm -f "$DOCKER_KEYRING"
    fi
    [[ -n "$sauve" ]] && rm -rf "$sauve"
    if [[ -n "$restaure" ]]; then
      p_fail "dépôt docker : « apt-get update » refuse la source — ce que CETTE passe a écrit est annulé, et ce que la machine portait déjà est RESTAURÉ ($restaure). Voir la sortie ci-dessus pour la cause"
    else
      p_fail "dépôt docker : « apt-get update » refuse la source — RETIRÉE, ainsi que sa clé ($DOCKER_LIST, $DOCKER_KEYRING) ; ni l'une ni l'autre n'était là avant cette passe. Voir la sortie ci-dessus pour la cause"
    fi
    return 1
  fi
  [[ -n "$sauve" ]] && rm -rf "$sauve"
  return 0
}

# ⚠ LA CONVERGENCE PORTE SUR CE QU'IL FAUT AJOUTER, JAMAIS SUR CE QU'IL FAUT ENLEVER. Si
# `LINUX_PACKAGES` a été posé à une passe précédente et que docker répond maintenant, la liste ne
# les contient plus — le `check` ne les réclame donc pas, et l'`apply` ne les retire pas. Retirer un
# paquet que l'opérateur pouvait vouloir est exactement la faute que le journal existe pour
# empêcher, et ce n'est pas à cette fonction de la commettre.
effective_packages() {
  printf '%s\n' "${PACKAGES[@]}"
  if [[ "${PROV_SUBSTRATE:-}" == "linux" ]] && ! docker_endpoint >/dev/null 2>&1; then
    printf '%s\n' "${LINUX_PACKAGES[@]}"
  fi
  return 0
}

probe_bwrap() {
  # stderr NON étouffé : l'échec réel de bwrap doit être verbeux (doctrine), et surtout un
  # as_human impossible (doctor lancé par un user tiers) doit dire SA cause — le 2>/dev/null
  # transformait « je ne peux pas sonder » en faux « le sandbox échoue ».
  as_human bwrap --ro-bind / / --unshare-all --die-with-parent /bin/true
}

# ⚠ `check` NE SONDE PAS LE DÉPÔT DOCKER, ET C'EST UN CHOIX. Il pourrait constater que la clé ou la
# source manquent — mais le dépôt n'est pas un état-cible, c'est un MOYEN d'installer les paquets,
# et ces paquets-là, `check` les sonde déjà. Une seconde ligne de dérive pour le même fait ferait
# deux verdicts d'une seule cause. Ce que ça coûte, et il faut le savoir : quand `apply` échouera à
# poser le dépôt, le `check` d'avant aura annoncé une dérive ordinaire. L'échec, lui, sera bruyant
# et nommé — c'est le contrat du rail, et il vaut mieux qu'un doctor qui prédit l'avenir.
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
  # Capturer puis tester, pas `printf | grep -qx` (DI-13) : sous `pipefail`, `grep -q` ferme le
  # tuyau au premier match et le producteur rend 141.
  if [[ " ${pkgs[*]} " == *" docker-ce "* ]]; then
    ensure_docker_repo || verdict_apply
  fi
  apt_ensure "${pkgs[@]}" || verdict_apply
  if probe_bwrap; then
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
