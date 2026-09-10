#!/usr/bin/env bash

#       ______________________________________________________
#      /          LCARS FLEET - FEDERATION DATABASE           \
#     |   ________   __________________________________________\
#     |  |  2026  |  | SOURCE: install.sh
#     |  |________|  | AUTHOR: DRDREE
#     |   ________   | SYSTEM: LCARS-FLEET v2 (runtime Elixir/OTP)
#     |  |  v2.0  |  | STATUS: PROTO-V2
#     |  |________|  |__________________________________________
#     |              \__________________________________________\
#      \    "To boldly go where no code has gone before..."     /
#       \______________________________________________________/
#
#     install.sh — LA porte d'entrée. Une seule, toujours.
#
#     Elle détecte ce que la machine PERMET, demande ce que tu VEUX quand
#     les deux sont possibles, annonce ce que ça prend, et délègue.
#
#       --workstation   LCARS s'installe DANS ce système. WSL2, ou un Linux natif
#                       DÉCLARÉ machine dédiée (LCARS_ALLOW_ANY_HOST=1) : le rail
#                       possède /etc et /opt/lcars, il reprend ce qu'il a posé
#                       mais ne restaure pas ce qu'il a modifié avant lui.
#                       Modèle 3 zones : SOURCE (ce checkout) → INSTALL
#                       (/opt/lcars/runtime, RO) → STATE (~/.lcars per-humain).
#       --container           LCARS tourne dans un conteneur. Rien hors de ton
#                       clone et de docker.
#       --bench         axe FORGE : « monte-la-moi ». Il ne dit PAS la même chose
#                       sur les deux rails, et c'est le § 13 qui les sépare :
#                         --container   fournit les annexes — forge jetable, runner CI,
#                                 humain de démonstration — en un geste.
#                         --workstation  la forge est montée ICI même si
#                                 FORGE_BASE_URL est posée. Rien d'autre : le
#                                 runner et l'humain de démo n'existent que sur
#                                 un banc, et le banc nomme le sien.
#                       L'humain EST une annexe : un déploiement de travail n'en
#                       sème aucun, les personnes s'inscrivent sur la forge.
#       --check         sonde read-only, rien n'est modifié.
#       --dry-run       tout jusqu'au bilan, PLUS ce que la sortie ferait — les artefacts et leurs
#                       sha256 attendus, la commande du rail — sans rien télécharger ni poser.
#       --uninstall     relais au désinstalleur (« provision uninstall ») par deploy/workstation
#                       uninstall, qui a le sudo. Ce qui suit « -- » lui part (--yes, --humans, --annexes).
#                       Le conteneur, lui, se défait par deploy/container reset.
#       --from-release  la provenance « release » même depuis un checkout : l'artefact de CETTE
#                       version, téléchargé dans ~/.lcars/kits/<version>/ et VÉRIFIÉ — sha256 en
#                       dur dans cette porte, signature minisign si l'outil est là (dit sinon).
#                       C'est le mouvement SOURCE d'une porte pipée (curl … | bash).
#       --source [REF]  la provenance « source », pour qui veut compiler : git clone AU TAG de cette
#                       porte, ou REF (une branche, un tag) — jamais main sans le dire. Remplace
#                       --branch, qui est REFUSÉ.
#       --repo URL      le dépôt de --source (défaut : le dépôt public, la cible).
#       --port-forge N  le port que publie la forge du poste (défaut 21000).
#       --port-deck N   le port du deck (défaut 20999).
#       --port-ssh N    le port SSH du banc (défaut 2222) — avec --bench uniquement.
#                       Les trois sont les ports que « bench-up » publie : un banc par port, et
#                       les WSL d une même machine partagent un daemon docker.
#       --forge-project N  la BASE des projets compose (défaut lcars) : <N>-forge,
#                       <N>-runner sur le poste, <N>-fleet pour le conteneur, et le banc
#                       en dérive les trois. UN sens (DI-05). C'est
#                       le geste qui en monte une SECONDE au lieu de déplacer
#                       celle qui tourne.
#
#     Le re-run est TOUJOURS sûr : pas de sentinelle, l'état c'est le
#     système, re-sondé à chaque passage.
#
# --- END HEADER ---

set -euo pipefail

# La version de CETTE porte. Elle s'affiche (`--version`) parce qu'une ligne de README doit pointer
# une URL PAR VERSION : servir depuis `HEAD` est le grief que `curl_bash_2026.md` nomme « gratuit à
# corriger », et une porte qui ne sait pas dire laquelle elle est ne peut pas être rapportée.
LCARS_DOOR_VERSION="2026-09-05"   # @@DOOR_VERSION@@ le tag de la release — door-gen.sh l'ecrit ici

main() {

if [[ -n "${NO_COLOR:-}" ]] || [[ "${PROV_COLOR:-}" == "0" ]] \
   || { [[ -z "${PROV_COLOR:-}" ]] && [[ ! -t 1 ]]; }; then
  AMBER=''; CYAN=''; W=''; G=''; R=''; N=''; BA=''
  LCARS_COLOR_HINT=1
else
  AMBER=$'\033[38;5;214m'; CYAN=$'\033[0;36m'; W=$'\033[1;37m'
  G=$'\033[1;32m'; R=$'\033[1;31m'; N=$'\033[0m'; BA=$'\033[1;38;5;214m'
fi

# ─── LA PORTE REFUSE ROOT ───────────────────────────────────────────────────
#
# ⚠ `curl | sudo bash` EST LE PIRE MOTIF QUI SOIT, et le refuser par construction vaut mieux que le
# déconseiller. Le sudo est demandé par le délégué du rail poste, à SON début, après la validation —
# jamais ici, où personne n'a encore rien choisi.
if [[ "$EUID" -eq 0 ]]; then
  echo ""
  echo "  ${R}Cette porte ne se lance pas en root.${N}"
  echo "  Elle mesure, elle propose, elle délègue — rien de tout cela n'a besoin de privilèges."
  echo "  Le rail poste demandera sudo lui-même, une fois, quand tu auras choisi :"
  echo "    bash $0 --workstation"
  exit 1
fi

# ⚠ `${BASH_SOURCE[0]}` EST NON LIÉ QUAND BASH LIT SUR STDIN, et c'est le cas NOMINAL du geste voulu
# (`curl … | bash`). Le repli `:-$0` tient sous `set -u` ; ce qui suit distingue les deux mondes :
#   · lancée depuis un fichier  → `SCRIPT_DIR` est le clone, le préflight y vit
#   · lancée depuis un flux     → il n'y a pas de clone, donc on en fait un (branche standalone)
#
# ⚠ ET LE REFUS DE STDIN A DISPARU (⚖ user 2026-08-31 : « c'est une question technique, pas un choix
# dogmatique »). Il n'achetait que deux des cinq griefs du pipe, et les deux ont un meilleur remède :
# la troncature par `{ main "$@"; }` en dernière ligne — au banc de troncature, 0 fuite sur 162 contre
# 67 pour la forme sans `main` — et la localisation par cette branche-ci.
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

# ⚠ `fleet_human_name` A DISPARU D'ICI (⚖ user 2026-08-30). Elle allait demander à
# `forge-gestures.sh` le nom du compte que la recette sèmerait, pour que le bandeau et l'étape 3 le
# nomment. Le rail ne sème plus d'humain : il n'y a plus de nom à demander, et en nommer un serait
# faire taper à l'opérateur une commande qui échoue.

REPO_URL="https://github.com/lordzurp/LCARS-fleet.git"   # la CIBLE (⚖ user) : le depot public — on y va chercher la RELEASE du tag, jamais main
# ─── LES CONSTANTES DE LA VERSION — vides dans le gabarit, remplies par deploy/lib/door-gen.sh ────
#
# La porte d'une release porte EN DUR l'adresse de ses artefacts, leurs sha256 et la cle qui les
# signe (curl_bash_2026 § 07.2 : un sha servi par le meme serveur que le binaire ne verifie rien).
# Chaque ligne marquee `@@DOOR_…@@` est ce que le generateur remplace, et rien d'autre — un temoin
# tient que la porte generee est ce gabarit, hors ces lignes.
DOOR_BASE=""                       # @@DOOR_BASE@@ <forge>/<owner>/<repo>/releases/download/<tag>
MINISIGN_PUBKEY=""                 # @@DOOR_PUBKEY@@ la cle publique minisign des artefacts
sums() { cat <<'SUMS'              # @@DOOR_SUMS_BEGIN@@ « <sha256>  <artefact> », un par ligne
SUMS
}                                  # @@DOOR_SUMS_END@@
SOURCE_REF="$LCARS_DOOR_VERSION"   # --source : git clone AU TAG de cette porte, jamais main sans le dire
WANT_SOURCE=0; FROM_RELEASE=0; DRY_RUN=0; UNINSTALL=0
DOCTOR_MODE=0
RAIL=""              # workstation | container — VIDE tant que personne n'a choisi
FORCED_SUBSTRATE=""  # posé par --substrate : vaut pour la porte ET pour le rail
WITH_BENCH=0           # axe FORGE      : monte-la-moi
# ⚠ `DISPOSABLE` A DISPARU D'ICI, ET SON DRAPEAU EST REFUSÉ PLUS BAS (⚖ user 2026-09-04 : « le
# --disposable semble être un vieux reliquat à virer »). Il portait un « axe DESTINATION » dont le
# seul effet, au bout de quatre étages, était un nom d'humain par défaut dans `forge-gestures.sh`
# — que plus personne ne demandait : seul le banc sème un humain, et il le NOMME.
# ⚠ `CONSENTED` A DISPARU D'ICI, ET SON DRAPEAU EST REFUSÉ PLUS BAS. Il valait « la 2ᵉ instance
# saute l'accueil et la pause » — une notion qui n'existe QUE si la porte se rejoue elle-même sous
# sudo. Elle ne le fait plus : le rail poste a son propre script, et l'escalade de celui-là n'a rien
# à sauter puisqu'il n'a ni accueil ni pause.
declare -a PASSTHRU=()
declare -a DELEGATE_ARGS=()   # ce qui suit `--` : pour le delegue de la branche, verbatim

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--doctor) DOCTOR_MODE=1; shift ;;
    --workstation)    RAIL=workstation; shift ;;
    --container)            RAIL=container; shift ;;
    # ─── UN SEUL AXE (§ 13) ─────────────────────────────────────────────────
    #
    # `--bench`  axe FORGE : montée par nous, ou fournie (FORGE_BASE_URL). Sur le conteneur, `--bench`
    # monte aussi le banc — runner CI et humain de démo — et c'est le banc qui NOMME cet humain
    # (`bench-forge-bootstrap.sh`, `LCARS_BUILTIN_HUMAN`). Un déploiement de travail n'en sème
    # aucun : les personnes s'inscrivent sur la forge, le convergeur les matérialise.
    --bench)          WITH_BENCH=1; shift ;;
    # ⚠ REFUSE, PAS IGNORE — même règle que `--consented` : un drapeau retiré doit RATER.
    --disposable) echo "  --disposable est retire : un deploiement ne seme pas d'humain de demonstration." >&2
                  echo "  Le banc (--container --bench) nomme le sien ; les personnes s'inscrivent sur la forge." >&2
                  exit 1 ;;
    # ⚠ REFUSE, PAS IGNORE. Un drapeau retire doit RATER : accepte et sans effet, il ferait
    # croire a un geste qui ne se produit plus. Meme regle que `--fleet-human`, meme verrou.
    --consented) echo "  --consented est retire : la porte ne se rejoue plus sous sudo." >&2
                 echo "  Le rail poste vit dans deploy/workstation, et son escalade n'a rien a sauter." >&2
                 exit 1 ;;
    --repo)   REPO_URL="${2:?--repo attend une URL}"; shift 2 ;;
    --source) WANT_SOURCE=1; shift
              if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then SOURCE_REF="$1"; shift; fi ;;
    # ⚠ REFUSE, PAS IGNORE — meme regle que `--consented`. `--branch` clonait `main` par defaut : une
    # porte de version qui l'accepterait encore enverrait compiler autre chose que ce qu'elle EST.
    --branch) echo "  --branch est retire : --source [<tag|branche>] clone AU TAG de cette porte ($LCARS_DOOR_VERSION), jamais main sans le dire." >&2
              exit 1 ;;
    --from-release) FROM_RELEASE=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --uninstall)    UNINSTALL=1; shift ;;
    --substrate) FORCED_SUBSTRATE="${2:?--substrate attend une valeur}"
                 PASSTHRU+=("$1" "$2"); shift 2 ;;
    # ports et nom d'instance : validés par `provision`, jamais ici
    --port-forge|--port-deck|--port-ssh) PASSTHRU+=("$1" "${2:?$1 attend un port}"); shift 2 ;;
    --forge-project)          PASSTHRU+=("$1" "${2:?$1 attend un nom}"); shift 2 ;;
    --env|--human|--only) PASSTHRU+=("$1" "${2:?$1 attend une valeur}"); shift 2 ;;
    --) shift; DELEGATE_ARGS=("$@"); break ;;
    --version)
      # ⚠ ELLE DOIT MARCHER PIPÉE, DONC SANS LIRE SON PROPRE FICHIER. C'est tout l'intérêt : celui
      # qui rapporte un problème sur une porte qu'il a pipée doit pouvoir dire LAQUELLE.
      echo "$LCARS_DOOR_VERSION"; exit 0 ;;
    --help|-h)
      # Pipée, `${BASH_SOURCE[0]}` est non lié : l'aide se lit dans le fichier quand il y en a un,
      # et se réduit à l'essentiel sinon. Une aide qui exige un fichier est une porte fermée.
      if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        sed -n '/^#     install.sh — LA porte/,/^#     système/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,5\}//'
      else
        echo "install.sh $LCARS_DOOR_VERSION — LA porte d'entrée."
        echo "  --workstation | --container   le rail · --bench  les annexes · --check  sonde read-only"
        echo "  --port-forge N | --port-deck N | --port-ssh N | --forge-project N | --substrate S"
        echo "  --dry-run  ce que la sortie ferait, sans rien poser · --uninstall  relais au désinstalleur du canal"
        echo "  --from-release  l'artefact de CETTE version, vérifié"
        echo "  --source [REF]  git clone AU TAG de cette porte (ou REF) · --repo URL  son dépôt"
      fi
      exit 0 ;;
    *) echo "Option inconnue : $1 — --help" >&2; exit 1 ;;
  esac
done

# ─── LES OUTILS DE LA PORTE — des définitions, aucune exécution ─────────────
#
# ⚠ CE BLOC N'EST PAS LE PRÉFLIGHT, ET LE TITRE QU'IL PORTAIT LE FAISAIT CROIRE. Un témoin d'ordre a
# lu ce titre comme la mesure et a place le préflight AVANT l'accueil, sur un fichier où l'ordre
# d'exécution était pourtant juste. Un intertitre est lu comme un repère : il doit désigner ce qui
# s'exécute là, pas ce qui se déclare.
preflight_ok=1
say_ok()   { echo "  ${G}[ok]${N} $1"; return 0; }
say_miss() { echo "  ${R}[MANQUE]${N} $1"; preflight_ok=0; }

PROVISION="$SCRIPT_DIR/deploy/provision"
FACTS_FILE=""
fait() { # fait <nom> — la valeur mesurée, vide si le fait n'a pas été posé
  [[ -n "$FACTS_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$FACTS_FILE" 2>/dev/null | tail -1
}

# sortie_dite <argv…> — ce que `--dry-run` rend a la place d'un exec : la commande, mot a mot, et rien
# n'est fait. Elle vit devant CHAQUE exec qui mute (§ 07.7 : « je ne sais pas ce que ca va faire »).
sortie_dite() {
  echo ""; echo "  ${W}--dry-run${N} : rien n'est fait. La sortie serait :"
  printf '   '; printf ' %q' "$@"; echo ""
  exit 0
}
# ─── LE MOUVEMENT SOURCE, PROVENANCE « release » — des definitions, rien ne s'execute ici ───────
#
# Pipee, cette porte n'a pas d'arbre, et le preflight vit dans le kit. Elle va donc chercher
# l'artefact de SA version (40-PORTE § 2) : le kit — c'est l'arbre (deploy/, provision,
# workstation). L'arch se lit ICI, avant tout arbre : c'est la seule lecture de la porte qui ne
# vient pas du module, et elle ne sert qu'a NOMMER un fichier — le preflight la re-mesure ensuite.
sum_of() { # sum_of <artefact> -> son sha256 dans la table ; rc 1 s'il n'y est pas
  local s n; while read -r s n; do [[ "$n" == "$1" ]] && { echo "$s"; return 0; }; done < <(sums); return 1
}
# assets_for <arch> -> le NOM de l'artefact que cette machine prend, par convention (00-OBJECTIF
# § 3 ; pack.sh le produit, et c'est le SEUL endroit ou la porte le connait) :
#   `lcars-fleet-<v>-<otp>-<arch>.tar.gz`  le kit — l'otp se lit dans la table, jamais compose.
assets_for() {
  local v="$LCARS_DOOR_VERSION" s n
  while read -r s n; do [[ "$n" == lcars-fleet-"$v"-*-"$1".tar.gz ]] && { echo "$n"; return 0; }; done < <(sums)
  return 0
}
fetch() { # fetch <url> <fichier> — `--proto '=https' --tlsv1.2 -fsSL` (§ 07.6) ; http n'entre que par LCARS_DOOR_INSECURE_HTTP=1
  local proto='=https'; [[ -z "${LCARS_DOOR_INSECURE_HTTP:-}" ]] || proto='=http,https'
  curl --proto "$proto" --tlsv1.2 -fsSL "$1" -o "$2"
}
# obtenir <artefact> — dans $KITS_DIR : deja la ET au sha de la table, rien ; sinon telecharge. Puis le
# sha256 contre la table, OBLIGATOIRE et jamais silencieux (§ 07.2) — un ecart efface le fichier et
# rien n'est pose. Puis la signature. Le `.sha256` ecrit a cote est celui que `workstation --from` relit.
obtenir() {
  local a="$1" f="$KITS_DIR/$1" want got
  want="$(sum_of "$a")" || { echo "  ${R}$a n'est pas dans la table de cette porte — elle ne l'a jamais vu, rien n'est posé.${N}"; return 1; }
  if [[ -f "$f" && "$(sha256sum "$f" | cut -d' ' -f1)" == "$want" ]]; then
    echo "  $a : déjà là, sha256 vérifié"
  else
    fetch "$BASE/$a" "$f" || { rm -f "$f"; echo "  ${R}$BASE/$a : téléchargement en échec — rien n'est posé.${N}"; return 1; }
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    [[ "$got" == "$want" ]] || { rm -f "$f"; echo "  ${R}sha256 de $a : attendu $want, obtenu $got — artefact altéré ou incomplet, rien n'est posé.${N}"; return 1; }
    echo "  $a : téléchargé, sha256 vérifié"
  fi
  printf '%s  %s\n' "$want" "$a" > "$f.sha256"
  signature "$a"
}
# signature <artefact> — minisign si l'outil est la (cle publique EN DUR) ; sinon le DIRE, sur stderr.
# Jamais taire, jamais degrader en succes (§ 07.4) : une signature invalide, ou absente alors que la
# porte porte une cle, est un refus — le fichier est efface, rien n'est pose.
signature() {
  local a="$1" f="$KITS_DIR/$1"
  [[ -n "$MINISIGN_PUBKEY" ]] || { echo "  ! provenance NON vérifiée (sha256 seul) : cette porte ne porte pas de clé publique" >&2; return 0; }
  command -v minisign >/dev/null 2>&1 || { echo "  ! minisign absent : provenance NON vérifiée (sha256 seul)" >&2; return 0; }
  [[ -f "$f.minisig" ]] || fetch "$BASE/$a.minisig" "$f.minisig" \
    || { rm -f "$f.minisig"; echo "  ${R}$a.minisig introuvable, et cette porte attend une signature — rien n'est posé.${N}"; return 1; }
  minisign -Vq -P "$MINISIGN_PUBKEY" -m "$f" \
    || { rm -f "$f" "$f.minisig"; echo "  ${R}signature de $a INVALIDE (minisign) — rien n'est posé.${N}"; return 1; }
  echo "  $a : signature vérifiée (minisign)"
}
# source_release — le mouvement SOURCE d'une porte pipee (ou --from-release) : le kit de SA version
# dans ~/.lcars/kits/<version>/, verifie, detare → c'est l'arbre.
source_release() {
  local arch a s manque=0
  arch="$(uname -m)"
  mapfile -t ASSETS < <(assets_for "$arch")
  [[ -n "${ASSETS[0]:-}" ]] || {
    echo "  ${R}aucun kit $LCARS_DOOR_VERSION pour $arch dans la table de cette porte.${N}"
    echo "  Le gabarit du dépôt ne télécharge rien : lance-le depuis un checkout, ou prends la porte d'une release."
    exit 1
  }
  KITS_DIR="$HOME/.lcars/kits/$LCARS_DOOR_VERSION"
  echo "  ${W}source${N} : release ${W}$LCARS_DOOR_VERSION${N} — $BASE → $KITS_DIR/  (arch $arch)"
  for a in "${ASSETS[@]}"; do
    if s="$(sum_of "$a")"; then printf '    %-56s sha256 %s\n' "$a" "$s"; else printf '    %-56s sha256 ABSENT DE LA TABLE\n' "$a"; manque=1; fi
  done
  [[ "$manque" -eq 0 ]] || { echo "  ${R}un artefact n'est pas dans la table de cette porte — elle ne l'a jamais vu : rien n'est téléchargé, rien n'est posé.${N}"; exit 1; }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  ${W}--dry-run${N} : rien n'est téléchargé."
    # un kit de CETTE version deja detare (une pose precedente) est un arbre : le preflight peut jouer
    if [[ ! -x "$KITS_DIR/lcars_install/deploy/provision" ]]; then
      echo "  Pas d'arbre ici — le préflight vit dans le kit. La sortie serait :"
      echo "    deploy/workstation up"
      exit 0
    fi
    SCRIPT_DIR="$KITS_DIR/lcars_install"; return 0
  fi
  if [[ "$BASE" != https://* ]]; then
    [[ -n "${LCARS_DOOR_INSECURE_HTTP:-}" ]] || { echo "  ${R}$BASE n'est pas https — cette porte ne télécharge qu'en https (LCARS_DOOR_INSECURE_HTTP=1 pour un banc local, et rien d'autre).${N}"; exit 1; }
    echo "  ${AMBER}LCARS_DOOR_INSECURE_HTTP=1 : $BASE — transport en clair, banc seulement.${N}" >&2
  fi
  command -v curl >/dev/null 2>&1 || { echo "  ${R}curl est absent — apt install curl${N}"; exit 1; }
  mkdir -p "$KITS_DIR"
  for a in "${ASSETS[@]}"; do obtenir "$a" || exit 1; done
  rm -rf "$KITS_DIR/lcars_install"
  tar -xzf "$KITS_DIR/${ASSETS[0]}" -C "$KITS_DIR" || { echo "  ${R}le kit ne se détare pas — rien n'est posé.${N}"; exit 1; }
  SCRIPT_DIR="$KITS_DIR/lcars_install"
}

# ⚠ UN DRAPEAU INVALIDE SE REFUSE AU PARSING, PAS APRÈS UNE MESURE. `provision` valide aussi son
# `--substrate` et rendrait le même refus — mais dix secondes plus tard, noyé dans un rapport, sur
# une machine qu'on aura sondée pour rien. Ce que l'opérateur a MAL TAPÉ ne demande aucune mesure.
case "${FORCED_SUBSTRATE:-wsl}" in
  wsl|docker|linux) ;;
  *) echo ""; echo "  ${R}--substrate $FORCED_SUBSTRATE : inconnu (wsl|docker|linux).${N}"; exit 1 ;;
esac

# ─── 1. L'ACCUEIL — IMMÉDIAT, AVANT TOUTE MESURE ────────────────────────────
#
# ⚠ IL VIENT EN PREMIER PARCE QU'IL EST GRATUIT. Le préflight prend quelques secondes ; celui qui a
# tapé la commande doit savoir tout de suite ce qui va se passer et ce que ça demande, pas regarder
# un curseur en se demandant s'il a lancé une installation.
cat <<EOF

  ${W}LCARS-FLEET v2${N} — porte d'entrée ${W}$LCARS_DOOR_VERSION${N}

  Le déroulé : ${W}source${N} → ${W}préflight${N} → ${W}bilan${N} → ${W}ton choix${N} → le rail.
  Rien n'est modifié avant ton choix, et cette porte ne demande jamais sudo.

  Les grands prérequis : ${W}git${N} pour la source · ${W}docker${N} pour le conteneur ·
  ${W}sudo${N} pour le poste (demandé par le rail lui-même, une fois, après ton choix).

EOF

# ─── 1b. LA SOURCE — ELLE VIENT AVANT LE PREFLIGHT, QUI VIT DEDANS ──────────
#
# ⚠ PIPEE, CETTE PORTE N'A PAS D'ARBRE, et le preflight est un module du depot. La source doit donc
# preceder la mesure — c'est l'ordre du canon, et c'est aussi ce qui rend `curl … | bash` jouable.
# Trois provenances, une regle (40-PORTE § 2) :
#   · un checkout (BASH_SOURCE lie, .git present)      → source  : on continue dedans, HEAD est dit
#   · la racine d'un kit (BASH_SOURCE lie, sans .git)  → kit     : on continue dedans
#   · pipee (BASH_SOURCE non lie), ou --from-release   → release : l'artefact de SA version, verifie
#   · --source [REF]                                   → source  : git clone AU TAG, pour qui compile
#
# ⚠ SOUS L'HUMAIN, SANS SUDO. L'ancienne porte clonait EN ROOT (`runuser`) apres son escalade : le
# clone appartenait a root, et `git` le lisait ensuite en « dubious ownership ». Ici il n'y a pas
# d'escalade du tout — git (--source) ou curl (release) est le seul prerequis de cette etape.
BASE="${LCARS_DOOR_BASE:-${DOOR_BASE:-${REPO_URL%.git}/releases/download/$LCARS_DOOR_VERSION}}"
KITS_DIR=""; PROVENANCE=""
if [[ "$WANT_SOURCE" -eq 1 ]]; then
  command -v git >/dev/null 2>&1 || {
    echo "  ${R}git est absent, et c'est le seul prérequis de cette étape.${N}"
    echo "    apt install git   (ou l'équivalent de ta distro)"
    exit 1
  }
  SRC_DIR="${LCARS_SRC:-$HOME/LCARS-fleet}"
  if [[ -d "$SRC_DIR/.git" ]]; then
    echo "  ${W}source${N} : $SRC_DIR existe — synchronisation sur ${W}$SOURCE_REF${N}"
    git -C "$SRC_DIR" fetch --quiet origin \
      && git -C "$SRC_DIR" checkout --quiet "$SOURCE_REF" \
      && git -C "$SRC_DIR" pull --quiet --ff-only origin "$SOURCE_REF" \
      || { echo "  ${R}la synchronisation a échoué — règle-la, puis relance.${N}"; exit 1; }
  else
    echo "  ${W}source${N} : clone de $REPO_URL (${W}$SOURCE_REF${N}) → $SRC_DIR"
    git clone --quiet --branch "$SOURCE_REF" "$REPO_URL" "$SRC_DIR" \
      || { echo "  ${R}le clone a échoué — règle-le, puis relance.${N}"; exit 1; }
  fi
  SCRIPT_DIR="$SRC_DIR"; PROVENANCE=source
elif [[ "$FROM_RELEASE" -eq 1 || -z "$SCRIPT_DIR" || ! -x "$SCRIPT_DIR/deploy/provision" ]]; then
  source_release; PROVENANCE=release
elif [[ -e "$SCRIPT_DIR/.git" ]]; then
  PROVENANCE=source
else
  PROVENANCE=kit
fi
PROVISION="$SCRIPT_DIR/deploy/provision"
[[ -x "$PROVISION" ]] || {
  echo "  ${R}provision introuvable après la source : $PROVISION${N}"
  echo "  L'arbre est incomplet — ce n'est pas docker qui manque, c'est la source."
  exit 1
}
case "$PROVENANCE" in
  source)  echo "  ${W}provenance${N} : source — $SCRIPT_DIR, HEAD $(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo inconnu)" ;;
  kit)     echo "  ${W}provenance${N} : kit — $SCRIPT_DIR" ;;
  release) echo "  ${W}provenance${N} : release $LCARS_DOOR_VERSION — le kit dans $SCRIPT_DIR" ;;
esac

echo ""
# ─── 2. PRÉFLIGHT — UNE SEULE MESURE, ET C'EST CELLE DU PROVISIONNEMENT ─────
#
# ⚠ CETTE PORTE MESURAIT ELLE-MÊME, et c'est la duplication que le canon proscrit nommément (« le
# préflight dupliqué entre la porte et ce qui vit dans deploy/ : une seule mesure »). Deux sondes du
# même fait dérivent — et celle qu'on ne relit pas est celle qui ment le jour où l'autre change.
#
# Le module `00-preflight` porte les deux rails. Il parle deux fois : en lignes pour un humain, et en
# faits `nom=valeur` (`p_fact`) dans `PROV_FACTS_FILE` pour qui doit DÉCIDER. La porte est ce
# « qui » : elle ne mesure plus rien, elle lit.
#
# ⚠ `doctor`, PAS `apply`, ET SANS SUDO : `doctor` est read-only, `NEEDS: root` n'est contrôlé qu'à
# l'apply (`provision`, `run_module`). La porte n'a pas de sudo et n'en aura pas — c'est le rail qui
# escalade, à son début.
echo "  ${W}Préflight${N}"

FACTS_FILE="$(mktemp "${TMPDIR:-/tmp}/lcars-facts.XXXXXX")" || FACTS_FILE=""
trap '[[ -n "${FACTS_FILE:-}" ]] && rm -f "$FACTS_FILE"' EXIT

# La sortie du module est CAPTURÉE : la porte rend son propre préflight, à partir des faits. Le
# rapport brut reste disponible pour qui le demande — il n'est pas jeté, il n'est pas imposé.
# ⚠ `--substrate` EST UNE OPTION DU RUNNER, PAS UNE VARIABLE : `provision` pose lui-même
# `PROV_SUBSTRATE` depuis son option (`provision:169`), donc une variable passée en environnement
# est écrasée sans un mot. Le drapeau de la porte se traduit en drapeau du runner — c'est l'idiome
# du reste de ce fichier (`PASSTHRU`), et c'est aussi ce qui donne la validation gratuitement.
remesurer() { # rejoue le préflight et recharge les faits — la SEULE façon de re-mesurer ici
  # ⚠ ET C'EST POURQUOI CETTE PORTE N'A PLUS DE SONDE À ELLE. Elle en avait une, et après une
  # escalade ou une pose de paquets elle la rejouait — donc deux sondes du même fait, à deux
  # instants, avec deux façons de conclure. Rejouer LE module garde la mesure unique dans le temps
  # aussi, pas seulement dans l'espace.
  : > "$FACTS_FILE"
  PREFLIGHT_OUT="$(env PROV_FACTS_FILE="$FACTS_FILE" \
    "$PROVISION" doctor --only 00-preflight ${FORCED_SUBSTRATE:+--substrate "$FORCED_SUBSTRATE"} 2>&1)" || true
}
remesurer

# ─── --uninstall : LE RELAIS, SELON LE CANAL LU AU PREFLIGHT — la porte DIT, le rail FAIT ─────────
# Le desinstalleur d'une machine est `provision uninstall` (le journal et le manifeste). La porte n'a
# pas de sudo : `deploy/workstation uninstall` l'a, et lit le MEME fait. Ce qui suit `--` lui part.
if [[ "$UNINSTALL" -eq 1 ]]; then
  case "$(fait channel)" in
    invalide) echo "  ${R}le canal d'installation de cette machine est ILLISIBLE — rien n'est fait ; le préflight nomme le fichier.${N}"; exit 1 ;;
    *)        _geste="provision uninstall (journal + manifeste) — sans --yes, il n'imprime que son plan" ;;
  esac
  echo "  ${W}--uninstall${N} : canal « $(fait channel) » → $_geste"
  [[ -x "$SCRIPT_DIR/deploy/workstation" ]] || { echo "  ${R}deploy/workstation introuvable — ce geste exige l'arbre complet.${N}"; exit 1; }
  [[ "$DRY_RUN" -eq 0 ]] || sortie_dite "$SCRIPT_DIR/deploy/workstation" uninstall "${DELEGATE_ARGS[@]}"
  exec "$SCRIPT_DIR/deploy/workstation" uninstall "${DELEGATE_ARGS[@]}"
fi

for t in git curl; do
  if [[ "$(fait "$t")" == "oui" ]]; then say_ok "$t"; else say_miss "$t — apt install $t"; fi
done

DOCKER_OK=0
case "$(fait docker)" in
  oui)    DOCKER_OK=1; say_ok "docker répond ($(fait docker_bin))" ;;
  refuse) # Même fait, deux conclusions : le poste escalade et s'en moque, le conteneur tourne sous
          # l'humain et ne peut pas travailler. La branche tranche, pas le préflight.
          echo "  ${W}[à voir]${N} $(fait docker_why)" ;;
  absent) if [[ "$(fait consent)" == "env" || "$(fait consent)" == "fichier" ]] \
             && [[ "$(fait substrat)" == "linux" && "${RAIL:-}" != "container" ]]; then
            echo "  ${W}[à voir]${N} docker absent — le rail POSTE le posera (docker-ce, dépôt upstream download.docker.com)"
            [[ -n "$RAIL" ]] || echo "           le CONTENEUR, lui, exige un daemon DÉJÀ debout : il n'installe rien (loi 5)."
          elif [[ "$RAIL" == "container" ]]; then
            say_miss "$(fait docker_why)"
            echo "           Le conteneur n'installe pas docker (loi 5) : pose-le comme tu l'entends,"
            echo "           ou donne cette machine au rail poste — LCARS_ALLOW_ANY_HOST=1 bash $0 --workstation"
          else
            say_miss "$(fait docker_why)"
          fi ;;
  *)      say_miss "le préflight n'a pas rendu de fait « docker » — provision doctor a-t-il tourné ?" ;;
esac

if [[ "$preflight_ok" -eq 0 ]]; then
  echo ""
  echo "  ${R}Prérequis manquants — rien n'a été fait. Comble-les et relance.${N}"
  echo "  Le rapport complet du préflight :"
  printf '%s\n' "$PREFLIGHT_OUT" | sed 's/^/    /'
  exit 1
fi

# ─── LE SUBSTRAT SE LIT, IL NE SE REDÉTECTE PAS ─────────────────────────────
# `--substrate` a été passé au module ci-dessus : ce qu'il rend EST la réponse, forcée ou mesurée.
# Une seconde détection ici rouvrirait la divergence que ce bloc vient de fermer.
SUBSTRATE="$(fait substrat)"
[[ -n "$SUBSTRATE" ]] || SUBSTRATE="${FORCED_SUBSTRATE:-linux}"

docker_installable_here() {   # 0 si le rail POSTE peut poser docker sur cette machine-ci
  [[ "${RAIL:-}" != "container" ]] || return 1
  [[ -n "${LCARS_ALLOW_ANY_HOST:-}" ]] || return 1
  [[ "$SUBSTRATE" == "linux" ]]
}
case "$SUBSTRATE" in
  wsl|docker|linux) ;;
  *) echo ""; echo "  ${R}--substrate $SUBSTRATE : inconnu (wsl|docker|linux).${N}"; exit 1 ;;
esac

if [[ "$SUBSTRATE" == "wsl" ]] && ! unshare -Ur true 2>/dev/null; then
  echo ""
  echo "  ${R}Pas de namespaces utilisateur — les pods tournent sous bwrap, qui les exige.${N}"
  echo "  WSL1 ? passe en WSL2 :  wsl --set-version <distro> 2   (PowerShell)"
  exit 1
fi

# ─── LE BILAN — CE QUE LA MACHINE PERMET, DIT AVANT TOUTE QUESTION ──────────
#
# ⚠ UNE OPTION IMPOSSIBLE S'AFFICHE, ELLE NE SE SUPPRIME PAS. La version d'avant choisissait
# `RAIL=container` en silence sur un linux natif, et masquait l'option 2 quand docker manquait : l'écran
# ne portait plus la trace de ce qui n'était pas offert, ni pourquoi. Un menu qui cache une option
# fait croire qu'elle n'existe pas ; un menu qui la barre EN NOMMANT SON FAIT apprend la machine à
# celui qui la lit — et c'est exactement ce que le canon demande (« l'option IMPOSSIBLE affichée,
# barrée, avec son fait »).
#
# Les faits viennent tous du même endroit : `00-preflight`, mesuré une fois plus haut.
POSTE_POURQUOI=""
CONTENEUR_POURQUOI=""
if [[ "$SUBSTRATE" == "wsl" ]]; then
  :
elif [[ "$SUBSTRATE" == "linux" && "$(fait consent)" != "none" ]]; then
  :
elif [[ "$SUBSTRATE" == "linux" ]]; then
  # ⚠ « N'A PAS DE DESINSTALLEUR » ETAIT FAUX, ET LE MEME FICHIER DISAIT L'INVERSE 98 LIGNES PLUS
  # BAS (« provision uninstall retire ce que le journal a noté »). Le verbe existe, avec son plan sans mutation, son `--yes`, son journal et son bilan de sortie.
  #
  # Ce que ce refus doit dire est plus precis, et c'est ce qui aide a decider : le rail POSSEDE la
  # machine, il sait REPRENDRE ce qu'il a pose, et il ne sait pas RESTAURER ce qu'il a modifie
  # avant lui. La nuance est le vrai contenu de l'avertissement — pas une absence d'outil.
  POSTE_POURQUOI="linux natif non déclaré. Ce rail est réservé à WSL2, ou à une machine DÉDIÉE qui l'assume : il possède /etc et /opt/lcars. « provision uninstall » reprend ce qu'il a posé, mais un retour à l'identique demande un instantané. Pour l'assumer : LCARS_ALLOW_ANY_HOST=1"
else
  POSTE_POURQUOI="substrat « $SUBSTRATE ». Ce rail est réservé à WSL2, ou à une machine DÉDIÉE déclarée telle par LCARS_ALLOW_ANY_HOST=1"
fi
[[ "$DOCKER_OK" -eq 1 ]] || CONTENEUR_POURQUOI="$(fait docker_why)"
# ─── LE CANAL : UN CANAL NE SE POSE PAS SUR UN AUTRE — jamais en silence, jamais de conversion ───
# `channel` = qui a posé cette machine (préflight). Ce que CETTE porte poserait est `channel_tree`
# (ce que l'arbre écrirait : source, ou kit). Le même canal est une mise à jour ; « aucun », une
# première pose ; « inconnu » (posé avant le tampon), un kit ou une source le reprennent et écrivent
# le tampon. Le rail conteneur ne pose rien sur la machine : le canal ne le concerne pas. Le geste
# nommé est celui du canal en place.
VOULU="$(fait channel_tree)"
case "$(fait channel)" in
  ""|aucun|"$VOULU") ;;
  inconnu) ;;
  invalide) POSTE_POURQUOI="le canal d'installation de cette machine est ILLISIBLE (le préflight nomme le fichier) — corrige-le avant de poser quoi que ce soit" ;;
  *) POSTE_POURQUOI="cette machine est installée par « $(fait channel) », et cette porte poserait « $VOULU » — un canal ne se pose pas sur un autre : « sudo deploy/provision uninstall --yes » d'abord (bash install.sh --uninstall le relaie), ou une mise à jour par le même canal (kit : deploy/workstation up --from <kit.tar.gz>, ou cette porte)" ;;
esac

bilan_menu() {
  local etat1 etat2
  if [[ -n "$POSTE_POURQUOI" ]]; then
    etat1="${R}IMPOSSIBLE${N} — $POSTE_POURQUOI"
  else
    etat1="${R}Ça prend${N} : sudo · un groupe système · /opt/lcars · des paquets"
    [[ "$SUBSTRATE" == "wsl" ]] && etat1="${R}Ça prend${N} : sudo · /etc/wsl.conf possédé entier · un groupe système · /opt/lcars"
  fi
  if [[ -n "$CONTENEUR_POURQUOI" ]]; then
    etat2="${R}IMPOSSIBLE${N} — $CONTENEUR_POURQUOI"
  else
    etat2="${R}Ça prend${N} : ~3 Go · ~15 min de build · deux ports · un volume qui survit. Pour tout défaire : reset, 30 s."
  fi
  cat <<EOF

  ${W}Bilan${N} — substrat ${W}$SUBSTRATE${N}, docker ${W}$(fait docker)${N}$(
    [[ -n "$(fait forge_fournie)" ]] && printf ', forge fournie %s' "$(fait forge_joignable)")

  ${BA}1)${N} ${W}TRAVAILLER SUR LCARS${N} — le code sur ce disque, la fleet tourne sous
     l'humain de fleet, le gate en 40 s. la convergence ajoute et ne retire pas.
     $etat1

  ${BA}2)${N} ${W}LE FAIRE TOURNER${N} — un conteneur, et rien hors de ton clone et de docker :
     pas de paquet, pas d'utilisateur, pas de groupe, rien dans /etc ni /usr.
     $etat2

EOF
}

# ⚠ LE REFUS SE JOUE AU CHOIX, PAS AU PARSING. C'est le renversement du canon : on MESURE tout, on
# EXPOSE tout, et on ne refuse qu'au moment où quelqu'un demande ce qui n'est pas possible. Refuser
# plus tôt, c'est refuser une machine qui voulait peut-être l'AUTRE rail.
# ⚠ UN REFUS DONNE LA VOIE QUI MARCHE, sinon il laisse quelqu'un devant un mur. Les deux rails sont
# des sorties l'un pour l'autre : ce qui bloque le poste ne bloque pas le conteneur, et réciproquement.
refuser_rail() { # refuser_rail <1|2> <raison>
  echo ""
  echo "  ${R}Ce rail n'est pas possible ici.${N}"
  echo "  $2"
  if [[ "$1" == "1" ]]; then
    echo "  Sous Windows : « wsl --install -d Ubuntu-24.04 », puis relance ici."
    [[ -z "$CONTENEUR_POURQUOI" ]] \
      && echo "  Ou prends l'autre rail, qui est possible ici :  bash $0 --container"
  else
    echo "  Le conteneur n'installe pas docker (loi 5) : pose-le comme tu l'entends, puis relance."
    [[ -z "$POSTE_POURQUOI" ]] \
      && echo "  Ou donne cette machine au rail poste :  bash $0 --workstation"
  fi
  exit 1
}

if [[ -n "$RAIL" ]]; then
  # Un drapeau de rail est une PRÉ-VALIDATION : l'opérateur a déjà dit ce qu'il veut, on ne le lui
  # redemande pas. Mais il ne dispense pas du refus — ce qui est impossible l'est aussi par drapeau.
  [[ "$RAIL" == "workstation" && -n "$POSTE_POURQUOI" ]] && refuser_rail 1 "$POSTE_POURQUOI"
  [[ "$RAIL" == "container"         && -n "$CONTENEUR_POURQUOI" ]] && refuser_rail 2 "$CONTENEUR_POURQUOI"
else
  bilan_menu
  # `--check` s'arrête ici : il a mesuré et il a dit. Aller plus loin demanderait un rail, donc un
  # choix, donc une mutation — ce qu'une sonde read-only ne fait pas.
  if [[ "$DOCTOR_MODE" -eq 1 || "$DRY_RUN" -eq 1 ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "  ${W}--dry-run${N} sans rail : le bilan est tout. Nomme un rail (--workstation | --container) pour voir la sortie."
    else
      echo "  ${W}--check${N} : le bilan ci-dessus est tout ce qu'une sonde peut dire sans rail choisi."
      echo "  Pour sonder un déploiement existant : deploy/workstation doctor · deploy/container status"
    fi
    exit 0
  fi
  ans=""
  { read -r -p "  ${G}1 ou 2 ?${N} " ans < /dev/tty; } 2>/dev/null || ans="__NO_TTY__"
  case "$ans" in
    1) [[ -n "$POSTE_POURQUOI" ]] && refuser_rail 1 "$POSTE_POURQUOI"; RAIL=workstation ;;
    2) [[ -n "$CONTENEUR_POURQUOI" ]] && refuser_rail 2 "$CONTENEUR_POURQUOI"; RAIL=container ;;
    __NO_TTY__)
      echo ""
      echo "  ${R}Pas de TTY : impossible de demander, et il n'y a pas de défaut sûr.${N}"
      echo "  Redis-le dans la ligne :"
      if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        echo "    bash $0 --workstation    # LCARS s'installe dans ce système"
        echo "    bash $0 --container      # LCARS tourne dans un conteneur"
      else
        # pipée : $0 est « bash », et la forme qui passe des arguments a un script lu sur stdin est -s --
        echo "    curl --proto '=https' --tlsv1.2 -fsSL <porte> | bash -s -- --workstation    # dans ce système"
        echo "    curl --proto '=https' --tlsv1.2 -fsSL <porte> | bash -s -- --container      # dans un conteneur"
      fi
      exit 1 ;;
    *) echo "  ${R}Réponse « $ans » non comprise — rien n'a été fait.${N}"; exit 1 ;;
  esac
fi

# ─── PRÉFLIGHT DE LA BRANCHE ────────────────────────────────────────────────
# Après la question, jamais avant : le conteneur ne prend pas la distro pour cible, et exiger une
# distro vierge plus haut refuserait une machine de travail qui voulait juste lancer un conteneur.
if [[ "$RAIL" == "workstation" ]]; then
  # Le substrat AVANT sudo : hors WSL ce rail est refusé quoi qu'il arrive, et « sudo manque »
  # enverrait installer sudo pour se faire refuser ensuite. `LCARS_ALLOW_ANY_HOST` est lu ici ET
  # dans `00-preflight` — même drapeau, même sens, aux deux étages.
  if [[ "$SUBSTRATE" != "wsl" ]]; then
    if [[ "$SUBSTRATE" == "linux" && -n "${LCARS_ALLOW_ANY_HOST:-}" ]]; then
      echo ""
      echo "  ${AMBER}Linux natif, et tu l'as déclaré DÉDIÉ (LCARS_ALLOW_ANY_HOST).${N}"
      echo "  Ce rail va posséder cette machine : paquets, groupe système, /opt/lcars."
      echo "  « provision uninstall » retire ce que le journal a noté ; le reste, la convergence"
      echo "  ne sait pas le retirer. Et rien de LCARS n'est mesuré sur ce substrat."
    else
      echo ""
      echo "  ${R}--workstation est réservé à WSL2.${N} Sur un Linux ordinaire, LCARS s'installe en conteneur :"
      echo "    bash $0 --container"
      [[ "$SUBSTRATE" == "linux" ]] && {
        echo ""
        echo "  Si cette machine est DÉDIÉE à LCARS et que tu acceptes qu'il la possède :"
        echo "    LCARS_ALLOW_ANY_HOST=1 bash $0 --workstation"
      }
      exit 1
    fi
  fi
  # ⚠ LE REFUS DE `--bench` SUR CE RAIL A DISPARU (§ 13 de `40-RAILS.md`). Il disait « il fournit les
  # annexes à un CONTENEUR ; ici la forge est montée par le provisionnement lui-même, sans drapeau » —
  # et il constatait une CAPACITÉ ABSENTE, pas un choix : `48-forge-host` montait en dur. Il consomme
  # désormais une forge fournie (`FORGE_BASE_URL`), donc les deux rails ont les deux états de l'axe
  # forge, et le drapeau a le même sens des deux côtés : « monte-la-moi ».
  #
  # ⚠ ET IL NE SÈME PLUS D'HUMAIN. C'était le raccourci que le § 13 nomme : `--bench` portait DEUX
  # choses — monter la forge (axe forge) et poser les annexes de démonstration (axe destination) —
  # parce que sur le conteneur les deux coïncidaient. Ouvrir `--bench` au poste sans séparer les deux
  # aurait rendu tous les postes semeurs, ce qui annulerait le canon du 30/08. Depuis, il n'y a
  # plus d'axe destination du tout : seul le banc sème un humain, et il le nomme.

  # `fait sudo` vaut `root` quand on y est déjà, `oui` quand la commande est là, `absent` sinon —
  # trois états mesurés par le module, pas re-sondés ici.
  if [[ "$(fait sudo)" == "absent" ]]; then
    echo ""
    echo "  ${R}sudo est absent, et ce rail en a besoin pour provisionner ce système.${N}"
    echo "  Le conteneur, lui, ne modifie rien :  bash $0 --container"
    exit 1
  fi

  if [[ "$SUBSTRATE" == "wsl" ]] && [[ -f /etc/wsl.conf ]] && ! grep -q "LCARS" /etc/wsl.conf 2>/dev/null; then
    echo ""
    echo "  ${R}/etc/wsl.conf existe et n'est pas le nôtre — ce rail le REMPLACE en entier.${N}"
    echo "  C'est la frontière de sécurité du conteneur (C: fermé, interop coupé), donc il n'est pas"
    echo "  fusionné : tout ce qui suit disparaît, sauvegarde ce qui compte."
    echo ""
    sed 's/^/      /' /etc/wsl.conf
    echo ""
    echo "  Si tu ne veux pas de ça : le conteneur ne touche à rien —  bash $0 --container"
  fi
fi

_box_plain() { printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g'; }
_box_pad() { # <texte> <largeur>
  local p n; p="$(_box_plain "$1")"; n=$(( $2 - ${#p} )); (( n < 0 )) && n=0
  printf '%s%*s' "$1" "$n" ''
}
# _box_emit [--rule] <titre> <ligne…> — `--rule` pose une règle sous le titre. Plancher : 57 colonnes.
_box_emit() {
  local _sep=0
  if [[ "${1:-}" == "--rule" ]]; then _sep=1; shift; fi
  local _title="$1"; shift
  local _w=57 _l _p _rule
  for _l in "$_title" "$@"; do _p="$(_box_plain "$_l")"; (( ${#_p} > _w )) && _w=${#_p}; done
  _rule="$(printf '%*s' "$_w" '' | sed 's/ /─/g')"
  printf '%s  ┌%s┐\n' "$CYAN" "$_rule"
  printf '  │%s%s%s│\n' "$W" "$(_box_pad "$_title" "$_w")" "$CYAN"
  if (( _sep )); then printf '  ├%s┤\n' "$_rule"; fi
  for _l in "$@"; do printf '  │%s%s%s│\n' "$N" "$(_box_pad "$_l" "$_w")" "$CYAN"; done
  printf '  └%s┘%s\n' "$_rule" "$N"
}

# ─── BANDEAU DE LA BRANCHE CHOISIE, ET LUI SEUL ─────────────────────────────
if true; then
cat <<EOF

${AMBER}     ____________________________________________________
    /                                                    \\
   /                ${BA}LCARS FLEET - FEDERATION DATABASE${N}     ${AMBER}\\
  |   ________   __________________________________________\\
  |  |  2026  |  | SOURCE: install.sh
  |  |________|  | SYSTEM: LCARS-FLEET v2 (Elixir/OTP)
  |   ________   | STATUS: INSTALLER — rail ${RAIL}
  |  | AGPL-3 |  |__________________________________________
  |  |________|  \\__________________________________________\\
  |                                                         /
   \\    ${W}"To boldly go where no code has gone before..."${AMBER}    /
    \\_____________________________________________________/${N}
EOF

if [[ "$RAIL" == "workstation" ]]; then
  if [[ "$SUBSTRATE" == "wsl" ]]; then
    _banner_wslconf="  · /etc/wsl.conf, pris en entier."
    _banner_back="  sous WSL il est gratuit — « wsl --unregister »."
  else
    _banner_wslconf=""
    _banner_back="  snapshot ou image, et le rail n'en fournit aucun."
  fi
  # ⚠ CE RAIL NE CRÉE PLUS D'UTILISATEUR, ET LE BANDEAU NE PEUT PAS LE PROMETTRE (⚖ user
  # 2026-08-30). Il annonçait « Ce rail créera l'utilisateur « lcars » » — un compte de
  # DÉMONSTRATION que la recette semait sur tout déploiement, avec un mot de passe posé et annoncé.
  # Un déploiement de travail pose les AUTORITÉS ; les personnes s'inscrivent sur la forge, sous
  # leur nom, et le convergeur les matérialise. Un bandeau qui promet un compte que rien ne créera
  # est la première chose que l'opérateur lira, et la première qui sera fausse.
  echo ""
  echo "  ${AMBER}Ce rail ne crée aucun humain${N} — il pose les autorités : ton siège, l'admin"
  echo "  de la forge, les comptes de service. Les personnes s'inscrivent sur la forge ;"
  echo "  un propriétaire les ajoute à la team « humans » et le convergeur les matérialise"
  echo "  ici (uid libre au-dessus du siège, groupe fleet). Toi, tu restes le siège."
  _banner_body=("  sudo · paquets · groupe fleet · /opt/lcars")
  if [[ -n "$_banner_wslconf" ]]; then _banner_body+=("$_banner_wslconf"); fi
  _banner_body+=(
    "  ${R}Mode dev : la convergence AJOUTE, elle ne retire pas.${N}"
    "  Revenir en arrière demande un point de restauration :"
    "$_banner_back"
    "  Idempotent : relancer est toujours sûr ; « --check »"
    "  sonde sans rien modifier."
    "  Confinement : les pods tournent sous bwrap, et la fleet"
    "  sous l'humain de fleet : le siège a sudo, ses pods aussi."
    "  Pire cas = nuke + re-provision (minutes)."
  )
  # ⚠ CE QUE `--bench` FAIT SUR **CE** RAIL, et rien de plus. La bannière conteneur annonce « forge
  # jetable + runner CI + humain de démo » — les deux derniers sont le BANC, qui n'existe que sur
  # le conteneur. Reprendre cette phrase ici promettrait ce que ce rail ne fait pas.
  if [[ "$WITH_BENCH" -eq 1 ]]; then
    _banner_body+=("  ${W}--bench : la forge est MONTÉE ici, même si FORGE_BASE_URL est posée.${N}")
  fi
  _box_emit "  RAIL POSTE — LCARS s'installe DANS ce système." "${_banner_body[@]}"
else
  _banner_body=(
    "  Pas de paquet, pas d'utilisateur, pas de groupe, rien"
    "  dans /etc ni /usr. ~3 Go d'image, ~15 min de build."
    "  Pour tout défaire : ${W}deploy/container reset${N} — 30 s."
  )
  if [[ "$WITH_BENCH" -eq 1 ]]; then
    _banner_body+=("  ${W}--bench : forge jetable + runner CI + humain de démo.${N}")
  else
    _banner_body+=("  Il te faut une forge : FORGE_BASE_URL + un token.")
  fi
  _box_emit "  RAIL CONTENEUR — rien hors de ton clone et de docker." "${_banner_body[@]}"
fi

echo ""
echo "  ${G}    ▶  Entrée pour continuer${N}  /  ${R}Ctrl+C pour annuler${N}"
echo ""

# Les accolades portent la redirection d'erreur, pas le `read` : sans elles, l'échec de
# `< /dev/tty` est signalé par le shell lui-même, avant la phrase calme qui l'explique.
[[ "$DRY_RUN" -eq 1 ]] || { read -r _ < /dev/tty; } 2>/dev/null || {
  echo "  [install] Pas de TTY — continue automatiquement (le rail est déjà choisi)."
  [[ -n "${LCARS_COLOR_HINT:-}" ]] && echo "  [install] Sortie non-terminal : couleurs coupées (PROV_COLOR=1 pour les garder dans le log)."
}
fi

# ─── LA BRANCHE CONTENEUR : aucune escalade, on délègue à la porte docker ───────
if [[ "$RAIL" == "container" ]]; then
  # ⚠ L'AMORÇAGE `sudo -v` A QUITTÉ CETTE PORTE (D5). Il vivait ici pour amorcer le cache que le shim
  # de `container` consomme commande par commande — mais la porte n'a pas de sudo, par canon. Le fait est
  # EXPOSÉ dans le bilan ; c'est `container` qui demande l'invite, à SON début, s'il en a besoin.
  #
  # Ce que ce bloc lisait était de toute façon MORT depuis E1 : `PROV_DOCKER_DENIED`,
  # `PROV_DOCKER_WHY`, `docker_endpoint`. Trois variables d'une lib que cette porte ne source plus.
  [[ -x "$SCRIPT_DIR/deploy/container" ]] || {
    echo "  ${R}deploy/container introuvable — ce rail exige le checkout complet.${N}"
    echo "  git clone $REPO_URL && cd LCARS-fleet && bash install.sh --container"
    exit 1
  }
  if [[ "$DOCTOR_MODE" -eq 1 ]]; then
    exec "$SCRIPT_DIR/deploy/container" doctor
  fi
  # ─── L'IMAGE EST UNE PRÉCONDITION DES DEUX CHEMINS CONTENEUR, ET C'EST LA PORTE QUI LA FOURNIT ──────
  # ─── L'ARITÉ SE DÉCLARE, ELLE NE SE SUPPOSE PAS ────────────────────────────────────────────────
  #
  # ⚠ CETTE BOUCLE AVANÇAIT DE DEUX EN DEUX, ET UN DRAPEAU DE `PASSTHRU` PEUT ÊTRE IMPAIR. Un
  # drapeau solo poussé dans `PASSTHRU` décale d'un cran tout ce qui le suit, et AUCUN `case` ne
  # le voit : les valeurs partent sur les défauts, et un drapeau du rail POSTE qui devrait être
  # REFUSÉ est avalé sans un mot (vu avec un drapeau solo, retiré depuis).
  #
  # ⚠ L'ARITÉ EST DÉCLARÉE, ET UN DRAPEAU INCONNU EST REFUSÉ. Deviner « c'est sûrement une paire »
  # est exactement ce qui a produit le défaut : le prochain drapeau solo ajouté à `PASSTHRU` le
  # reproduirait en silence. Ici il fait rater la porte, en se nommant. Il n'y a AUCUN solo
  # aujourd'hui ; la branche `1` reste pour que le prochain se déclare au lieu de se deviner.
  passthru_arite() { # passthru_arite <drapeau> -> 2 (drapeau + valeur) · 1 (solo) · 0 (inconnu)
    case "$1" in
      --substrate|--port-forge|--port-deck|--port-ssh|--forge-project|--env|--human|--only) echo 2 ;;
      *) echo 0 ;;
    esac
  }
  _container_reject=()
  _i=0
  while [[ "$_i" -lt "${#PASSTHRU[@]}" ]]; do
    _arite="$(passthru_arite "${PASSTHRU[$_i]}")"
    if [[ "$_arite" -eq 0 ]]; then
      _container_reject+=("${PASSTHRU[$_i]} (arité non déclarée dans la traduction du conteneur — la deviner décalerait tout ce qui suit, en silence)")
      break
    fi
    case "${PASSTHRU[$_i]}" in
      --forge-project)
        if [[ "$WITH_BENCH" -eq 1 ]]; then
          # PRÉPOSÉ : le délégué lit en dernier-gagne, donc un `-- --project X` explicite l'emporte.
          DELEGATE_ARGS=(--project "${PASSTHRU[$((_i + 1))]}" ${DELEGATE_ARGS[@]+"${DELEGATE_ARGS[@]}"})
        else
          export LCARS_BASE="${PASSTHRU[$((_i + 1))]}"   # le conteneur s'appelle <N>-fleet (deploy/container)
        fi ;;
      # ⚠ TROIS PORTS, PAS DEUX, ET LE TROISIEME MANQUAIT. `bench-up.sh` en publie trois — forge,
      # deck et SSH — et refuse net si l'un d'eux est tenu. La porte n'en traduisait que deux : un
      # operateur pouvait donc deplacer la forge et le deck, et se faire refuser sur un port SSH
      # qu'aucun drapeau ne savait bouger.
      #
      # VU : « REFUS : un autre conteneur tient deja un des ports de ce
      # banc · 2222 -> lcars-nuit-lcars-1 ». Le refus est JUSTE — les bancs WSL partagent un meme
      # daemon docker, donc un seul banc par port — mais la sortie qu'il propose (« --ssh-port »)
      # n'existait pas a l'entree. Un refus qui nomme un geste que la porte ne sait pas passer
      # envoie l'operateur contre un mur.
      --port-forge|--port-deck|--port-ssh)
        if [[ "$WITH_BENCH" -eq 1 ]]; then
          case "${PASSTHRU[$_i]}" in
            --port-deck) _d="--deck-port" ;;
            --port-ssh)  _d="--ssh-port" ;;
            *)           _d="--forge-port" ;;
          esac
          DELEGATE_ARGS=("$_d" "${PASSTHRU[$((_i + 1))]}" ${DELEGATE_ARGS[@]+"${DELEGATE_ARGS[@]}"})
        else
          _container_reject+=("${PASSTHRU[$_i]} (les ports du conteneur sont ceux du compose — ajoute --bench, ou edite le compose)")
        fi ;;
      --env|--human|--only)
        _container_reject+=("${PASSTHRU[$_i]} (drapeau du rail POSTE : il pilote « provision », que le conteneur n'appelle pas)") ;;
    esac
    _i=$((_i + _arite))
  done
  if [[ "${#_container_reject[@]}" -gt 0 ]]; then
    echo ""
    echo "  ${R}Ce rail ne peut pas honorer ces options :${N}"
    printf '    %s\n' "${_container_reject[@]}"
    echo "  Rien n'a ete fait. Les accepter sans les lire serait pire que les refuser."
    exit 1
  fi

  if [[ "$WITH_BENCH" -ne 1 && -z "${FORGE_BASE_URL:-}" ]]; then
    echo ""
    echo "  ${R}FORGE_BASE_URL n'est pas posée — le conteneur ne fabrique pas ta forge, il la consomme.${N}"
    echo "  Deux voies :"
    echo "    ${W}--bench${N}                     LCARS monte une forge jetable, un runner et un humain de démo"
    echo "    FORGE_BASE_URL=http://…    tu as déjà une forge  (« deploy/container forge-check »)"
    exit 1
  fi

  # ⚠ LE BUILD D'IMAGE A QUITTÉ CETTE PORTE (D4, `40-RAILS.md` §§ 3 et 6), ET IL N'A PAS DÉMÉNAGÉ :
  # il est MORT ici. Un conteneur de production TIRE son image — épinglée par digest, avec le gate joué
  # UNE FOIS par le rail qui la construit. Un client ne compile pas chez son hôte : il hériterait
  # d'un binaire que personne d'autre n'a vu, sur une machine dont ce n'est pas le métier.
  #
  # `container build` reste, comme geste de DEV, et c'est `container` qui décide s'il en a besoin — il connaît
  # son image, ses tags et son compose. La porte, elle, n'a jamais eu de raison de le savoir : elle
  # sondait `image inspect` avec `PROV_DOCKER_BIN`, une variable morte depuis que le préflight a
  # quitté ce fichier.
  #
  # Les trois témoins qui gardaient ce chemin (image absente / présente / build en échec) suivent
  # dans `container_project.bats` — ce sont des déplacements, pas des suppressions.

  if [[ "$WITH_BENCH" -eq 1 ]]; then
    echo ""
    echo "  ${W}--bench${N} : forge jetable + conteneur + runner CI + humain de démo, en un geste."
    # Le délégué reçoit la résolution du daemon, il ne la refait pas — le fait vient du module.
    DOCKER_BIN="$(fait docker_bin)"; export DOCKER_BIN
    [[ "$DRY_RUN" -eq 0 ]] || sortie_dite "$SCRIPT_DIR/deploy/docker/bench/bench-up.sh" ${DELEGATE_ARGS[@]+"${DELEGATE_ARGS[@]}"}
    exec "$SCRIPT_DIR/deploy/docker/bench/bench-up.sh" ${DELEGATE_ARGS[@]+"${DELEGATE_ARGS[@]}"}
  fi
  echo ""
  [[ "$DRY_RUN" -eq 0 ]] || sortie_dite "$SCRIPT_DIR/deploy/container" up
  echo "  ${W}up${N} — la sortie qui suit est celle de deploy/container"
  exec "$SCRIPT_DIR/deploy/container" up
fi

# ─── LA BRANCHE POSTE : on délègue, comme pour le conteneur ─────────────────────
#
# ⚠ CE BLOC FAISAIT CENT QUARANTE LIGNES, ET C'ÉTAIT LE RAIL ENTIER. Escalade sudo, clone sous
# l'humain, tranche paquets, `provision apply`, lecture du verdict, acceptation, identifiants,
# bandeau de fin : la porte ne choisissait pas un rail, elle en EXÉCUTAIT un. Le canon l'a tranché
# — « le rail poste sédimenté dans install.sh : il SORT, dans son propre script ».
#
# ⚠ ET LE RE-EXEC MEURT AVEC LUI. La porte se relançait sous sudo, donc elle devait se dire de
# sauter l'accueil et la pause qu'elle venait de jouer : `--consented`, un drapeau pour contourner
# un problème qu'elle s'était créé en voulant tout porter. `workstation` n'a ni accueil ni pause :
# son escalade n'a rien à sauter, et `EUID` — un FAIT — lui suffit à reconnaître son second passage.
#
# Le rail poste et le rail conteneur sortent maintenant par la même forme : un `exec` vers un délégué du
# clone, et le code de retour est le sien.
WORKSTATION="$SCRIPT_DIR/deploy/workstation"
[[ -x "$WORKSTATION" ]] || {
  echo "  ${R}deploy/workstation introuvable — ce rail exige le checkout complet.${N}"
  echo "  git clone $REPO_URL && cd LCARS-fleet && bash install.sh --workstation"
  exit 1
}
# ⚠ `--bench` ÉTAIT AVALÉ SUR CE RAIL, ET IL AFFICHAIT UNE PROMESSE. Mesure : les trois usages de
# `WITH_BENCH` en zone de sortie sont tous dans la branche CONTENEUR, et le drapeau n'entre pas dans
# `PASSTHRU` — sur le poste il posait une variable que personne ne lisait, après avoir annoncé
# « forge jetable + runner CI + humain de démo ». Un drapeau accepté qui ne fait rien est pire qu'un
# drapeau refusé : le refus laisse l'opérateur chercher, le silence le laisse croire.
#
# CE QU'IL FAIT ICI, ET C'EST TOUT CE QUE LE § 13 LUI DONNE : l'axe FORGE, « monte-la-moi ». Sur ce
# rail la montée est déjà le défaut quand `FORGE_BASE_URL` est absente ; l'apport du drapeau est donc
# de monter QUAND MÊME si elle est posée. Le runner CI et l'humain de démo sont le BANC, qui
# n'existe que sur le conteneur, et qui nomme son humain lui-même.
if [[ "$WITH_BENCH" -eq 1 ]]; then
  export PROV_FORGE_MONTEE=1
fi
if [[ "$DOCTOR_MODE" -eq 1 ]]; then
  exec "$WORKSTATION" doctor "${PASSTHRU[@]}"
fi
if [[ "$DRY_RUN" -eq 1 ]]; then
  # ce que le RAIL ferait, dit ici parce que c'est la question du drapeau — le sudo est la-bas
  echo "  le rail ferait : sudo provision apply  (canal $VOULU)"
  sortie_dite "$WORKSTATION" up "${PASSTHRU[@]}"
fi
echo ""
echo "  ${W}up${N} — la sortie qui suit est celle de deploy/workstation"
exec "$WORKSTATION" up "${PASSTHRU[@]}"

}

# ⚠ `{ main "$@"; }` ET PAS `main "$@"` — LA DIFFERENCE EST MESUREE, PAS ESTHETIQUE.
#
# `curl | bash` fait lire le script AU FIL DE L'EAU : un flux coupe laisse bash executer ce qu'il a
# deja lu. Tout mettre dans des fonctions et n'appeler qu'a la fin ferme presque le trou — presque :
# une troncature qui tombe exactement sur `main` ou `main ` donne a bash une commande VALIDE sans
# arguments, et il APPELLE la fonction. Deux octets, et tout s'execute.
#
# L'accolade ferme ce reste : `{ main` non fermee est une erreur de syntaxe, jamais une commande.
# Banc a toutes les troncatures possibles (joue hors du depot, non embarque) :
#
#     sans main()      41 fuites / 97
#     main "$@"         2 vraies / 118
#     { main "$@"; }    0 vraies / 123
#
# `curl_bash_2026.md` ecrit « Resolu : la troncature (main(){…} en derniere ligne) ». C'est vrai a
# deux octets pres, et ces deux octets executent le script entier.
#
# RIEN NE DOIT SUIVRE CETTE LIGNE.
{ main "$@"; }
