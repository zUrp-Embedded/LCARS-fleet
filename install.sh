#!/usr/bin/env bash
# SOURCE: install.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-14
# STATUS: l'installeur — il mesure, montre, délègue
#
#     install.sh — l'installeur de LCARS-FLEET.
#
#     Il mesure la machine, montre ce qu'il va faire, puis délègue. Le système n'est modifié qu'après
#     le bilan, et ce script ne demande jamais sudo lui-même. Pipé, ou avec --from-release, il
#     télécharge d'abord le kit de la version, le vérifie et le détare dans ~/.lcars/kits/.
#
#       (sans option)   LCARS tourne dans un conteneur Docker. Rien hors de Docker.
#       --workstation   LCARS s'installe dans ce système : une distribution WSL2, ou une machine
#                       Linux dédiée déclarée par LCARS_ALLOW_ANY_HOST=1. Ce mode possède /etc,
#                       /opt/lcars, des groupes et des paquets ; un terrain se refait, il ne se
#                       désinstalle pas.
#       --bench         l'installeur monte lui-même la forge, son runner CI et un compte de
#                       démonstration. Sans ce drapeau, une forge existante est requise
#                       (FORGE_BASE_URL).
#       --check         mesure et affiche, ne modifie rien (--doctor est le même drapeau).
#       --dry-run       tout jusqu'au bilan, puis la commande qui serait exécutée.
#                       Pipés sans kit déjà posé, --check et --dry-run s'arrêtent avant de télécharger.
#       --from-release  depuis un clone : installer la dernière version publiée du dépôt au lieu de
#                       l'arbre courant (son installeur, vérifié par sa somme, est rejoué).
#       --repo URL      le dépôt dont les releases sont tirées (défaut : celui de cette version).
#       --substrate S   le substrat attendu : wsl, linux ou docker ; un substrat que la mesure
#                       contredit est refusé.
#       --forge-project N   la base des projets compose (défaut lcars) : N-forge, N-runner, N-fleet.
#       --port-forge N  le port de la forge montée par --bench (défaut 21000).
#       --port-deck N   le port du deck (défaut 20999).
#       --port-ssh N    le port SSH du conteneur (défaut 2222) ; sans objet avec --workstation.
#       --env FICHIER   passé au provisionnement et à la mesure (--workstation).
#       --human USER, --only MODULE   passés au provisionnement (--workstation).
#       --version       la version de ce script.
#       -h, --help      cette aide.
#
#     Relancer est toujours sûr : l'état est celui du système, mesuré à chaque passage.
#
# --- END HEADER ---

set -euo pipefail

LCARS_DOOR_VERSION=""              # @@DOOR_VERSION@@ le tag de la release — door-gen.sh l'ecrit ici

main() {
declare -a ARGS=("$@")
VERSION_DITE="${LCARS_DOOR_VERSION:-non publiée}"

if [[ -n "${NO_COLOR:-}" ]] || [[ "${PROV_COLOR:-}" == "0" ]] \
   || { [[ -z "${PROV_COLOR:-}" ]] && [[ ! -t 1 ]]; }; then
  AMBER=''; W=''; G=''; R=''; N=''
else
  AMBER=$'\033[38;5;214m'; W=$'\033[1;37m'; G=$'\033[1;32m'; R=$'\033[1;31m'; N=$'\033[0m'
fi

if [[ "$EUID" -eq 0 ]]; then
  echo ""
  echo "  ${R}Cet installeur ne se lance pas en root.${N}"
  echo "  Il mesure et délègue ; le mode --workstation demande sudo lui-même, une fois."
  exit 1
fi

# BASH_SOURCE n'est pas lié quand bash lit sur stdin (curl | bash) : sans fichier, pas d'arbre
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PORTE_CMD="bash ${BASH_SOURCE[0]}"
else
  SCRIPT_DIR=""
  PORTE_CMD="curl -fsSL <install.sh> | bash -s --"
fi

REPO_URL="https://github.com/zurp-embedded/LCARS-fleet.git"
# Les constantes d'une version : vides dans le gabarit, écrites par deploy/lib/door-gen.sh sur les
# lignes marquées @@DOOR_…@@, et sur elles seules.
DOOR_BASE=""                       # @@DOOR_BASE@@ <forge>/<owner>/<repo>/releases/download/<tag>
MINISIGN_PUBKEY=""                 # @@DOOR_PUBKEY@@ la clé publique minisign des artefacts
DOOR_IMAGE=""                      # @@DOOR_IMAGE@@ l'image publiée de cette version (registre/image:tag), vide sans publication
sums() { cat <<'SUMS'              # @@DOOR_SUMS_BEGIN@@ « <sha256>  <artefact> », un par ligne
SUMS
}                                  # @@DOOR_SUMS_END@@

MODE=container
FROM_RELEASE=0; DRY_RUN=0; DOCTOR_MODE=0; WITH_BENCH=0; REPO_DONNE=0
FORCED_SUBSTRATE=""
declare -a PASSTHRU=()       # au délégué du mode --workstation, tel quel
declare -a MESURE=()         # au préflight initial : ce qui change la mesure
declare -a PROJET_PORTS=()   # au préflight et au délégué : le projet et les ports

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workstation)    MODE=workstation; shift ;;
    --bench)          WITH_BENCH=1; shift ;;
    --check|--doctor) DOCTOR_MODE=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --from-release)   FROM_RELEASE=1; shift ;;
    --repo)           REPO_URL="${2:?--repo attend une URL}"; REPO_DONNE=1; shift 2 ;;
    --substrate)      FORCED_SUBSTRATE="${2:?--substrate attend une valeur}"; shift 2 ;;
    --port-forge|--port-deck|--port-ssh)
                      PROJET_PORTS+=("$1" "${2:?$1 attend un port}"); shift 2 ;;
    --forge-project)  PROJET_PORTS+=("$1" "${2:?$1 attend un nom}"); shift 2 ;;
    # 00-preflight lit ce que --env pose (la forge fournie, la déclaration) ; l'humain et la sélection ne pèsent que sur l'apply
    --env)            PASSTHRU+=("$1" "${2:?$1 attend un fichier}"); MESURE+=("$1" "$2"); shift 2 ;;
    --human|--only)   PASSTHRU+=("$1" "${2:?$1 attend une valeur}"); shift 2 ;;
    --version) echo "$VERSION_DITE"; exit 0 ;;
    --help|-h)
      if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        sed -n '/^#     install.sh — /,/^#     Relancer/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,5\}//'
      else
        echo "install.sh $VERSION_DITE — l'installeur de LCARS-FLEET."
        echo "  (sans option) conteneur Docker · --workstation dans ce système · --bench la forge montée"
        echo "  --check (--doctor) · --dry-run · --from-release · --repo URL · --substrate S"
        echo "  --forge-project N · --port-forge N · --port-deck N · --port-ssh N · --env F · --human U · --only M"
        echo "  --version · -h, --help"
      fi
      exit 0 ;;
    *) echo "Option inconnue : $1 — --help" >&2; exit 1 ;;
  esac
done
case "${FORCED_SUBSTRATE:-wsl}" in
  wsl|docker|linux) ;;
  *) echo "  ${R}--substrate $FORCED_SUBSTRATE : inconnu (wsl|docker|linux).${N}"; exit 1 ;;
esac
if [[ "$MODE" == "container" ]]; then
  [[ "${#PASSTHRU[@]}" -eq 0 ]] \
    || { echo "  ${PASSTHRU[0]} est un drapeau du mode --workstation : il pilote le provisionnement, que le conteneur n'appelle pas." >&2; exit 1; }
else
  [[ " ${PROJET_PORTS[*]:-} " != *" --port-ssh "* ]] \
    || { echo "  --port-ssh est le port SSH du conteneur : l'installation dans ce système n'en publie aucun." >&2; exit 1; }
fi
[[ "$WITH_BENCH" -eq 1 || " ${PROJET_PORTS[*]:-} " != *" --port-forge "* ]] \
  || { echo "  --port-forge n'a d'objet qu'avec --bench : sans lui la forge est fournie (FORGE_BASE_URL), son port n'est pas celui de ce projet." >&2; exit 1; }
PASSTHRU+=(${PROJET_PORTS[@]+"${PROJET_PORTS[@]}"})
MODE_FLAG=""; [[ "$MODE" != "workstation" ]] || MODE_FLAG=" --workstation"

# ─── outils ───────────────────────────────────────────────────────────────────────────────────
FACTS_FILE=""
fait() { sed -n "s/^$1=//p" "$FACTS_FILE" | tail -1; }
stop() { # stop <ligne…> — le bilan s'arrête là, rien n'est fait
  echo ""; local l; for l in "$@"; do echo "  $l"; done; echo ""; exit 1
}
sortie_dite() { # sortie_dite <argv…> — ce que --dry-run rend à la place d'un exec
  echo ""; echo "  ${W}--dry-run${N} : rien n'est fait. La commande serait :"
  printf '   '; printf ' %q' "$@"; echo ""; echo ""
  exit 0
}
fetch() { # fetch <url> <fichier>
  local proto='=https'; [[ -z "${LCARS_DOOR_INSECURE_HTTP:-}" ]] || proto='=http,https'
  curl --proto "$proto" -fsSL "$1" -o "$2"
}
sum_of() { local s n; while read -r s n; do [[ "$n" == "$1" ]] && { echo "$s"; return 0; }; done < <(sums); return 1; }
assets_for() { # assets_for <arch> -> le kit de cette version pour cette arch, par convention de nom
  local v="$LCARS_DOOR_VERSION" s n
  while read -r s n; do [[ "$n" == lcars-fleet-"$v"-*-"$1".tar.gz ]] && { echo "$n"; return 0; }; done < <(sums)
  return 0
}
signature() { # signature <artefact> — minisign si l'outil est là ; sinon le dire, jamais taire
  local a="$1" f="$KITS_DIR/$1"
  [[ -n "$MINISIGN_PUBKEY" ]] || { echo "  ! provenance non vérifiée (sha256 seul) : ce script ne porte pas de clé publique" >&2; return 0; }
  command -v minisign >/dev/null 2>&1 || { echo "  ! minisign absent : provenance non vérifiée (sha256 seul)" >&2; return 0; }
  [[ -f "$f.minisig" ]] || fetch "$BASE/$a.minisig" "$f.minisig" \
    || { rm -f "$f.minisig"; echo "  ${R}$a.minisig introuvable, et ce script attend une signature — rien n'est posé.${N}"; return 1; }
  minisign -Vq -P "$MINISIGN_PUBKEY" -m "$f" \
    || { rm -f "$f" "$f.minisig"; echo "  ${R}signature de $a invalide (minisign) — rien n'est posé.${N}"; return 1; }
  echo "  $a : signature vérifiée (minisign)"
}
obtenir() { # obtenir <artefact> <sha256> — dans KITS_DIR, vérifié ; rc 2 s'il était déjà là
  local a="$1" want="$2" f="$KITS_DIR/$1" got deja=0
  if [[ -f "$f" && "$(sha256sum "$f" | cut -d' ' -f1)" == "$want" ]]; then
    echo "  $a : déjà là, sha256 vérifié"; deja=1
  else
    fetch "$BASE/$a" "$f" || { rm -f "$f"; echo "  ${R}$BASE/$a : téléchargement en échec — rien n'est posé.${N}"; return 1; }
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || { rm -f "$f"; echo "  ${R}sha256 de $a : attendu $want, obtenu $got — artefact altéré ou incomplet, rien n'est posé.${N}"; return 1; }
    echo "  $a : téléchargé, sha256 vérifié"
  fi
  printf '%s  %s\n' "$want" "$a" > "$f.sha256"
  signature "$a" || return 1
  [[ "$deja" -eq 0 ]] || return 2
}
delegue_dit() { # la commande du délégué, en mots, pour un --dry-run ou un --check qui n'a pas d'arbre
  if [[ "$MODE" == "workstation" ]]; then echo "deploy/workstation up --from <kit>"
  elif [[ "$WITH_BENCH" -eq 1 ]]; then echo "deploy/container --bench up"
  else echo "deploy/container up"
  fi
}
derniere_release() { # le script du dépôt n'a pas de table : il rejoue l'installeur de la dernière release, vérifié par sa somme
  local url="${REPO_URL%.git}/releases/latest/download" dest="$HOME/.lcars/kits/installeur-derniere-release" a
  local -a suite=()
  for a in "${ARGS[@]}"; do [[ "$a" == --from-release ]] || suite+=("$a"); done
  if [[ "$DRY_RUN" -eq 1 || "$DOCTOR_MODE" -eq 1 ]]; then
    echo "  Ce script n'est pas celui d'une release : rien n'est téléchargé. La commande serait :"
    echo "    curl -fsSL $url/install.sh | bash -s --${suite[*]:+ ${suite[*]}}"
    exit 0
  fi
  command -v curl >/dev/null 2>&1 || { echo "  ${R}curl est absent — apt install curl${N}"; exit 1; }
  mkdir -p "$dest"
  if ! fetch "$url/install.sh" "$dest/install.sh" || ! fetch "$url/install.sh.sha256" "$dest/install.sh.sha256"; then
    rm -f "$dest/install.sh" "$dest/install.sh.sha256"
    echo "  ${R}$url : l'installeur de la dernière release ou sa somme sont introuvables — rien n'est posé.${N}"
    echo "  Une forge qui ne sert pas releases/latest se prend par le script d'une version : <dépôt>/releases/download/<version>/install.sh"
    exit 1
  fi
  ( cd "$dest" && sha256sum -c --quiet --strict install.sh.sha256 >/dev/null 2>&1 ) \
    || { rm -f "$dest/install.sh"; echo "  ${R}l'installeur de la dernière release ne correspond pas à sa somme publiée — rien n'est posé.${N}"; exit 1; }
  echo "  source : dernière release de ${REPO_URL%.git} — installeur vérifié par sa somme"
  exec bash "$dest/install.sh" ${suite[@]+"${suite[@]}"}
}
source_release() { # le kit de cette version dans ~/.lcars/kits/<version>/, vérifié, détaré → c'est l'arbre
  local arch asset somme rc=0
  [[ -n "$DOOR_BASE" ]] || derniere_release
  arch="$(uname -m)"
  asset="$(assets_for "$arch")"
  [[ -n "$asset" ]] || {
    echo "  ${R}aucun kit $LCARS_DOOR_VERSION pour $arch dans la table de ce script.${N}"
    exit 1
  }
  somme="$(sum_of "$asset")"
  KITS_DIR="$HOME/.lcars/kits/$LCARS_DOOR_VERSION"
  echo "  ${W}source${N} : release ${W}$LCARS_DOOR_VERSION${N} — $BASE → $KITS_DIR/  (arch $arch)"
  printf '    %-56s sha256 %s\n' "$asset" "$somme"
  if [[ "$DRY_RUN" -eq 1 || "$DOCTOR_MODE" -eq 1 ]]; then
    if [[ ! -x "$KITS_DIR/lcars_install/deploy/provision" ]]; then
      echo "  ${W}$([[ "$DRY_RUN" -eq 1 ]] && echo --dry-run || echo --check)${N} : rien n'est téléchargé. Le préflight vit dans le kit, qui n'est pas là."
      echo "  La commande serait : $(delegue_dit)"
      exit 0
    fi
    echo "  kit déjà posé, rien n'est téléchargé"
    SCRIPT_DIR="$KITS_DIR/lcars_install"; return 0
  fi
  if [[ "$BASE" != https://* ]]; then
    [[ -n "${LCARS_DOOR_INSECURE_HTTP:-}" ]] || { echo "  ${R}$BASE n'est pas https — ce script ne télécharge qu'en https (LCARS_DOOR_INSECURE_HTTP=1 pour un banc local).${N}"; exit 1; }
    echo "  ${AMBER}LCARS_DOOR_INSECURE_HTTP=1 : $BASE — transport en clair, banc seulement.${N}" >&2
  fi
  command -v curl >/dev/null 2>&1 || { echo "  ${R}curl est absent — apt install curl${N}"; exit 1; }
  mkdir -p "$KITS_DIR"
  obtenir "$asset" "$somme" || rc=$?
  [[ "$rc" -ne 1 ]] || exit 1
  # un détarage interrompu reste dans son échafaudage : seul un arbre complet porte le nom lcars_install
  if [[ "$rc" -ne 2 || ! -x "$KITS_DIR/lcars_install/deploy/provision" ]]; then
    local echafaudage="$KITS_DIR/.lcars_install.partiel"
    rm -rf "$echafaudage"; mkdir -p "$echafaudage"
    tar -xzf "$KITS_DIR/$asset" -C "$echafaudage" && [[ -d "$echafaudage/lcars_install" ]] \
      || { rm -rf "$echafaudage"; echo "  ${R}le kit ne se détare pas — rien n'est posé.${N}"; exit 1; }
    rm -rf "$KITS_DIR/lcars_install"
    mv "$echafaudage/lcars_install" "$KITS_DIR/lcars_install"
    rm -rf "$echafaudage"
  fi
  SCRIPT_DIR="$KITS_DIR/lcars_install"
}

# ─── 1. le bandeau ────────────────────────────────────────────────────────────────────────────
cat <<EOF

${AMBER}     ____________________________________________________
    /                                                    \\
   /             ${W}LCARS FLEET - FEDERATION DATABASE${N}        ${AMBER}\\
  |   ________   __________________________________________\\
  |  |  2026  |  | ${N}LCARS-FLEET — installeur${AMBER}
  |  |________|  | ${N}version $VERSION_DITE · runtime Elixir/OTP${AMBER}
  |   ________   | ${N}licence AGPL-3${AMBER}
  |  |  v2.0  |  |__________________________________________
  |  |________|  \\__________________________________________\\
  |                                                         /
   \\    ${W}"To boldly go where no code has gone before..."${AMBER}    /
    \\_____________________________________________________/${N}

EOF

# ─── 2. la source : l'arbre d'où tout se joue ─────────────────────────────────────────────────
if [[ "$REPO_DONNE" -eq 0 && -n "$DOOR_BASE" ]]; then BASE="$DOOR_BASE"
else BASE="${REPO_URL%.git}/releases/download/$LCARS_DOOR_VERSION"
fi
KITS_DIR=""; PROVENANCE=""
if [[ "$FROM_RELEASE" -eq 1 || -z "$SCRIPT_DIR" || ! -e "$SCRIPT_DIR/deploy/provision" ]]; then
  source_release; PROVENANCE=release
elif [[ -e "$SCRIPT_DIR/.git" ]]; then
  PROVENANCE=source
else
  PROVENANCE=kit
fi
PROVISION="$SCRIPT_DIR/deploy/provision"
DELEGUE="$SCRIPT_DIR/deploy/$MODE"
arbre_incomplet() { stop "${R}L'arbre est incomplet : $1.${N}" "Ce n'est pas docker qui manque, c'est la source."; }
[[ -x "$PROVISION" ]] || arbre_incomplet "$PROVISION absent ou non exécutable"
[[ -x "$DELEGUE" ]]   || arbre_incomplet "$DELEGUE absent ou non exécutable"
[[ -r "$SCRIPT_DIR/deploy/installer-constants.env" ]] \
  || arbre_incomplet "constantes de l'installeur introuvables : $SCRIPT_DIR/deploy/installer-constants.env"
# les constantes de l'installeur se lisent dans l'arbre, comme une donnée ; avant lui, seule l'aide en cite
constante() { sed -n "s/^$1=//p" "$SCRIPT_DIR/deploy/installer-constants.env"; }
RACINE="$(constante PROV_ROOT)"
case "$PROVENANCE" in
  source)  SOURCE_LIGNE="clone git · branche $(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo inconnue) · commit $(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo inconnu)" ;;
  kit)     SOURCE_LIGNE="archive (kit) · révision $(cat "$SCRIPT_DIR/$(constante PROV_SOURCE_STAMP)" 2>/dev/null || echo inconnue)" ;;
  release) SOURCE_LIGNE="release $LCARS_DOOR_VERSION · kit dans $SCRIPT_DIR" ;;
esac

# ─── 3. le préflight : une seule mesure, celle du provisionnement ─────────────────────────────
FACTS_FILE="$(mktemp "${TMPDIR:-/tmp}/lcars-facts.XXXXXX" 2>/dev/null)" \
  || stop "${R}Aucun fichier temporaire ne se crée dans ${TMPDIR:-/tmp}${N} — le préflight y écrit ses faits. Corriger TMPDIR, puis relancer."
trap 'rm -f "$FACTS_FILE"' EXIT
PREFLIGHT_RC=0
PREFLIGHT_OUT="$(env PROV_FACTS_FILE="$FACTS_FILE" \
  "$PROVISION" doctor --only 00-preflight ${FORCED_SUBSTRATE:+--substrate "$FORCED_SUBSTRATE"} \
  ${PROJET_PORTS[@]+"${PROJET_PORTS[@]}"} ${MESURE[@]+"${MESURE[@]}"} 2>&1)" || PREFLIGHT_RC=$?

[[ -n "$(fait docker)" ]] || {
  echo "  ${R}Le préflight n'a rendu aucun fait — provision doctor n'a pas tourné.${N}"
  printf '%s\n' "$PREFLIGHT_OUT" | sed 's/^/    /'
  exit 1
}
SUBSTRATE="$(fait substrat)"

# ─── 4. le bilan ──────────────────────────────────────────────────────────────────────────────
go() { [[ "${1:-}" =~ ^[0-9]+$ ]] && awk -v m="$1" 'BEGIN { printf "%d", (m + 512) / 1024 }' || printf '?'; }
ou() { [[ -n "$1" ]] && printf '%s' "$1" || printf '?'; }
case "$SUBSTRATE" in
  wsl)    TERRAIN="sous WSL2" ;;
  linux)  TERRAIN="Linux dédié" ;;
  docker) TERRAIN="dans un conteneur" ;;
esac
SYSTEMD="systemd actif"; [[ "$(fait systemd)" == "oui" ]] || SYSTEMD="sans systemd"
GROUPES="$(fait groupes | tr ',' '\n' | { grep -xE 'sudo|docker|fleet' || true; } | paste -sd, - | sed 's/,/, /g')"
[[ -n "$GROUPES" ]] || GROUPES="ni sudo, ni docker, ni fleet"

echo "  ${W}Source${N}     $SOURCE_LIGNE"
echo ""
echo "  ${W}Système${N}    $(ou "$(fait distro)") $(fait distro_version) $TERRAIN · noyau $(ou "$(fait noyau)") · $SYSTEMD"
echo "             $(ou "$(fait arch)") · $(ou "$(fait cpu)") cœurs · $(go "$(fait ram_mb)") Go de RAM · $(go "$(fait disque_mb)") Go libres sur /"
echo "             utilisateur $(ou "$(fait utilisateur)") · groupes ${GROUPES:-?}"

DOCKER_OK=0
case "$(fait docker)" in
  oui)    DOCKER_OK=1
          echo "  ${W}Docker${N}     serveur $(ou "$(fait docker_server)") · $(ou "$(fait docker_flavor)") · $(ou "$(fait docker_host)")"
          [[ "$(fait compose)" != "non" ]] || echo "             ${R}compose absent${N} — $(fait compose_why)" ;;
  refuse) echo "  ${W}Docker${N}     ${R}accès refusé${N} — $(fait docker_why)" ;;
  *)      if [[ "$SUBSTRATE" == "linux" && "$MODE" == "workstation" ]]; then
            echo "  ${W}Docker${N}     absent · sera posé par l'installation (docker-ce, dépôt download.docker.com)"
          else
            echo "  ${W}Docker${N}     ${R}absent${N} — $(fait docker_why)"
          fi ;;
esac

# jq lit l'API de la forge depuis l'hôte du conteneur ; dans ce système, 10-packages le pose
OUTILS_REQUIS="git curl jq"; [[ "$MODE" != "workstation" ]] || OUTILS_REQUIS="git curl sudo"
OUTILS_MANQUANTS=""
for t in $OUTILS_REQUIS; do
  case "$(fait "$t")" in oui|root) ;; *) OUTILS_MANQUANTS="${OUTILS_MANQUANTS:+$OUTILS_MANQUANTS, }$t" ;; esac
done
if [[ -z "$OUTILS_MANQUANTS" ]]; then
  echo "  ${W}Outils${N}     ${OUTILS_REQUIS// /, } présents"
else
  echo "  ${W}Outils${N}     ${R}manquants : $OUTILS_MANQUANTS${N}"
fi

FORGE_ETAT=""   # montee | fournie | injoignable | aucune
if [[ "$WITH_BENCH" -eq 1 ]]; then
  FORGE_ETAT=montee
  echo "  ${W}Forge${N}      montée par l'installeur avec son runner CI (--bench)"
elif [[ -n "$(fait forge_fournie)" ]]; then
  if [[ "$(fait forge_joignable)" == "oui" ]]; then
    FORGE_ETAT=fournie
    echo "  ${W}Forge${N}      fournie : $(fait forge_fournie) · joignable"
  else
    FORGE_ETAT=injoignable
    echo "  ${W}Forge${N}      fournie : $(fait forge_fournie) · ${R}injoignable${N}"
  fi
else
  FORGE_ETAT=aucune
  echo "  ${W}Forge${N}      ${R}aucune${N} : FORGE_BASE_URL n'est pas définie et --bench n'a pas été passé"
fi
PORTS_PRIS=""; ports_ligne=""; PORT_DECK=""; PORT_SSH=""
for p in forge deck ssh; do
  v="$(fait "port_$p")"; n="${v%% *}"; etat="${v#* }"; [[ "$v" == *" "* ]] || etat=""
  [[ "$p" != "deck" ]] || PORT_DECK="$n"; [[ "$p" != "ssh" ]] || PORT_SSH="$n"
  # le port de la forge n'est pas à ce projet quand elle est fournie ; le port SSH n'est publié que par le conteneur
  [[ "$p" == "forge" && "$FORGE_ETAT" != "montee" ]] && continue
  [[ "$p" == "ssh" && "$MODE" == "workstation" ]] && continue
  case "$etat" in
    libre)  ports_ligne="${ports_ligne:+$ports_ligne · }$n ($p) libre" ;;
    nous*)  ports_ligne="${ports_ligne:+$ports_ligne · }$n ($p) publié par ce projet" ;;
    pris*)  ports_ligne="${ports_ligne:+$ports_ligne · }$n ($p) ${R}${etat^^}${N}"; PORTS_PRIS="${PORTS_PRIS:+$PORTS_PRIS ; }$p $n $etat" ;;
    *)      ports_ligne="${ports_ligne:+$ports_ligne · }$(ou "$n") ($p) ${etat:-état inconnu}" ;;
  esac
done
echo "             projet $(ou "$(fait projet)") · ports $ports_ligne"
PROJET_ROUGE=""; [[ "$MODE" != "container" ]] || PROJET_ROUGE="$R"
[[ -z "$(fait projet_pris)" ]] || echo "             ${PROJET_ROUGE}projet déjà présent sur ce daemon : $(fait projet_pris)${N}"
echo ""

# ─── 5. ce qui arrête, avant toute grille ─────────────────────────────────────────────────────
[[ -z "$OUTILS_MANQUANTS" ]] || stop "${R}Outils manquants : $OUTILS_MANQUANTS.${N}" "Les installer, puis relancer. Le rapport du préflight :" "$(printf '%s\n' "$PREFLIGHT_OUT" | sed 's/^/    /')"
if [[ "$MODE" == "workstation" ]]; then
  case "$SUBSTRATE" in
    wsl) ;;
    linux)
      [[ "$(fait consent)" == "env" ]] || stop \
        "${R}Linux natif sans déclaration.${N} L'installation dans ce système possède la machine (/etc, $RACINE," \
        "des groupes, des comptes) et ne se désinstalle pas : elle est réservée à une machine dédiée." \
        "Pour la déclarer dédiée, à chaque passe :  LCARS_ALLOW_ANY_HOST=1 $PORTE_CMD --workstation" \
        "Sinon, le conteneur ne touche à rien :      $PORTE_CMD" ;;
    *) stop "${R}--workstation ne s'installe que dans une distribution WSL2 ou sur une machine Linux dédiée.${N}" \
            "Ici (substrat $SUBSTRATE), le conteneur :  $PORTE_CMD" ;;
  esac
fi
if [[ "$DOCKER_OK" -eq 0 ]]; then
  if [[ "$(fait docker)" == "refuse" ]]; then
    stop "${R}Docker répond mais refuse cet utilisateur.${N}" "$(fait docker_why)"
  elif [[ "$SUBSTRATE" == "wsl" ]]; then
    stop "${R}Docker est absent.${N} Les deux installations en ont besoin : la forge est un conteneur." \
         "Sous WSL, activer l'intégration WSL de Docker Desktop pour cette distribution, puis relancer."
  elif [[ "$MODE" == "container" ]]; then
    stop "${R}Docker est absent.${N} Le conteneur ne l'installe pas." \
         "L'installer, ou donner la machine à l'installation dans le système :  LCARS_ALLOW_ANY_HOST=1 $PORTE_CMD --workstation"
  fi
else
  # le daemon qui a répondu au préflight, pas un DOCKER_HOST de l'environnement qu'il a écarté
  DOCKER_HOST_VU="$(fait docker_host)"
  if [[ -n "$DOCKER_HOST_VU" ]]; then export DOCKER_HOST="$DOCKER_HOST_VU"; else unset DOCKER_HOST; fi
fi
# l'installation dans ce système est ce que le préflight juge : un plancher en dérive (RAM, disque, arch,
# WSL1…) ou un canal illisible arrêterait son apply, il arrête ici avant le choix
if [[ "$MODE" == "workstation" && "$PREFLIGHT_RC" -ne 0 ]]; then
  stop "${R}Le préflight refuse ce terrain pour l'installation dans ce système.${N} Ce qu'il constate :" \
       "$(printf '%s\n' "$PREFLIGHT_OUT" | grep -E '^(DRIFT|FAIL|ERREUR) ' | sed 's/^/    /' || printf '%s\n' "$PREFLIGHT_OUT" | sed 's/^/    /')"
fi
if [[ "$MODE" == "container" && "$(fait compose)" == "non" ]]; then
  stop "${R}Docker répond, mais compose est absent.${N} Le conteneur se pose par docker compose." \
       "$(fait compose_why)" \
       "Poser le plugin compose de docker (paquet docker-compose-plugin), puis relancer."
fi
case "$FORGE_ETAT" in
  aucune) stop "${R}Les deux installations ont besoin d'une forge et de son runner CI. Aucune n'est indiquée.${N}" \
               "Relancer en précisant laquelle :" \
               "  $PORTE_CMD$MODE_FLAG --bench                       une forge jetable, montée par l'installeur" \
               "  FORGE_BASE_URL=https://… $PORTE_CMD$MODE_FLAG      une forge existante" ;;
  injoignable) stop "${R}La forge fournie ne répond pas : $(fait forge_fournie)${N}" "Vérifier l'URL et que l'API répond (/api/v1/version), puis relancer." ;;
esac
[[ -z "$PORTS_PRIS" ]] || stop "${R}Un port demandé est déjà tenu : $PORTS_PRIS.${N}" \
  "Déplacer avec --port-forge, --port-deck ou --port-ssh, ou libérer le port."
if [[ "$MODE" == "container" && -n "$(fait projet_pris)" ]]; then
  stop "${R}Un projet compose « $(fait projet_pris) » existe déjà sur ce daemon.${N}" \
       "Choisir un autre nom :  $PORTE_CMD --forge-project <nom>   — ou détruire l'autre :  deploy/container -p <projet> reset"
fi

# ─── 6. le mode, et sa grille ─────────────────────────────────────────────────────────────────
BASE_PROJET="$(ou "$(fait projet)")"
if [[ "$MODE" == "container" ]]; then
  cat <<EOF
  ${W}Installation en conteneur${N} — LCARS tourne dans Docker, la distribution
  n'est pas modifiée : aucun paquet, aucun compte, rien dans /etc ni /usr.
    Modifie    Docker : un conteneur et deux volumes au projet $BASE_PROJET-fleet, le magasin $BASE_PROJET-fleet-*
    Requiert   docker · la forge (ci-dessus)
    Espace     ~3 Go · durée ~15 min · ports $(ou "$PORT_DECK") (deck), $(ou "$PORT_SSH") (ssh)
    Retour     deploy/container -p $BASE_PROJET-fleet reset, 30 s
  Pour installer dans ce système à la place :  $PORTE_CMD --workstation

EOF
else
  if [[ "$SUBSTRATE" == "wsl" ]]; then
    MODIFIE="/etc/wsl.conf, $RACINE, des groupes et des comptes de service, des paquets apt, ~/.config, ~/.docker et ~/.claude de l'utilisateur"
    RETOUR="aucun désinstalleur : la distribution se recrée (wsl --unregister <distro>)"
  else
    MODIFIE="$RACINE, des groupes et des comptes de service, des paquets apt, ~/.claude de l'utilisateur, docker-ce si aucun daemon ne répond"
    RETOUR="aucun désinstalleur : la machine se réinstalle"
  fi
  cat <<EOF
  ${W}Installation dans ce système${N} — LCARS s'installe sur cette distribution, la fleet
  tourne sous un compte de service. C'est le mode pour travailler sur le code.
    Modifie    $MODIFIE
    Requiert   sudo, demandé une fois au démarrage · docker · la forge (ci-dessus)
    Espace     ~2 Go · durée ~10 min
    Retour     $RETOUR
  Pour installer en conteneur à la place :  $PORTE_CMD

EOF
fi

if [[ "$DOCTOR_MODE" -eq 1 ]]; then
  echo "  ${W}--check${N} : rien n'est fait. Pour un déploiement existant : deploy/workstation doctor · deploy/container status"
  echo ""
  exit 0
fi

# ─── 7. l'instance, quand on va la posséder ───────────────────────────────────────────────────
CONSENTI=0
if [[ "$MODE" == "workstation" ]]; then
  SIGNAUX=""
  apt="$(fait apt_installs)"
  [[ -z "$apt" || "$apt" == "inconnu" ]] || SIGNAUX="paquets installés après sa création : $apt"
  humains="$(fait comptes_humains)"
  [[ "$humains" != *,* ]] || SIGNAUX="${SIGNAUX:+$SIGNAUX
    }comptes humains : $humains"
  if [[ -n "$SIGNAUX" && "$(fait channel)" == "aucun" ]]; then
    echo "  Cette instance porte des traces d'usage :"
    echo "    $SIGNAUX"
    if [[ "$SUBSTRATE" != "wsl" ]]; then
      echo "  (machine déclarée dédiée : à titre d'information)"
    elif [[ "$DRY_RUN" -eq 1 ]]; then
      echo "  (--dry-run : la question serait posée ici)"
    else
      echo "  L'installation prend possession de l'instance. Une instance vierge est le prérequis."
      if { exec 3< /dev/tty; } 2>/dev/null; then
        printf '  Continuer ? [O/n] '
        ans=""
        read -r ans <&3 || stop "Rien n'a été fait."
        exec 3<&-
        case "$ans" in
          ""|o|O|oui|y|Y|yes) CONSENTI=1 ;;
          n|N|non|no) stop "Rien n'a été fait." ;;
          *) stop "Réponse « $ans » non comprise — rien n'a été fait." ;;
        esac
      else
        echo "  (sans terminal, l'installation continue : le terrain est jetable)"
      fi
    fi
    echo ""
  fi
fi

# ─── 8. la sortie : un seul exec, vers le délégué du mode ─────────────────────────────────────
if [[ "$MODE" == "workstation" ]]; then
  if [[ "$WITH_BENCH" -eq 1 ]]; then
    export LCARS_BENCH=1 PROV_FORGE_MONTEE=1
    export LCARS_BUILTIN_HUMAN="${LCARS_BUILTIN_HUMAN:-lcars}"
  fi
  CMD=("$DELEGUE" up ${FORCED_SUBSTRATE:+--substrate "$FORCED_SUBSTRATE"} ${PASSTHRU[@]+"${PASSTHRU[@]}"})
  [[ "$PROVENANCE" != "release" ]] || CMD+=(--from "$KITS_DIR/lcars_install")   # le kit déjà détaré et vérifié, pas le tar une seconde fois
  RAPPEL="Installation dans ce système — deploy/workstation up"
elif [[ "$WITH_BENCH" -eq 1 ]]; then
  CMD=("$DELEGUE" ${PROJET_PORTS[@]+"${PROJET_PORTS[@]}"} --bench up)
  RAPPEL="Installation en conteneur, avec le banc — deploy/container --bench up"
else
  CMD=("$DELEGUE" ${PROJET_PORTS[@]+"${PROJET_PORTS[@]}"} up)
  RAPPEL="Installation en conteneur — deploy/container up"
fi
# une release en conteneur nomme son image ; absente du daemon, elle est tirée avant le up, qui ne tire jamais
PRE=()
if [[ "$MODE" != "workstation" && "$PROVENANCE" == "release" && -n "$DOOR_IMAGE" ]]; then
  export LCARS_IMAGE="$DOOR_IMAGE"
  if ! "$(fait docker_bin)" image inspect "$DOOR_IMAGE" >/dev/null 2>&1; then
    PRE=("$DELEGUE" pull)
    echo "  l'image de cette version n'est pas sur ce daemon : elle sera tirée d'abord ($DOOR_IMAGE)"
  fi
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  [[ "${#PRE[@]}" -eq 0 ]] || { printf '  --dry-run : d'"'"'abord'; printf ' %q' "${PRE[@]}"; echo ""; }
  sortie_dite "${CMD[@]}"
fi
echo "  ${G}$RAPPEL${N}"
echo ""
# la réponse à « Continuer ? » est déjà le consentement : une seconde invite ne décide rien de plus
if [[ "$CONSENTI" -eq 0 ]]; then
  echo "  ${G}    ▶  Entrée pour continuer${N}  /  ${R}Ctrl+C pour annuler${N}"
  echo ""
  if { exec 3< /dev/tty; } 2>/dev/null; then
    read -r _ <&3 || stop "Rien n'a été fait."
    exec 3<&-
  else
    echo "  Pas de terminal : l'installation continue."
  fi
fi
rm -f "$FACTS_FILE"   # exec ne rejoue pas le trap
[[ "${#PRE[@]}" -eq 0 ]] || "${PRE[@]}" || exit 1
exec "${CMD[@]}"

}

# { main "$@"; } et non main "$@" : un flux coupé au milieu de « main » donnerait à bash une
# commande valide ; l'accolade non fermée est une erreur de syntaxe, jamais une commande.
# RIEN NE DOIT SUIVRE CETTE LIGNE.
{ main "$@"; }
