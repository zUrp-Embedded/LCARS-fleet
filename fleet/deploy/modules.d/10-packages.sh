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
#   socat       — DEUX CONSOMMATEURS, ET ILS N'ONT RIEN À VOIR L'UN AVEC L'AUTRE. Le second est
#                 `bin/lcars`, qui parle à la socket unix de `lcars-catalogue` : bash n'ouvre pas de
#                 socket unix (`/dev/tcp` est TCP seul), donc sans socat le geste
#                 `lcars catalogue install` n'a pas de transport. Il retombe sur `nc -U`, présent
#                 ici aussi, mais ce repli dépend de l'implémentation de nc. Cette ligne existe pour
#                 que retirer socat le jour où les pods n'en ont plus besoin ne casse pas l'autre
#                 consommateur en silence.
#
#                 LE RELAIS D'EGRESS DU POD, et il est load-bearing : le sanctuaire n'a AUCUN
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
  # ─── LA CONSOLE WEB, ET ELLE ENTRE ICI PARCE QUE LES DEUX RAILS L'OBTIENNENT ENFIN PAREIL ────
  # ⚠ `ttyd` ÉTAIT HORS DE CETTE LISTE, ET LA RAISON ÉCRITE EN FACE A CESSÉ D'ÊTRE VRAIE.
  # `62-runtime-helpers` disait : « `ttyd` n'est pas empaqueté par Debian (l'image le récupère en
  # binaire statique pinné par sha256) ; Ubuntu 26.04 sert `ttyd 1.7.7-4build1`, `universe`, la
  # version exacte que le Dockerfile épingle. Deux mécanismes pour un même fait. » Le second
  # mécanisme est parti avec bookworm : l'image bâtit sur Ubuntu 26.04 et demande le paquet, comme
  # ici. Un fait, un mécanisme, une liste — et `deploy_manifest.bats` peut enfin l'exiger des deux
  # rails, ce qu'il ne pouvait pas faire d'un binaire téléchargé.
  # ⚠ `universe`, pas `main` : sur une image serveur où ce composant serait fermé, `apt_ensure`
  # échoue en le disant. C'est le bon endroit pour l'apprendre — avant la console noire.
  ttyd
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
#                un paquet docker dans la distro y fabriquerait un SECOND daemon, concurrent du premier.
#   · `docker` — on est DANS le conteneur ; il n'y a rien à installer et rien à monter.
#
# ⚖ USER 2026-08-23 : « on prend l'upstream par apt ». C'est un DÉPÔT TIERS, et c'est la seule
# exception à la règle « tout vient de la distro » que ce fichier applique à `gh` et
# `git-filter-repo` — donc elle s'écrit ici plutôt que de se découvrir dans le code.
#
# CE QUE L'UPSTREAM ACHÈTE, ET CE N'EST PAS LE NUMÉRO DE VERSION. `docker.io` n'existe que chez
# Canonical : sur une Debian, sur une dérivée, le paquet n'a ni le même nom ni le même contenu.
# `docker-ce` est le MÊME empaquetage partout, donc une machine LCARS a le même docker quelle que
# soit sa distro — et surtout le même que celui que la majorité des postes portent déjà, ce qui
# supprime la classe entière des conflits `docker.io` / `docker-ce`.
#
# CE QU'ON PAIE, dit sans arrondir : une délégation de confiance permanente à
# `download.docker.com`, et une dépendance à la publication d'une suite pour le nom de code de la
# distro. ⚖ USER, sur les deux : « si canonical se fait percer, c'est pas LCARS qui m'inquiétera le
# plus ce jour-là », et « on peut faire confiance à canonical et docker.org pour ne pas sortir une
# LTS sans docker viable dessus ».
#
# ⚠ IL N'Y A PAS DE REPLI VERS `docker.io`, ET C'EST DÉLIBÉRÉ. Retomber sur un autre empaquetage
# quand l'upstream manque poserait un docker que l'opérateur n'a pas demandé, sous un nom qui
# entrera en conflit avec celui qu'il installera ensuite. Ce qu'on doit, c'est un refus qui NOMME la
# cause — « la suite <codename> n'existe pas chez Docker » — au lieu d'un `apt-get update` qui
# échoue trois lignes plus loin sur une erreur de dépôt que personne ne rattachera à ce choix.
LINUX_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

# La clé et la source, dérivées — jamais câblées. `$ID` vaut `ubuntu` ou `debian` et désigne le
# chemin du dépôt ; `$VERSION_CODENAME` désigne la suite. Écrire l'un des deux en dur ferait un
# fichier qui ment sur toute autre machine que celle où il a été écrit.
DOCKER_KEYRING="${LCARS_DOCKER_KEYRING:-/etc/apt/keyrings/docker.asc}"
DOCKER_LIST="${LCARS_DOCKER_LIST:-/etc/apt/sources.list.d/docker.list}"
# ⚠ LA CLÉ EST ÉPINGLÉE PAR SHA256, ET CE N'EST PAS UN PIN DE VERSION. Le paragraphe d'en-tête dit
# qu'on ne pin rien de ce que la distro livre — vrai, et sans rapport : ici on ne fige pas une
# version, on fige une ANCRE DE CONFIANCE. Un `curl | trust` accorderait à jamais la signature de ce
# que le réseau a rendu ce jour-là ; le sha dit laquelle on a acceptée, et le jour où Docker la
# tourne, `fetch_verify` s'arrête au lieu de faire confiance à autre chose sans le dire.
# La MÊME clé sert les deux dépôts (ubuntu et debian) — vérifié : même sha256 aux deux URL. Un pin
# par distro serait deux vérités pour un fait.
DOCKER_GPG_SHA256="${LCARS_DOCKER_GPG_SHA256:-1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570}"

os_field() { # os_field <clef de /etc/os-release>
  [[ -r /etc/os-release ]] || return 1
  ( . /etc/os-release 2>/dev/null; printf '%s' "${!1:-}" )
}

# Pose le dépôt upstream — et REFUSE en nommant la cause plutôt que de poser une source cassée.
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
  # ⚠ « LA SUITE N'EXISTE PAS » ET « JE N'ATTEINS PAS LE RÉSEAU » NE SONT PAS LE MÊME FAIT, et les
  # confondre envoie l'opérateur vérifier chez Docker une suite qui y est. `curl` distingue les deux
  # par son code : 22 = HTTP >= 400 (la suite manque), tout le reste = DNS, proxy, timeout, TLS.
  # D'où l'absence de `2>/dev/null` — le diagnostic de curl est la seule chose qui sépare les deux
  # causes, et l'étouffer les rend identiques à l'écran.
  # `-L` : sans lui `-f` laisse passer un 301, la sonde validerait une redirection que `apt` ne suit
  # pas. Mesuré le 2026-08-23 : aucune redirection aujourd'hui — c'est la classe qu'on ferme, pas un
  # symptôme observé.
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

  ensure_dir "$(dirname "$DOCKER_KEYRING")" 0755 root:root || return 1
  # ⚠ `fetch_verify` N'EST PAS IDEMPOTENT, ET C'EST SON CONTRAT : il télécharge, vérifie, pose et
  # COMPTE un changement, à chaque appel. L'idempotence appartient à l'appelant — `15-toolchain` la
  # tient de la même façon, en ne l'appelant que quand la version posée diffère du pin. Sans cette
  # garde, une machine où docker est installé mais dont le daemon ne répond pas (service coupé)
  # re-télécharge la clé et sort `POSÉ` à chaque passe : un rail qui se dit convergé et compte un
  # changement à chaque tour.
  if [[ "$(sha256sum "$DOCKER_KEYRING" 2>/dev/null | awk '{print $1}')" != "$DOCKER_GPG_SHA256" ]]; then
    fetch_verify "$url/gpg" "$DOCKER_GPG_SHA256" "$DOCKER_KEYRING" 0644 || return 1
  fi

  arch="$(dpkg --print-architecture)"
  write_atomic "$DOCKER_LIST" 0644 "root:root" <<EOF || return 1
deb [arch=$arch signed-by=$DOCKER_KEYRING] $url $codename stable
EOF
  # `update` ciblé : la source vient d'apparaître, `apt_ensure` ne trouverait rien sans lui.
  #
  # ⚠ ET S'IL REFUSE, ON RETIRE CE QU'ON VIENT DE POSER. C'est le seul chemin d'échec qui laissait
  # quelque chose derrière lui, et c'est le plus cher : une source apt vers un dépôt que la machine
  # refuse ne casse pas ici — elle casse au prochain `apt-get update` de l'opérateur, des mois plus
  # tard, sur une erreur que personne ne rattachera à LCARS. Les trois gardes ci-dessus refusent
  # AVANT d'écrire ; celui-ci doit défaire, sinon la propriété « un refus ne laisse rien » n'est
  # vraie que sur les chemins faciles.
  if ! run_quiet apt-get update -o Dir::Etc::sourcelist="$DOCKER_LIST" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"; then
    rm -f "$DOCKER_LIST" "$DOCKER_KEYRING"
    p_fail "dépôt docker : « apt-get update » refuse la source — RETIRÉE, ainsi que sa clé ($DOCKER_LIST, $DOCKER_KEYRING) ; la machine repart comme avant, voir la sortie ci-dessus pour la cause"
    return 1
  fi
  return 0
}

# La liste EFFECTIVE de ce passage — une seule fonction, lue par `check` ET par `apply`, pour que
# les deux ne puissent pas répondre différemment sur le même substrat.
#
# ─── LA SONDE, PAS LE NOM DU PAQUET ─────────────────────────────────────────────────────────────
#
# ⚠ CETTE FONCTION NE TESTAIT QUE LE SUBSTRAT, et sur une machine qui a déjà docker c'était faux.
# La majorité des postes Linux ont déjà docker — par l'upstream ou par la distro. Un `dpkg -s` qui
# échoue déclenche alors une installation dont la machine n'a pas besoin, et deux empaquetages
# concurrents entrent en conflit : au mieux apt refuse, au pire il retire le Docker de l'opérateur.
#
# ⚠ ET LA SONDE N'EST JAMAIS UN NOM DE PAQUET, MÊME MAINTENANT QUE LE RAIL POSE `docker-ce`.
# Sonder ce nom-là reproduirait la même faute déplacée d'un empaquetage à l'autre : une machine qui
# tient son docker d'ailleurs se verrait poser un dépôt tiers dont elle n'a aucun besoin. La doctrine est déjà écrite dans
# `install.sh` : « ON SONDE UN ENDPOINT QUI RÉPOND, PAS UN BINAIRE […] une distro sans intégration
# activée n'a NI /usr/bin/docker NI /var/run/docker.sock, et le daemon répond quand même ».
# `docker_endpoint` rend 0 quand un daemon a répondu ; c'est la seule question qui compte.
#
# ⚠ LA CONVERGENCE PORTE SUR CE QU'IL FAUT AJOUTER, JAMAIS SUR CE QU'IL FAUT ENLEVER. Si
# `LINUX_PACKAGES` a été posé à une passe précédente et que docker répond maintenant, la liste ne
# les contient plus — le `check` ne les réclame donc pas, et l'`apply` ne les retire pas. Retirer un
# paquet que l'opérateur pouvait vouloir est exactement la faute que le journal existe pour
# empêcher, et ce n'est pas à cette fonction de la commettre.
#
# ⚠ ET LE POINT D'INJECTION EST ICI, PAS DANS UN DES DEUX VERBES. `deploy_manifest.bats` porte déjà
# « check et apply lisent la MÊME liste » : une condition posée dans `check()` seul les ferait
# diverger, et le doctor réclamerait à vie un paquet que l'apply n'installe pas.
effective_packages() {
  printf '%s\n' "${PACKAGES[@]}"
  if [[ "${PROV_SUBSTRATE:-}" == "linux" ]] && ! docker_endpoint >/dev/null 2>&1; then
    printf '%s\n' "${LINUX_PACKAGES[@]}"
  fi
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

# ⚠ `check` NE SONDE PAS LE DÉPÔT DOCKER, ET C'EST UN CHOIX. Il pourrait constater que la clé ou la
# source manquent — mais le dépôt n'est pas un état-cible, c'est un MOYEN d'installer les paquets,
# et ces paquets-là, `check` les sonde déjà. Une seconde ligne de dérive pour le même fait ferait
# deux verdicts d'une seule cause. Ce que ça coûte, et il faut le savoir : quand `apply` échouera à
# poser le dépôt, le `check` d'avant aura annoncé une dérive ordinaire. L'échec, lui, sera bruyant
# et nommé — c'est le contrat du rail, et il vaut mieux qu'un doctor qui prédit l'avenir.
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
  # ⚠ LE DÉPÔT SE POSE SEULEMENT S'IL SERT, ET LA CONDITION EST LA LISTE ELLE-MÊME. `effective_packages`
  # ne contient les paquets docker que lorsque AUCUN daemon n'a répondu ; poser la source en dehors de
  # ce cas ajouterait un dépôt tiers sur une machine qui a déjà docker — précisément ce que ce module
  # refuse de faire depuis qu'il sonde un endpoint au lieu d'un nom de paquet.
  if printf '%s\n' "${pkgs[@]}" | grep -qx 'docker-ce'; then
    ensure_docker_repo || verdict_apply
  fi
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
