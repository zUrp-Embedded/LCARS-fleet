#!/usr/bin/env bash
# SOURCE: install.sh
# AUTHOR: DrDree
# STARDATE: 2026-09-14
# STATUS: l'installeur — il mesure sans privilège, montre, marque la pause, puis agit ; root une fois, par sudo
#
#     install.sh — l'installeur de LCARS-FLEET.
#
#     Il mesure la machine sans privilège, montre ce qu'il va faire, marque une pause (Entrée pour
#     continuer, Ctrl+C pour annuler ; sans terminal, il continue en le disant), puis agit. Avant
#     cette pause, seul ~/.lcars/kits/ reçoit quelque chose. Le script d'une release, pipé ou avec
#     --from-release, y télécharge d'abord le kit de sa version, le vérifie et le détare : la mesure
#     vit dans le kit.
#
#       (sans option)   LCARS tourne dans un conteneur Docker, sans root. Rien hors de Docker ; jq est
#                       requis sur cette machine : le banc lit l'API de sa forge, et « deploy/container
#                       forge-apply » dérive le roster d'une forge fournie. Une instance déjà
#                       présente n'est pas réinstallée : le refus nomme sa mise à jour.
#       --workstation   LCARS s'installe dans ce système : une distribution WSL2, ou une machine
#                       Linux dédiée déclarée par LCARS_ALLOW_ANY_HOST=1. Ce mode possède /etc,
#                       la racine de LCARS, des groupes, des comptes et des paquets ; un terrain se
#                       refait, il ne se désinstalle pas. Après la pause, l'installeur se relance une
#                       fois par sudo. Depuis un clone, root exécute ce checkout tel quel : ce canal
#                       fait confiance au checkout. Pour un kit, root copie l'archive dans un dossier
#                       à lui, en revérifie la somme inscrite dans ce script, la détare et joue
#                       l'installeur de cette copie. Root décide lui-même des refus qui protègent la
#                       machine (déclaration, canal, chaque port de ce projet, projets compose),
#                       mesure l'écriture sous la racine, puis pose. Sans sudo, ou sans terminal
#                       quand sudo demande un mot de passe, il s'arrête.
#       --bench         l'installeur monte lui-même la forge, son runner CI et un compte de
#                       démonstration. Sans ce drapeau, une forge existante est requise (FORGE_BASE_URL).
#       --check         mesure et affiche, ne modifie rien (--doctor est le même drapeau). Un refus
#                       du bilan sort en 1 avant la grille ; avec --workstation, la mesure se complète
#                       en root, par sudo, et un terrain qu'elle refuse en est un.
#       --dry-run       tout jusqu'à la commande qui serait exécutée ; avec --workstation, par sudo,
#                       pour mesurer entier. Rien n'est exécuté.
#                       Pipés sans kit déjà posé, --check et --dry-run s'arrêtent avant de télécharger.
#       --from-release  depuis un clone : télécharge l'installeur de la dernière release du dépôt,
#                       le vérifie contre sa somme publiée et le rejoue avec les mêmes options.
#       --repo URL      le dépôt dont les releases sont tirées (défaut : celui de cette version).
#       --substrate S   le substrat attendu : wsl, linux ou docker ; un substrat que la mesure
#                       contredit est refusé.
#       --forge-project N   la base des projets compose (défaut lcars) : N-forge, N-runner, N-fleet.
#       --port-forge N  le port de la forge montée, avec --bench seulement.
#       --port-deck N   le port du deck.
#       --port-ssh N    le port SSH du conteneur ; refusé avec --workstation.
#                       Le bilan affiche chaque port retenu, défaut compris.
#       --env FICHIER   passé au provisionnement et à la mesure (--workstation).
#       --human USER, --only MODULE   passés au provisionnement (--workstation).
#       --version       la version de ce script.
#       -h, --help      cette aide.
#
#     La relance en root ne reçoit aucune variable : les choix de l'opérateur y passent en options,
#     que l'installeur écrit lui-même ; aucune ne dispense root de sa mesure.
#       --docker-host URL    le daemon docker que la mesure sans privilège a vu répondre.
#       --linux-dedie   la déclaration LCARS_ALLOW_ANY_HOST=1.
#       --forge URL, --forge-publique URL   FORGE_BASE_URL et FORGE_PUBLIC_URL.
#       --humain-demo NOM    LCARS_BUILTIN_HUMAN, l'humain de démonstration du banc (défaut lcars).
#       --forge-admin-reset  PROV_FORGE_ADMIN_RESET=1 : un mot de passe neuf pour l'administrateur
#                       de la forge du poste.
#       --apres-pause   la grille et la pause ont eu lieu avant sudo ; sans elle, l'installeur lancé
#                       en root mesure, montre et marque la pause lui-même avant d'agir.
#
#     Relancer reprend depuis la mesure : l'état est celui du système, lu à chaque passage.
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

# BASH_SOURCE n'est pas lié quand bash lit sur stdin (curl | bash) : sans fichier, pas d'arbre.
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PORTE_TIRAGE=""
  PORTE_BASH="bash ${BASH_SOURCE[0]}"
else
  SCRIPT_DIR=""
  PORTE_TIRAGE="curl -fsSL <install.sh> | "   # l'adresse de la porte, écrite une fois la base de la release connue
  PORTE_BASH="bash -s --"
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
APRES_PAUSE=0                # la relance en root : la grille et la pause ont eu lieu sans privilège
declare -a PASSTHRU=()       # au délégué du mode --workstation, tel quel
declare -a MESURE=()         # à la mesure : ce qui la change
declare -a PROJET_PORTS=()   # à la mesure et au délégué : le projet et les ports
declare -a COMMUNS=()        # ce que les deux modes acceptent : un remède le rejoue
declare -a SSH_ARGS=()       # --port-ssh, que le mode --workstation refuse
declare -a SUITE=()          # à la relance en root : tout sauf ce qui a servi à tirer le kit

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workstation)    MODE=workstation; SUITE+=("$1"); shift ;;
    --bench)          WITH_BENCH=1; COMMUNS+=("$1"); SUITE+=("$1"); shift ;;
    --check|--doctor) DOCTOR_MODE=1; COMMUNS+=("$1"); SUITE+=("$1"); shift ;;
    --dry-run)        DRY_RUN=1; COMMUNS+=("$1"); SUITE+=("$1"); shift ;;
    --from-release)   FROM_RELEASE=1; COMMUNS+=("$1"); shift ;;
    --repo)           REPO_URL="${2:?--repo attend une URL}"; REPO_DONNE=1; COMMUNS+=("$1" "$2"); shift 2 ;;
    --substrate)      FORCED_SUBSTRATE="${2:?--substrate attend une valeur}"; COMMUNS+=("$1" "$2"); SUITE+=("$1" "$2"); shift 2 ;;
    --port-forge|--port-deck)
                      PROJET_PORTS+=("$1" "${2:?$1 attend un port}"); COMMUNS+=("$1" "$2"); SUITE+=("$1" "$2"); shift 2 ;;
    --port-ssh)       PROJET_PORTS+=("$1" "${2:?$1 attend un port}"); SSH_ARGS+=("$1" "$2"); shift 2 ;;
    --forge-project)  PROJET_PORTS+=("$1" "${2:?$1 attend un nom}"); COMMUNS+=("$1" "$2"); SUITE+=("$1" "$2"); shift 2 ;;
    # 00-preflight lit ce que --env pose (la forge fournie, la déclaration) ; l'humain et la sélection ne pèsent que sur l'apply
    --env)            PASSTHRU+=("$1" "${2:?$1 attend un fichier}"); MESURE+=("$1" "$2"); SUITE+=("$1" "$2"); shift 2 ;;
    --human|--only)   PASSTHRU+=("$1" "${2:?$1 attend une valeur}"); SUITE+=("$1" "$2"); shift 2 ;;
    --docker-host)    export DOCKER_HOST="${2:?--docker-host attend une adresse}"; shift 2 ;;
    --linux-dedie)    export LCARS_ALLOW_ANY_HOST=1; shift ;;
    --forge)          export FORGE_BASE_URL="${2:?--forge attend une URL}"; shift 2 ;;
    --forge-publique) export FORGE_PUBLIC_URL="${2:?--forge-publique attend une URL}"; shift 2 ;;
    --humain-demo)    export LCARS_BUILTIN_HUMAN="${2:?--humain-demo attend un nom}"; shift 2 ;;
    --forge-admin-reset) export PROV_FORGE_ADMIN_RESET=1; shift ;;
    --apres-pause)    APRES_PAUSE=1; shift ;;
    --version) echo "$VERSION_DITE"; exit 0 ;;
    --help|-h)
      if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        sed -n '/^#     install.sh — /,/^#     Relancer/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,5\}//'
      else
        echo "install.sh $VERSION_DITE — l'installeur de LCARS-FLEET."
        echo "  (sans option) conteneur Docker · --workstation dans ce système, root par sudo après la pause · --bench la forge montée"
        echo "  --check (--doctor) · --dry-run · --from-release · --repo URL · --substrate S"
        echo "  --forge-project N · --port-forge N · --port-deck N · --port-ssh N · --env F · --human U · --only M"
        echo "  la relance en root : --docker-host URL · --linux-dedie · --forge URL · --forge-publique URL"
        echo "  · --humain-demo NOM · --forge-admin-reset · --apres-pause"
        echo "  --version · -h, --help"
      fi
      exit 0 ;;
    *) echo "Option inconnue : $1 — --help" >&2; exit 1 ;;
  esac
done
# en root, seul le mode --workstation joue : sa mesure root décide, quelle que soit la façon dont root a été obtenu
if [[ "$EUID" -eq 0 && "$MODE" != workstation ]]; then
  echo ""
  echo "  ${R}Cet installeur se lance sans root.${N}"
  echo "  Il mesure et montre sans privilège ; le mode --workstation demande sudo lui-même, une fois, après la pause."
  exit 1
fi
ROOT_DIT="root, par sudo, une fois après la pause"
[[ "$EUID" -ne 0 ]] || ROOT_DIT="root, déjà obtenu : la suite se joue sur place, après la pause"
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

# ─── outils ───────────────────────────────────────────────────────────────────────────────────
FACTS_FILE=""
fait() { sed -n "s/^$1=//p" "$FACTS_FILE" | tail -1; }
stop() { # stop <ligne…> — le bilan s'arrête là, rien n'est fait
  echo ""; local l; for l in "$@"; do echo "  $l"; done; echo ""; exit 1
}
# Une commande proposée est celle de l'opérateur, rejouée dans le mode visé : suivie telle quelle, elle ne
# ramène pas au refus qui l'a imprimée. Une variable se place devant PORTE_BASH : pipée, devant curl, bash
# ne la recevrait pas.
relance() { # relance <container|workstation> [VAR=valeur | drapeau…] → la ligne à relancer, ces ajouts compris
  local mode="$1" a; shift
  local -a vars=() recus=(${COMMUNS[@]+"${COMMUNS[@]}"})
  [[ "$mode" != workstation || "$SUBSTRATE" != linux ]] || vars+=(LCARS_ALLOW_ANY_HOST=1)
  [[ -z "${FORGE_BASE_URL:-}" ]] || vars+=("FORGE_BASE_URL=$FORGE_BASE_URL")
  if [[ "$mode" == workstation ]]; then recus=(--workstation ${recus[@]+"${recus[@]}"} ${PASSTHRU[@]+"${PASSTHRU[@]}"})
  else recus+=(${SSH_ARGS[@]+"${SSH_ARGS[@]}"})
  fi
  for a in "$@"; do [[ "$a" != *=* ]] || vars+=("$a"); done
  printf '%s%s%s' "$PORTE_TIRAGE" "${vars[*]:+${vars[*]} }" "$PORTE_BASH"
  [[ "${#recus[@]}" -eq 0 ]] || printf ' %q' "${recus[@]}"
  for a in "$@"; do [[ "$a" == *=* ]] || printf ' %s' "$a"; done
}
sortie_dite() { # sortie_dite <argv…> — ce que --dry-run rend à la place d'un exec
  echo ""; echo "  ${W}--dry-run${N} : rien n'est fait. La commande serait :"
  printf '   '; printf ' %q' "$@"; echo ""; echo ""
  exit 0
}
fetch() { # fetch <url> <fichier> — en https seul, sauf LCARS_DOOR_INSECURE_HTTP pour un banc local ; curl dit pourquoi il refuse
  local proto='=https'; [[ -z "${LCARS_DOOR_INSECURE_HTTP:-}" ]] || proto='=http,https'
  curl --proto "$proto" -fsSL --show-error "$1" -o "$2"
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
    echo "  $a : déjà là, sha256 vérifié, rien n'est téléchargé"; deja=1
  else
    fetch "$BASE/$a" "$f" || { rm -f "$f"; echo "  ${R}$BASE/$a : téléchargement en échec — rien n'est posé.${N}"; return 1; }
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || { rm -f "$f"; echo "  ${R}sha256 de $a : attendu $want, obtenu $got — artefact altéré ou incomplet, rien n'est posé.${N}"; return 1; }
    echo "  $a : téléchargé, sha256 vérifié"
  fi
  signature "$a" || return 1
  [[ "$deja" -eq 0 ]] || return 2
}
delegue_dit() { # la commande du délégué, en mots, pour un --dry-run ou un --check qui n'a pas d'arbre
  if [[ "$MODE" == "workstation" && "$DOCTOR_MODE" -eq 1 ]]; then echo "sudo sur l'installeur du kit vérifié, pour la mesure en root ; rien n'est posé"
  elif [[ "$MODE" == "workstation" ]]; then echo "sudo sur l'installeur du kit vérifié, puis deploy/workstation up"
  elif [[ "$WITH_BENCH" -eq 1 ]]; then echo "deploy/container --bench up"
  else echo "deploy/container up"
  fi
}
derniere_release() { # le script du dépôt n'a pas de table : il rejoue l'installeur de la dernière release, vérifié par sa somme
  local url="${REPO_URL%.git}/releases/latest/download" dest="$HOME/.lcars/kits/installeur-derniere-release" a
  local -a suite=() vars=()
  for a in "${ARGS[@]}"; do [[ "$a" == --from-release ]] || suite+=("$a"); done
  [[ -z "${LCARS_ALLOW_ANY_HOST:-}" ]] || vars+=(LCARS_ALLOW_ANY_HOST=1)
  [[ -z "${FORGE_BASE_URL:-}" ]] || vars+=("FORGE_BASE_URL=$FORGE_BASE_URL")
  if [[ "$DRY_RUN" -eq 1 || "$DOCTOR_MODE" -eq 1 ]]; then
    echo "  Ce script n'est pas celui d'une release : rien n'est téléchargé. La commande serait :"
    echo "    curl -fsSL $url/install.sh | ${vars[*]:+${vars[*]} }bash -s --${suite[*]:+ ${suite[*]}}"
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
source_release() { # le kit de cette version dans ~/.lcars/kits/<version>/, vérifié, détaré → l'arbre de la mesure sans privilège ; KIT_ARCHIVE et KIT_SOMME pour la relance en root
  local arch asset rc=0
  [[ -n "$DOOR_BASE" ]] || derniere_release
  arch="$(uname -m)"
  asset="$(assets_for "$arch")"
  [[ -n "$asset" ]] || {
    echo "  ${R}aucun kit $LCARS_DOOR_VERSION pour $arch dans la table de ce script.${N}"
    exit 1
  }
  KIT_SOMME="$(sum_of "$asset")"
  KITS_DIR="$HOME/.lcars/kits/$LCARS_DOOR_VERSION"
  KIT_ARCHIVE="$KITS_DIR/$asset"
  echo "  ${W}source${N} : release ${W}$LCARS_DOOR_VERSION${N} — $BASE → $KITS_DIR/  (arch $arch)"
  printf '    %-56s sha256 %s\n' "$asset" "$KIT_SOMME"
  if [[ "$DRY_RUN" -eq 1 || "$DOCTOR_MODE" -eq 1 ]]; then
    # rien ne se télécharge : un kit déjà posé se reprend quand son archive porte encore sa somme
    if [[ ! -x "$KITS_DIR/lcars_install/deploy/provision" || "$(sha256sum "$KIT_ARCHIVE" 2>/dev/null | cut -d' ' -f1)" != "$KIT_SOMME" ]]; then
      echo "  ${W}$([[ "$DRY_RUN" -eq 1 ]] && echo --dry-run || echo --check)${N} : rien n'est téléchargé. Le préflight vit dans le kit, qui n'est pas là, ou dont l'archive ne porte plus sa somme."
      echo "  La commande serait : $(delegue_dit)"
      exit 0
    fi
    # un kit déjà posé se dit une fois, par obtenir, qui revérifie son archive
  else
    command -v curl >/dev/null 2>&1 || { echo "  ${R}curl est absent — apt install curl${N}"; exit 1; }
    mkdir -p "$KITS_DIR"
  fi
  obtenir "$asset" "$KIT_SOMME" || rc=$?
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
mesurer() { # mesurer [option de provision…] — « provision mesure » de cet arbre : ses faits dans FACTS_FILE, son rapport dans PREFLIGHT_OUT, son code dans PREFLIGHT_RC
  FACTS_FILE="$(mktemp "${TMPDIR:-/tmp}/lcars-facts.XXXXXX" 2>/dev/null)" \
    || stop "${R}Aucun fichier temporaire ne se crée dans ${TMPDIR:-/tmp}${N} — la mesure y écrit ses faits. Corriger TMPDIR, puis relancer."
  trap 'rm -f "$FACTS_FILE"' EXIT
  PREFLIGHT_RC=0
  # la forge montée par --bench est celle du poste : son port est de ce projet, et root le vérifie
  local montee=""; [[ "$WITH_BENCH" -eq 0 ]] || montee=1
  PREFLIGHT_OUT="$(PROV_FORGE_MONTEE="$montee" "$SCRIPT_DIR/deploy/provision" mesure --faits "$FACTS_FILE" "$@" \
    ${FORCED_SUBSTRATE:+--substrate "$FORCED_SUBSTRATE"} ${PROJET_PORTS[@]+"${PROJET_PORTS[@]}"} ${MESURE[@]+"${MESURE[@]}"} 2>&1)" || PREFLIGHT_RC=$?
}
constat() { printf '%s\n' "$PREFLIGHT_OUT" | grep -E '^(DRIFT|FAIL|ERREUR) ' | sed 's/^/    /' || printf '%s\n' "$PREFLIGHT_OUT" | sed 's/^/    /'; }
# La relance d'un kit en root : root copie l'archive dans un dossier à lui, vérifie la copie contre la somme
# que ce script inscrit, la détare et joue l'installeur de la copie, qu'il retire à la sortie. L'arbre détaré
# sous le compte de l'utilisateur n'est jamais exécuté par root.
VERIFIE_KIT='set -eu
archive="$1" somme="$2"; shift 2
copie="$(mktemp -d -p "${TMPDIR:-/var/tmp}" lcars-kit.XXXXXX)"
trap "rm -rf -- \"$copie\"" EXIT
trap "exit 130" INT
trap "exit 143" TERM
cp -- "$archive" "$copie/kit.tar.gz"
printf "%s  %s\n" "$somme" "$copie/kit.tar.gz" | sha256sum -c --quiet --strict >/dev/null 2>&1 \
  || { echo "  $archive ne porte plus la somme inscrite dans l'\''installeur : root ne le détare pas, rien n'\''est fait ; relancer l'\''installeur." >&2; exit 1; }
tar --no-same-owner -xzf "$copie/kit.tar.gz" -C "$copie" \
  || { echo "  la copie de $archive ne se détare pas : rien n'\''est fait." >&2; exit 1; }
bash "$copie/lcars_install/install.sh" "$@"'
# Les choix de l'opérateur vivent dans ses variables ; sudo ne les transmet pas, la relance les reçoit en options.
choix_options() { # choix_options → CHOIX, les choix de l'opérateur en options
  CHOIX=()
  [[ -z "${LCARS_ALLOW_ANY_HOST:-}" ]] || CHOIX+=(--linux-dedie)
  [[ -z "${FORGE_BASE_URL:-}" ]] || CHOIX+=(--forge "$FORGE_BASE_URL")
  [[ -z "${FORGE_PUBLIC_URL:-}" ]] || CHOIX+=(--forge-publique "$FORGE_PUBLIC_URL")
  [[ -z "${LCARS_BUILTIN_HUMAN:-}" ]] || CHOIX+=(--humain-demo "$LCARS_BUILTIN_HUMAN")
  [[ -z "${PROV_FORGE_ADMIN_RESET:-}" ]] || CHOIX+=(--forge-admin-reset)
  return 0
}
relance_root() { # relance_root → exec sudo : sur ce fichier, ou pour un kit sur la copie vérifiée par root ; les choix en options
  local -a choix=()
  [[ "$DOCKER_OK" -eq 0 ]] || choix+=(--docker-host "$(fait docker_host)")
  choix_options
  choix+=(${CHOIX[@]+"${CHOIX[@]}"})
  rm -f "$FACTS_FILE"   # exec ne rejoue pas le trap
  # lancé en root, l'installeur a déjà montré et marqué la pause : la suite root se joue ici
  [[ "$EUID" -ne 0 ]] || suite_root
  [[ "$PROVENANCE" != release ]] \
    || exec sudo bash -c "$VERIFIE_KIT" lcars-kit "$KIT_ARCHIVE" "$KIT_SOMME" "${SUITE[@]}" --apres-pause ${choix[@]+"${choix[@]}"}
  exec sudo bash "$SCRIPT_DIR/install.sh" "${SUITE[@]}" --apres-pause ${choix[@]+"${choix[@]}"}
}
suite_root() { # la relance en root : la mesure root décide seule, puis le délégué sur ses faits
  mesurer
  [[ "$(fait phase)" == root ]] || {
    echo "  ${R}La mesure en root n'a rendu aucun fait : rien n'est fait. Ce que provision a dit :${N}"
    printf '%s\n' "$PREFLIGHT_OUT" | sed 's/^/    /'
    exit 1
  }
  local nom v etat
  v="$(fait echange)"
  case "${v##* }" in
    oui) etat="écriture et « mv --exchange » joués par root" ;;
    non) etat="${R}« mv --exchange » refusé${N}" ;;
    *)   etat="${R}non inscriptible par root${N}" ;;
  esac
  echo "  ${W}En root${N}    ${v% *} : $etat"
  for nom in forge deck; do
    v="$(fait "port_$nom")"
    [[ -n "$v" ]] || continue
    case "${v#* }" in
      libre)       etat="libre" ;;
      nous*)       etat="tenu par ${v#* nous }, de ce projet" ;;
      "pris par"*) etat="${R}tenu par ${v#* pris par }${N}" ;;
      *)           etat="${R}${v#* }${N}" ;;
    esac
    echo "             port ${v%% *} ($nom) $etat"
  done
  if [[ -n "$(fait projet_etranger)" ]]; then
    echo "             ${AMBER}projet compose d'un autre déploiement sur ce daemon : $(fait projet_etranger)${N}"
  elif [[ -n "$(fait projet_pris)" ]]; then
    echo "             projet compose de la forge de ce poste : $(fait projet_pris)"
  fi
  echo ""
  [[ "$PREFLIGHT_RC" -eq 0 ]] || stop "${R}La mesure en root refuse ce terrain.${N} Ce qu'elle constate :" "$(constat)"
  if [[ "$DOCTOR_MODE" -eq 1 ]]; then
    echo "  ${W}--check${N} : rien n'est fait. Pour un déploiement existant : deploy/workstation doctor"
    echo ""
    exit 0
  fi
  local -a suite=(${FORCED_SUBSTRATE:+--substrate "$FORCED_SUBSTRATE"} ${PASSTHRU[@]+"${PASSTHRU[@]}"} ${PROJET_PORTS[@]+"${PROJET_PORTS[@]}"})
  [[ "$WITH_BENCH" -eq 0 ]] || suite+=(--bench)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    # la commande dite refait sa mesure : les choix reçus en options la suivent, les faits de cette passe non
    choix_options
    # la copie vérifiée d'un kit est retirée à la sortie : son chemin ne se rejoue pas
    [[ "$SCRIPT_DIR" != */lcars-kit.??????/lcars_install ]] \
      || { echo "  Depuis le kit vérifié, dont root retire la copie à la sortie :"; DELEGUE="deploy/$MODE"; }
    sortie_dite "$DELEGUE" up ${suite[@]+"${suite[@]}"} ${CHOIX[@]+"${CHOIX[@]}"}
  fi
  # le délégué reçoit les faits et les retire à sa sortie
  trap - EXIT
  exec "$DELEGUE" up --faits "$FACTS_FILE" ${suite[@]+"${suite[@]}"}
}

# ─── 1. le bandeau, une fois : la relance en root ne le redit pas ─────────────────────────────
[[ "$EUID" -eq 0 ]] || cat <<EOF

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
# pipée, une commande proposée retire la porte à l'adresse d'où elle vient : celle de sa release
if [[ -n "$PORTE_TIRAGE" ]]; then
  if [[ -n "$LCARS_DOOR_VERSION" ]]; then PORTE_TIRAGE="curl -fsSL $BASE/install.sh | "
  else PORTE_TIRAGE="curl -fsSL ${REPO_URL%.git}/releases/latest/download/install.sh | "
  fi
fi
KITS_DIR=""; PROVENANCE=""
if [[ "$FROM_RELEASE" -eq 1 || -z "$SCRIPT_DIR" || ! -e "$SCRIPT_DIR/deploy/provision" ]]; then
  [[ "$EUID" -ne 0 ]] || stop "${R}Le script d'une release se lance sans root.${N}" \
    "Il pose le kit sous le compte de l'utilisateur ; après la pause, root joue une copie du kit qu'il vérifie lui-même."
  source_release; PROVENANCE=release
elif [[ -e "$SCRIPT_DIR/.git" ]]; then
  PROVENANCE=source
else
  PROVENANCE=kit
fi
DELEGUE="$SCRIPT_DIR/deploy/$MODE"
# le délégué ne part qu'après la pause : son absence se dit avant tout ; celle du runner, la mesure la dit
[[ -x "$DELEGUE" ]] || stop "${R}L'arbre est incomplet : $DELEGUE absent ou non exécutable.${N}" "Ce n'est pas docker qui manque, c'est la source."

[[ "$EUID" -ne 0 || "$APRES_PAUSE" -eq 0 ]] || suite_root

# ─── 3. la mesure sans privilège : une seule, celle du préflight ──────────────────────────────
# lancé en root sans la marque de relance, la grille se mesure comme sans privilège : root la montre, marque la pause, puis décide
if [[ "$EUID" -eq 0 ]]; then mesurer --sans-privilege; else mesurer; fi

[[ -n "$(fait docker)" ]] || {
  echo "  ${R}Le préflight n'a rendu aucun fait : rien n'est mesuré, rien n'est fait. Ce que provision a dit :${N}"
  printf '%s\n' "$PREFLIGHT_OUT" | sed 's/^/    /'
  exit 1
}
SUBSTRATE="$(fait substrat)"
RACINE="$(fait racine)"
case "$PROVENANCE" in
  source)  BRANCHE="$(git -C "$SCRIPT_DIR" symbolic-ref -q --short HEAD 2>/dev/null)" && BRANCHE="branche $BRANCHE" || BRANCHE="tête détachée"
           SOURCE_LIGNE="clone git · $BRANCHE · commit $(fait revision)" ;;
  kit)     SOURCE_LIGNE="archive (kit) · révision $(fait revision)" ;;
  release) SOURCE_LIGNE="release $LCARS_DOOR_VERSION · kit dans $SCRIPT_DIR" ;;
esac

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
if [[ "$MODE" == workstation ]]; then
  case "$(fait channel)" in
    aucun)    echo "             canal $(fait channel_tree) · machine jamais installée" ;;
    invalide) echo "             canal $(fait channel_tree) · ${R}canal de la machine illisible${N}" ;;
    *)        echo "             canal $(fait channel_tree) · machine installée par le canal $(fait channel)" ;;
  esac
fi
echo ""
echo "  ${W}Système${N}    $(ou "$(fait distro)") $(fait distro_version) $TERRAIN · noyau $(ou "$(fait noyau)") · $SYSTEMD"
echo "             $(ou "$(fait arch)") · $(ou "$(fait cpu)") cœurs · $(go "$(fait ram_mb)") Go de RAM · $(go "$(fait disque_mb)") Go libres pour $RACINE"
echo "             utilisateur $(ou "$(fait utilisateur)") · groupes ${GROUPES:-?}"

DOCKER_OK=0
case "$(fait docker)" in
  oui)    DOCKER_OK=1
          echo "  ${W}Docker${N}     serveur $(ou "$(fait docker_server)") · $(ou "$(fait docker_flavor)") · $(ou "$(fait docker_host)")"
          [[ -z "$(fait docker_host_ecarte)" ]] \
            || echo "             ${R}DOCKER_HOST=$(fait docker_host_ecarte) ne répond pas${N} : la socket par défaut sert à sa place"
          [[ "$(fait compose)" != "non" ]] || echo "             ${R}compose absent${N} — $(fait compose_why)" ;;
  refuse) echo "  ${W}Docker${N}     ${R}accès refusé${N} — $(fait docker_why)" ;;
  *)      if [[ "$SUBSTRATE" == "linux" && "$MODE" == "workstation" ]]; then
            echo "  ${W}Docker${N}     absent · sera posé par l'installation (docker-ce, dépôt download.docker.com)"
          else
            echo "  ${W}Docker${N}     ${R}absent${N} — $(fait docker_why)"
          fi ;;
esac

# en conteneur, le banc et forge-apply lisent l'API de la forge par jq depuis l'hôte ; dans ce système, 10-packages le pose
if [[ "$MODE" != workstation ]]; then OUTILS_REQUIS="git curl jq"; elif [[ "$EUID" -eq 0 ]]; then OUTILS_REQUIS="git curl"; else OUTILS_REQUIS="git curl sudo"; fi
OUTILS_MANQUANTS=""
for t in $OUTILS_REQUIS; do
  [[ "$(fait "$t")" == oui ]] || OUTILS_MANQUANTS="${OUTILS_MANQUANTS:+$OUTILS_MANQUANTS, }$t"
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
    pris*)  ports_ligne="${ports_ligne:+$ports_ligne · }$n ($p) ${R}${etat}${N}"; PORTS_PRIS="${PORTS_PRIS:+$PORTS_PRIS ; }$p $n $etat" ;;
    # un processus que ce compte ne voit pas : dans ce système, root dit s'il est de ce projet ; un conteneur ne publie pas un port tenu
    tenu)   if [[ "$MODE" == workstation ]]; then
              ports_ligne="${ports_ligne:+$ports_ligne · }$n ($p) tenu, propriétaire vérifié après sudo"
            else
              ports_ligne="${ports_ligne:+$ports_ligne · }$n ($p) ${R}tenu${N}"; PORTS_PRIS="${PORTS_PRIS:+$PORTS_PRIS ; }$p $n tenu par un processus que ce compte ne voit pas"
            fi ;;
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
      [[ "$(fait consent)" == env || "$(fait consent)" == posee ]] || stop \
        "${R}Linux natif sans déclaration.${N} L'installation dans ce système possède la machine (/etc, $RACINE," \
        "des groupes, des comptes) et ne se désinstalle pas : elle est réservée à une machine dédiée." \
        "Pour la déclarer dédiée, à chaque passe :  $(relance workstation)" \
        "Sinon, le conteneur ne touche à rien :  $(relance container)" ;;
    *) stop "${R}--workstation ne s'installe que dans une distribution WSL2 ou sur une machine Linux dédiée.${N}" \
            "Ici (substrat $SUBSTRATE), le conteneur :  $(relance container)" ;;
  esac
fi
if [[ "$DOCKER_OK" -eq 0 ]]; then
  if [[ "$(fait docker)" == "refuse" ]]; then
    stop "${R}Docker répond mais refuse cet utilisateur.${N}" "$(fait docker_why)"
  elif [[ "$SUBSTRATE" == "wsl" ]]; then
    stop "${R}Docker est absent.${N} Les deux installations en ont besoin : la forge est un conteneur." \
         "Sous WSL, activer l'intégration WSL de Docker Desktop pour cette distribution, puis relancer."
  elif [[ "$MODE" == "container" && "$SUBSTRATE" == "linux" && ( "$(fait channel)" == aucun || "$(fait channel)" == "$(fait channel_tree)" ) ]]; then
    stop "${R}Docker est absent.${N} Le conteneur ne l'installe pas : l'installer, puis relancer." \
         "Ou donner la machine à l'installation dans le système, qui le pose :  $(relance workstation)"
  elif [[ "$MODE" == "container" ]]; then
    stop "${R}Docker est absent.${N} Le conteneur ne l'installe pas : l'installer, puis relancer." "$(fait docker_why)"
  fi
else
  # le daemon qui a répondu au préflight, pas un DOCKER_HOST de l'environnement qu'il a écarté
  DOCKER_HOST="$(fait docker_host)"
  export DOCKER_HOST
fi
# l'installation dans ce système est ce que le préflight juge : un plancher en dérive (OS, arch, RAM,
# disque, WSL1) ou un canal illisible arrêterait son apply, il arrête ici avant le choix
if [[ "$MODE" == "workstation" && "$PREFLIGHT_RC" -ne 0 ]]; then
  stop "${R}Le préflight refuse ce terrain pour l'installation dans ce système.${N} Ce qu'il constate :" "$(constat)"
fi
if [[ "$MODE" == "container" && "$(fait compose)" == "non" ]]; then
  stop "${R}Docker répond, mais compose est absent.${N} Le conteneur se pose par docker compose." \
       "$(fait compose_why)" \
       "Poser le plugin compose de docker (paquet docker-compose-plugin), puis relancer."
fi
# une instance posée se met à jour par le délégué de cet arbre, qui la reconnaît à son compose ; sa conf
# (forge, secrets) n'est pas celle que ce bilan mesure : l'installeur ne la repose pas
BASE_PROJET="$(ou "$(fait projet)")"
if [[ "$MODE" == "container" && -n "$(fait projet_pris)" ]]; then
  IMAGE_DITE="${DOOR_IMAGE:-${LCARS_IMAGE:-}}"
  TIRER=""; [[ "$PROVENANCE" != release || -z "$DOOR_IMAGE" ]] || TIRER="LCARS_IMAGE=$DOOR_IMAGE deploy/container pull && "
  PROJET_DIT=""; [[ "${#PROJET_PORTS[@]}" -eq 0 ]] || PROJET_DIT="$(printf ' %q' "${PROJET_PORTS[@]}")"
  if [[ ",$(fait projet_pris)," != *",$BASE_PROJET-fleet,"* ]]; then
    stop "${R}Un projet compose « $(fait projet_pris) » existe déjà sur ce daemon, sous la base « $BASE_PROJET ».${N}" \
         "Choisir une autre base : la même commande, avec --forge-project <autre base>."
  elif [[ "$WITH_BENCH" -eq 1 ]]; then
    stop "${R}Le banc « $BASE_PROJET » existe déjà sur ce daemon ($(fait projet_pris)).${N} L'installeur ne pose pas un banc sur un autre." \
         "Le mettre à jour, la forge, ses jetons et les volumes gardés :" \
         "  ${TIRER}deploy/docker/bench/bench-swap-image.sh --image ${IMAGE_DITE:-<image>}$PROJET_DIT" \
         "Un second banc à côté : la même commande, avec --forge-project <autre base>."
  else
    stop "${R}L'instance « $BASE_PROJET-fleet » existe déjà sur ce daemon.${N} L'installeur ne pose pas une instance sur une autre." \
         "La mettre à jour, volumes et magasin gardés :" \
         "  ${TIRER}${IMAGE_DITE:+LCARS_IMAGE=$IMAGE_DITE }deploy/container -p $BASE_PROJET-fleet up" \
         "Une seconde instance à côté : la même commande, avec --forge-project <autre base>."
  fi
fi
case "$FORGE_ETAT" in
  aucune) stop "${R}Les deux installations ont besoin d'une forge et de son runner CI. Aucune n'est indiquée.${N}" \
               "Une forge jetable, montée par l'installeur :  $(relance "$MODE" --bench)" \
               "Une forge existante :  $(relance "$MODE" "FORGE_BASE_URL=https://…")" ;;
  injoignable) stop "${R}La forge fournie ne répond pas : $(fait forge_fournie)${N}" "Vérifier l'URL et que l'API répond (/api/v1/version), puis relancer." ;;
esac
[[ -z "$PORTS_PRIS" ]] || stop "${R}Un port demandé est déjà tenu : $PORTS_PRIS.${N}" \
  "Déplacer avec --port-forge, --port-deck ou --port-ssh, ou libérer le port."
# sans terminal, sudo ne demande aucun mot de passe : la relance en root n'a lieu que si « sudo -n » passe
SANS_TERMINAL=0
if [[ "$MODE" == "workstation" ]]; then
  if { exec 3< /dev/tty; } 2>/dev/null; then
    exec 3<&-
  else
    SANS_TERMINAL=1
    [[ "$EUID" -eq 0 ]] || sudo -n true 2>/dev/null \
      || stop "${R}Sans terminal, sudo ne peut pas demander de mot de passe, et « sudo -n » est refusé : la suite en root n'aura pas lieu.${N}"
  fi
fi

# ─── 6. le mode, et sa grille ─────────────────────────────────────────────────────────────────
# une release en conteneur nomme son image ; absente du daemon, elle est tirée avant le up, qui ne tire jamais
IMAGE_ETAT=inconnue
if [[ "$MODE" == "container" && "$PROVENANCE" == "release" && -n "$DOOR_IMAGE" ]]; then
  if "$(fait docker_bin)" image inspect "$DOOR_IMAGE" >/dev/null 2>&1; then IMAGE_ETAT=presente; else IMAGE_ETAT=a_tirer; fi
fi
if [[ "$MODE" == "container" ]]; then
  if [[ "$WITH_BENCH" -eq 1 ]]; then
    RETOUR="deploy/docker/bench/bench-down.sh --project $BASE_PROJET --yes : le conteneur, la forge, le runner et le magasin"
  else
    RETOUR="deploy/container -p $BASE_PROJET-fleet reset, 30 s : le conteneur et ses volumes ; le magasin reste"
  fi
  # mesuré sur .63 (docker natif, beta2) : banc 93 à 107 s image présente, 125 s tirage compris ; instance
  # seule 7 s image présente ; le tirage anonyme de l'image, 16 à 31 s
  if [[ "$WITH_BENCH" -eq 1 ]]; then DUREE_LA="~1 min 30"; DUREE_TIRER="~2 min"
  else DUREE_LA="moins d'une minute"; DUREE_TIRER="~1 min"
  fi
  case "$IMAGE_ETAT" in
    presente) DUREE="durée $DUREE_LA, l'image est sur ce daemon" ;;
    a_tirer)  DUREE="durée $DUREE_TIRER, tirage de l'image compris" ;;
    *)        DUREE="durée $DUREE_LA image présente, $DUREE_TIRER à tirer" ;;
  esac
  cat <<EOF
  ${W}Installation en conteneur${N} — LCARS tourne dans Docker, la distribution
  n'est pas modifiée : aucun paquet, aucun compte, rien dans /etc ni /usr.
    Modifie    Docker : un conteneur et deux volumes au projet $BASE_PROJET-fleet, le magasin $BASE_PROJET-fleet-*
    Requiert   docker · la forge (ci-dessus)
    Espace     ~3 Go · $DUREE · ports $(ou "$PORT_DECK") (deck), $(ou "$PORT_SSH") (ssh)
    Statut     deploy/container -p $BASE_PROJET-fleet status
    Retour     $RETOUR
EOF
  # l'installation dans ce système n'est proposée qu'à une machine que ce canal peut poser
  case "$(fait channel)" in
    aucun|"$(fait channel_tree)") echo "  Pour installer dans ce système à la place :  $(relance workstation)" ;;
    invalide) ;;
    *) echo "  Dans ce système : cette machine est posée par le canal « $(fait channel) » et cet arbre poserait « $(fait channel_tree) » — un canal ne se pose pas sur un autre." ;;
  esac
  echo ""
else
  if [[ "$SUBSTRATE" == "wsl" ]]; then
    MODIFIE="/etc/wsl.conf, $RACINE, des groupes et des comptes de service, des paquets apt, ~/.config, ~/.docker et ~/.claude de l'utilisateur"
    RETOUR="aucun désinstalleur : la distribution se recrée (wsl --unregister <distro>)"
    # la forge montée et son runner vivent dans le daemon de Docker Desktop, hors de la distribution
    [[ "$WITH_BENCH" -eq 0 ]] \
      || RETOUR+=" ; la forge et le runner restent dans Docker Desktop : docker compose -p $BASE_PROJET-forge down -v, docker compose -p $BASE_PROJET-runner down -v"
  else
    MODIFIE="$RACINE, des groupes et des comptes de service, des paquets apt, ~/.claude de l'utilisateur, docker-ce si aucun daemon ne répond"
    RETOUR="aucun désinstalleur : la machine se réinstalle"
  fi
  cat <<EOF
  ${W}Installation dans ce système${N} — LCARS s'installe sur cette distribution, la fleet
  tourne sous un humain de fleet. C'est le mode pour travailler sur le code.
    Modifie    $MODIFIE
    Requiert   $ROOT_DIT · docker · la forge (ci-dessus)
    Espace     ~2 Go · durée ~10 min
    Retour     $RETOUR
  Pour installer en conteneur à la place :  $(relance container)

EOF
fi

if [[ "$DOCTOR_MODE" -eq 1 ]]; then
  if [[ "$MODE" == "workstation" ]]; then
    echo "  ${W}--check${N} : la mesure se complète en root ($ROOT_DIT) ; rien n'est posé."
    [[ "$SANS_TERMINAL" -eq 0 ]] || echo "  Pas de terminal : --check continue."
    echo ""
    relance_root
  fi
  echo "  ${W}--check${N} : rien n'est fait. Pour un déploiement existant : deploy/container -p $BASE_PROJET-fleet status"
  echo ""
  exit 0
fi

# ─── 7. l'instance, quand on va la posséder ───────────────────────────────────────────────────
SANS_TERMINAL_DIT=0
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
          ""|o|O|oui|y|Y|yes) ;;
          n|N|non|no) stop "Rien n'a été fait." ;;
          *) stop "Réponse « $ans » non comprise — rien n'a été fait." ;;
        esac
      else
        echo "  (sans terminal, l'installation continue : le terrain est jetable)"
        SANS_TERMINAL_DIT=1
      fi
    fi
    echo ""
  fi
fi

# ─── 8. la sortie : un seul exec, vers sudo dans ce système, vers le délégué en conteneur ─────
PRE=()
if [[ "$MODE" == "workstation" ]]; then
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  ${W}--dry-run${N} : la commande se dit après la mesure en root ($ROOT_DIT) ; rien n'est exécuté."
    [[ "$SANS_TERMINAL" -eq 0 ]] || echo "  Pas de terminal : --dry-run continue."
    echo ""
    relance_root
  fi
  RAPPEL="Installation dans ce système — la suite demande root : sudo, puis deploy/workstation up"
else
  if [[ "$WITH_BENCH" -eq 1 ]]; then
    CMD=("$DELEGUE" ${PROJET_PORTS[@]+"${PROJET_PORTS[@]}"} --bench up)
    RAPPEL="Installation en conteneur, avec le banc — deploy/container --bench up"
  else
    CMD=("$DELEGUE" ${PROJET_PORTS[@]+"${PROJET_PORTS[@]}"} up)
    RAPPEL="Installation en conteneur — deploy/container up"
  fi
  if [[ "$IMAGE_ETAT" != inconnue ]]; then
    export LCARS_IMAGE="$DOOR_IMAGE"
    if [[ "$IMAGE_ETAT" == a_tirer ]]; then
      # le projet visé : pull ne dit une suite qu'à une instance déjà posée, celle de ce projet
      PRE=("$DELEGUE" --forge-project "$BASE_PROJET" pull)
      echo "  l'image de cette version n'est pas sur ce daemon : elle sera tirée d'abord ($DOOR_IMAGE)"
    fi
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    [[ "${#PRE[@]}" -eq 0 ]] || { printf '  --dry-run : d'"'"'abord'; printf ' %q' "${PRE[@]}"; echo ""; }
    sortie_dite "${CMD[@]}"
  fi
fi
echo "  ${G}$RAPPEL${N}"
echo ""
# la pause se joue à chaque passe, « Continuer ? » répondu ou non : c'est le dernier moment avant que le système change
echo "  ${G}    ▶  Entrée pour continuer${N}  /  ${R}Ctrl+C pour annuler${N}"
echo ""
if { exec 3< /dev/tty; } 2>/dev/null; then
  read -r _ <&3 || stop "Rien n'a été fait."
  exec 3<&-
elif [[ "$SANS_TERMINAL_DIT" -eq 0 ]]; then
  echo "  Pas de terminal : l'installation continue."
fi
[[ "$MODE" != "workstation" ]] || relance_root
rm -f "$FACTS_FILE"   # exec ne rejoue pas le trap
[[ "${#PRE[@]}" -eq 0 ]] || "${PRE[@]}" || exit 1
exec "${CMD[@]}"

}

# { main "$@"; } et non main "$@" : un flux coupé au milieu de « main » donnerait à bash une
# commande valide ; l'accolade non fermée est une erreur de syntaxe, jamais une commande.
# RIEN NE DOIT SUIVRE CETTE LIGNE.
{ main "$@"; }
