#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/variable_walls.bats
# AUTHOR: vanille
# STARDATE: 2026-08-27
# STATUS: actif — les invariants d'ECRITURE des variables, tenus par une mesure et non par la relecture

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
}

code_of() { sed 's/#.*//' "$1"; }

# le code bash du dépôt, reconnu à son shebang : hors témoins, arbres bâtis ou jetables, et arbres de
# travail d'autres branches posés sous .claude/worktrees ; un awk par lot de fichiers, pas deux processus par fichier.
# Lisibles seulement : awk meurt sur un fichier qu'il ne peut ouvrir, et le reste de son lot partirait avec lui
bash_code() {
  find "$REPO" \( -path "$REPO/.git" -o -path "$REPO/.claude/worktrees" -o -name tests -o -name _build \
                  -o -name deps -o -name tmp -o -name node_modules \) -prune -o -type f -readable -print0 2>/dev/null \
    | xargs -0 awk 'FNR == 1 { if (/^#!.*(bash|bats)/) print FILENAME; nextfile }' 2>/dev/null | sort
}

@test "instrument : un fichier illisible ne retire pas du périmètre les fichiers bash de son lot" {
  [ "$(id -u)" -ne 0 ] || skip "à jouer sans privilège : root lit un fichier en 000"
  local REPO="$BATS_TEST_TMPDIR/depot" i
  mkdir -p "$REPO/lot"
  for i in $(seq 1 40); do printf '#!/usr/bin/env bash\n' > "$REPO/lot/s$i"; done
  printf '#!/usr/bin/env bash\n' > "$REPO/lot/illisible"; chmod 000 "$REPO/lot/illisible"
  run bash_code
  [ "$(grep -c "^$REPO/lot/s" <<<"$output")" -eq 40 ] || { echo "$output"; return 1; }
}

@test "MUR 1: aucun repli sur une variable que bash pose TOUJOURS" {
  local internes='EUID|UID|PPID|BASHPID|RANDOM|SECONDS|LINENO|SHLVL|GROUPS|PWD|IFS|BASH_VERSION|MACHTYPE|OSTYPE|HOSTTYPE'
  local motif="\\\$\\{($internes):?[-=]"
  local -a BASH_CODE
  mapfile -t BASH_CODE < <(bash_code)

  # GARDE D'INSTRUMENT : un balayage cassé compte zéro, comme un sans-faute ; chaque arbre contribue,
  # et trois membres nommés, un par forme de nom (suffixe, sans suffixe, la porte)
  local t
  for t in deploy runtime/test runtime/bin runtime/services; do
    printf '%s\n' "${BASH_CODE[@]}" | grep -q "^$REPO/$t/" || {
      echo "MUR 1 — l'arbre « $t » ne contribue AUCUN fichier bash au perimetre : l'instrument est casse" >&2
      return 1
    }
  done
  [ "${#BASH_CODE[@]}" -ge 85 ]
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/deploy/lib/deploy-release.sh$'
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/bin/fleet$'
  printf '%s\n' "${BASH_CODE[@]}" | grep -qx "$REPO/install.sh"

  local f n total=0 rompu=0
  for f in "${BASH_CODE[@]}"; do
    n="$(code_of "$f" | grep -cE -- "$motif" || true)"
    [ "$n" -eq 0 ] && continue
    rompu=1
    total=$((total + n))
    echo "MUR 1 rompu — ${f#"$REPO"/} :" >&2
    code_of "$f" | grep -nE -- "$motif" >&2
  done
  [ "$rompu" -eq 0 ] || {
    echo "MUR 1 : $total repli(s) contre une variable que bash pose toujours." >&2
    echo "Le geste : retirer le repli, pas le remplacer par un autre." >&2
    return 1
  }
}

@test "MUR 2: aucun fichier dans la portee de provision-lib ne RECOPIE un defaut qu'elle pose" {
  local lib="$REPO/deploy/lib/provision-lib.sh" constantes="$REPO/deploy/installer-constants.env"
  [ -r "$lib" ] || { echo "provision-lib.sh introuvable : $lib" >&2; return 1; }

  # les noms que la lib pose : les constantes, et ses défauts `: "${X:=valeur}"`
  local poseurs
  poseurs="$( { sed -nE 's/^(PROV_[A-Z0-9_]+)=.+$/\1/p' "$constantes"
                sed 's/#.*//' "$lib" | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{(PROV_[A-Z_]+):=(.+)\}"[[:space:]]*$/\1/p'; } | sort -u)"
  [ -n "$poseurs" ] || { echo "aucun poseur lu dans la lib ni dans les constantes — l'instrument est casse" >&2; return 1; }
  printf '%s\n' "$poseurs" | grep -qx PROV_TOKENS_DIR || { echo "PROV_TOKENS_DIR n'est plus lu parmi les poseurs — l'instrument ne suit plus les constantes" >&2; return 1; }
  printf '%s\n' "$poseurs" | grep -qx PROV_DECK_PORT || { echo "PROV_DECK_PORT n'est plus lu parmi les poseurs — l'instrument ne suit plus la lib" >&2; return 1; }

  # La portee : les fichiers qui sourcent la lib, PLUS le runner qui la source lui-meme.
  local portee
  portee="$(grep -rl '\. "\${PROVISION_LIB' "$REPO/deploy" 2>/dev/null; echo "$REPO/deploy/provision")"
  [ "$(printf '%s\n' "$portee" | wc -l)" -ge 20 ] || {
    echo "portee a $(printf '%s\n' "$portee" | wc -l) fichiers — le balayage est casse" >&2; return 1; }

  local alt; alt="$(printf '%s\n' "$poseurs" | paste -sd'|')"
  local f n src rompu=0
  while read -r f; do
    [ -r "$f" ] || continue
    # le poseur ne vaut qu'après le `source` : une lecture au-dessus est vivante
    src="$(grep -nE '^[[:space:]]*(\.|source)[[:space:]].*(PROVISION_LIB|provision-lib)' "$f" | head -1 | cut -d: -f1)"
    [ -n "$src" ] || continue
    while IFS=: read -r n _; do
      [ -n "$n" ] || continue
      [ "$n" -gt "$src" ] || continue
      echo "MUR 2 rompu — ${f#"$REPO"/}:$n recopie un defaut que provision-lib.sh pose deja :" >&2
      sed -n "${n}p" "$f" | sed 's/^/     /' >&2
      rompu=1
    done < <(sed 's/#.*//' "$f" | grep -nE "\\\$\{($alt):-[^}]+\}")
  done <<<"$portee"

  [ "$rompu" -eq 0 ] || {
    echo "Le geste : lire la variable sans repli. set -u est garanti par le contrat" >&2
    echo "shell.sourcers_set_strict, donc l'absence devient un echec bruyant, pas une valeur inventee." >&2
    return 1
  }
}

@test "MUR 3: aucun motif de temoin n'utilise la classe qui ne veut pas dire ce qu'elle a l'air de dire" {
  local bs; bs="$(printf '\\')"
  local interdit="[^${bs}n]"

  mapfile -t SUITES < <(
    find "$REPO" \( -path "$REPO/.git" -o -path "$REPO/.claude/worktrees" -o -name _build -o -name deps \
                    -o -name tmp -o -name node_modules \) -prune -o -type f \( -name '*.bats' -o -name '*.bash' \) -print \
      2>/dev/null | sort -u
  )
  [ "${#SUITES[@]}" -ge 60 ] || { echo "corpus de temoins a ${#SUITES[@]} fichiers — balayage casse" >&2; return 1; }

  local f n rompu=0
  for f in "${SUITES[@]}"; do
    n="$(grep -cF -- "$interdit" "$f" || true)"
    [ "$n" -eq 0 ] && continue
    rompu=1
    echo "MUR 3 rompu — ${f#"$REPO"/} :" >&2
    grep -nF -- "$interdit" "$f" >&2
  done
  [ "$rompu" -eq 0 ] || {
    echo "Le geste : remplacer par un point. grep travaille ligne a ligne." >&2
    return 1
  }
}

@test "MUR 4: le port du deck a UNE declaration, et les copies du runtime et de l'image s'accordent" {
  local attendu
  attendu="$(sed -nE 's/^PROV_DECK_PORT_DEFAULT=([0-9]+)$/\1/p' "$REPO/deploy/installer-constants.env")"
  [[ "$attendu" =~ ^[0-9]+$ ]] || {
    echo "MUR 4 — PROV_DECK_PORT_DEFAULT illisible dans installer-constants.env : l'autorite ne se lit plus" >&2
    return 1
  }

  # chaque miroir avec son geste : un nombre présent ailleurs dans le fichier ne suffit pas
  local rompu=0
  check() { # check <fichier> <motif etendu> <ce que c'est>
    local f="$REPO/$1"
    [ -r "$f" ] || { echo "MUR 4 rompu — $1 illisible" >&2; rompu=1; return; }
    sed 's/#.*//' "$f" | grep -qE -- "$2" || {
      echo "MUR 4 rompu — $1 ne porte pas « $attendu » pour $3 :" >&2
      sed 's/#.*//' "$f" | grep -nE 'DECK_PORT|LANDING_PORT|20[0-9]{3}' >&2
      rompu=1
    }
  }
  check runtime/services/console-landing.sh   "LCARS_LANDING_PORT:-$attendu\}"        "le port d'ecoute du lanceur"
  check runtime/services/console-deck.py      "LCARS_LANDING_PORT\", \"$attendu\"\)"  "le port d'ecoute du serveur"
  check runtime/services/container/boot.sh    "LCARS_LANDING_PORT:-$attendu\}"        "le pont du rail conteneur"
  check runtime/services/lib/module-protocol.sh "LCARS_LANDING_PORT:=$attendu\}" "le defaut du protocole des modules du produit"
  check deploy/docker/Dockerfile      "LCARS_LANDING_PORT:-$attendu\}"        "la sonde de sante"
  check deploy/docker/docker-compose.yml "\\\$\{PROV_DECK_PORT_DEFAULT:\?[^}]*\}\"$" "la publication du port, lue dans les constantes"

  [ "$rompu" -eq 0 ] || {
    echo "L'autorite est PROV_DECK_PORT_DEFAULT dans installer-constants.env — les copies la suivent." >&2
    return 1
  }
}

@test "MUR 5: le chemin du fichier de siege est le MEME partout, et le manifeste pose celui-la" {
  local sites=(
    "runtime/bin/fleet"
    # le BEAM lit le siege dans Fleet.BootGuard (GUARD B), que config/runtime.exs appelle
    "runtime/lib/fleet/boot_guard.ex"
    # la politique de POPULATION vit ici, une seule fois — c'est ce site que le mur doit voir
    "runtime/services/lib/module-protocol.sh"
    "runtime/services/container/init.sh"
  )
  # les chemins déclarés : la constante de l'installeur, la forme shell `${LCARS_SEAT_UID_FILE:-<X>}`
  # et la forme BEAM `System.get_env("LCARS_SEAT_UID_FILE", "<X>")`
  local f vus=() v lus
  v="$(sed -n 's/^PROV_SEAT_UID_FILE=//p' "$REPO/deploy/installer-constants.env")"
  [ -n "$v" ] || { echo "MUR 5 — PROV_SEAT_UID_FILE illisible dans installer-constants.env" >&2; return 1; }
  vus+=("$v")
  for f in "${sites[@]}"; do
    [ -r "$REPO/$f" ] || { echo "MUR 5 rompu — $f illisible" >&2; return 1; }
    lus="$(sed 's/#.*//' "$REPO/$f" \
             | sed -nE -e 's/.*LCARS_SEAT_UID_FILE:-([^}]+)\}.*/\1/p' \
                       -e 's/.*LCARS_SEAT_UID_FILE", "([^"]+)".*/\1/p' \
                       -e 's/.*@seat_path_default "([^"]+)".*/\1/p')"
    [ -n "$lus" ] || { echo "MUR 5 — aucune declaration lue dans $f : l'instrument ne lit plus la forme" >&2; return 1; }
    while read -r v; do [ -n "$v" ] && vus+=("$v"); done <<<"$lus"
  done
  local distinctes; distinctes="$(printf '%s\n' "${vus[@]}" | sort -u)"
  [ "$(printf '%s\n' "$distinctes" | wc -l)" -eq 1 ] || {
    echo "MUR 5 rompu — ${#vus[@]} declarations, PLUSIEURS chemins :" >&2
    printf '%s\n' "$distinctes" | sed 's/^/     /' >&2
    return 1
  }
  local attendu="$distinctes"
  grep -qE "^anchor[[:space:]]+${attendu//\//\\/}[[:space:]]" "$REPO/deploy/system.manifest" || {
    echo "MUR 5 rompu — les ${#vus[@]} declarations disent « $attendu » et le manifeste ne pose pas ce fichier :" >&2
    grep -nE '^anchor' "$REPO/deploy/system.manifest" >&2
    return 1
  }
}

@test "MUR 6: le groupe de traversee des consoles a UNE declaration, nom ET gid" {
  local nom gid
  nom="$(sed -nE 's/^PROV_CONSOLE_GROUP=([a-z0-9_-]+)$/\1/p' "$REPO/deploy/installer-constants.env")"
  [ -n "$nom" ] || { echo "MUR 6 — PROV_CONSOLE_GROUP illisible dans installer-constants.env" >&2; return 1; }
  # Le gid vient du manifeste, seul endroit ou le groupe est DECLARE avec son numero.
  gid="$(sed -nE "s/^group[[:space:]]+${nom}[[:space:]]+([0-9]+)[[:space:]].*/\1/p" "$REPO/deploy/system.manifest" | head -n1)"
  [[ "$gid" =~ ^[0-9]+$ ]] || {
    echo "MUR 6 rompu — le manifeste ne DECLARE pas le groupe « $nom » avec un gid :" >&2
    grep -nE '^group' "$REPO/deploy/system.manifest" >&2
    return 1
  }

  local rompu=0
  need() { # need <fichier> <motif> <geste>
    sed 's/#.*//' "$REPO/$1" 2>/dev/null | grep -qE -- "$2" || {
      echo "MUR 6 rompu — $1 ne porte pas « $nom » pour $3" >&2; rompu=1; }
  }
  need runtime/services/console.sh          "LCARS_CONSOLE_GROUP:-$nom\}"          "la lecture du lanceur de console"
  need runtime/services/console-landing.sh  "LCARS_CONSOLE_GROUP:-$nom\}"          "la lecture du lanceur de deck"
  need deploy/system.manifest      "^runtime[[:space:]]+/run/lcars/console/<human>[[:space:]]+2710[[:space:]]+<human>:$nom" "la possession du repertoire de socket"

  [ "$rompu" -eq 0 ] || { echo "L'autorite est PROV_CONSOLE_GROUP dans installer-constants.env." >&2; return 1; }
}

@test "MUR 7: ce que l'installeur DECIDE et qu'un daemon lit voyage par la table de transport" {
  local svc="$REPO/deploy/modules.d/64-services.sh" lib="$REPO/deploy/lib/provision-lib.sh"
  [ -r "$svc" ] && [ -r "$lib" ] || { echo "MUR 7 — 64-services ou provision-lib illisible" >&2; return 1; }
  local table; table="$(sed 's/#.*//' "$svc" | sed -n '/services_env_body/,/^}/p' \
                        | sed -nE 's/.*echo "((LCARS|FORGE)_[A-Z_]+)=.*/\1/p' | sort -u)"
  [ -n "$table" ] || { echo "MUR 7 — la table de transport ne se lit plus dans services_env_body" >&2; return 1; }
  local daemons; daemons="$(sed 's/#.*//' "$svc" \
                            | sed -nE 's;.*ExecStart=.*/([a-z0-9-]+\.(sh|py)).*;\1;p' | sort -u)"
  [ "$(printf '%s\n' "$daemons" | grep -c .)" -ge 3 ] || {
    echo "MUR 7 — seulement $(printf '%s\n' "$daemons" | grep -c .) daemon(s) lus dans les ExecStart : l'instrument est casse" >&2
    return 1
  }
  # le jumeau installeur d'un nom produit : LCARS_X -> PROV_X, sauf quatre noms que la table de la lib traduit autrement
  jumeau() { case "$1" in
    FORGE_BASE_URL) echo PROV_FORGE_URL ;; FORGE_PUBLIC_URL) echo PROV_FORGE_PUBLIC_URL ;;
    LCARS_LANDING_PORT) echo PROV_DECK_PORT ;; LCARS_PRIVATE_DIR) echo PROV_TOKENS_DIR ;;
    LCARS_*) echo "PROV_${1#LCARS_}" ;; *) echo "" ;; esac; }
  local d f src v j decidees="" lus=""
  for d in $daemons; do
    f="$REPO/runtime/services/$d"
    [ -r "$f" ] || { echo "MUR 7 — daemon introuvable : services/$d" >&2; return 1; }
    src="$(sed 's/#.*//' "$f")"
    for v in $(grep -oE '(LCARS|FORGE)_[A-Z_]+' <<<"$src" | sort -u); do
      # posee par le daemon lui-meme (assignation dont la droite ne se relit pas) : pas une lecture
      if grep -oE "(^|[;&|[:space:]])(export[[:space:]]+)?$v=[^;]*" <<<"$src" | sed "s/.*$v=//" | grep -qv "$v"; then continue; fi
      j="$(jumeau "$v")"; [ -n "$j" ] || continue
      # décidée par l'installeur : un défaut de la lib, ou une constante qui n'est pas un chemin canonique (ceux-là s'accordent par les murs de chemins)
      grep -qE "^[[:space:]]*:[[:space:]]*\"\\\$\{$j:=|^$j=[^/]" "$lib" "$REPO/deploy/installer-constants.env" || continue
      decidees="$decidees$v\n"
      printf '%s\n' "$table" | grep -qx "$v" || lus="$lus$v (daemon $d)\n"
    done
  done
  decidees="$(printf '%b' "$decidees" | grep . | sort -u)"
  [ "$(printf '%s\n' "$decidees" | grep -c .)" -ge 3 ] || {
    echo "MUR 7 — $(printf '%s\n' "$decidees" | grep -c .) variable(s) decidee(s) par l'installeur lue(s) par un daemon : l'instrument est casse" >&2
    return 1
  }
  [ -z "$(printf '%b' "$lus")" ] || { echo "MUR 7 rompu — lues par un daemon, decidees par l'installeur, ABSENTES de services.env :" >&2; printf '%b' "$lus" >&2; return 1; }
}

@test "MUR 9: le chemin du magasin s'accorde partout avec celui que les constantes de l'installeur declarent" {
  # store.sh possède les noms, installer-constants.env le chemin ; le mur vérifie l'accord de tous les
  # porteurs du dépôt, runtime compris, qui garde ses propres copies
  local lib="$REPO/deploy/lib/store.sh"
  [ -r "$lib" ] || { echo "MUR 9 — store.sh illisible" >&2; return 1; }

  local racine
  racine="$(sed -n 's/^PROV_STORE_ROOT=//p' "$REPO/deploy/installer-constants.env")"
  [ -n "$racine" ] || { echo "MUR 9 — installer-constants.env ne declare plus PROV_STORE_ROOT : l'autorite est illisible" >&2; return 1; }

  local natures
  natures="$(sed -n '/^LCARS_STORE_TREES=(/,/^)/p' "$lib" | sed -nE 's/^  ([a-z]+)\b.*/\1/p')"
  [ "$(printf '%s\n' "$natures" | grep -c .)" -ge 3 ] || {
    echo "MUR 9 — moins de 3 natures lues dans store.sh : l'instrument ne lit plus la liste" >&2; return 1; }

  : > "$BATS_TEST_TMPDIR/vus"
  local f
  while read -r f; do
    [ -r "$f" ] || continue
    # le code seul : commentaires et docstrings Elixir retirés, un mur qui lit la prose interdit de l'écrire
    python3 - "$f" "$racine" <<'PYX' >> "$BATS_TEST_TMPDIR/vus" 2>/dev/null || true
import io, re, sys
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
s = re.sub(r'@(?:module)?doc\s+"""(.*?)"""', '', s, flags=re.S)
s = '\n'.join(re.sub(r'#.*', '', l) for l in s.split('\n'))
racine = sys.argv[2]
for m in re.finditer(r'/var/lib/[A-Za-z0-9_.-]*lcars[A-Za-z0-9_.-]*(?:/([a-z.]+))?', s):
    tete = '/'.join(m.group(0).split('/')[:4])
    print('ORPHELIN:' + tete if tete != racine else (m.group(1) or ''))
PYX
  done < <(grep -rl '/var/lib/.*lcars' "$REPO" --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp --exclude-dir=worktrees \
             --exclude-dir=tests 2>/dev/null | grep -v '/deps/[a-z_]*/')

  [ -s "$BATS_TEST_TMPDIR/vus" ] || { echo "MUR 9 — aucun porteur lu : le balayage est casse" >&2; return 1; }
  local rompu=0 sub
  while read -r sub; do
    [ -n "$sub" ] || continue
    case "$sub" in
      ORPHELIN:*)
        echo "MUR 9 rompu — « ${sub#ORPHELIN:} » ne s'accorde pas avec la racine que les constantes declarent (« $racine »)" >&2
        rompu=1; continue ;;
    esac
    printf '%s\n' "$natures" | grep -qx "$sub" && continue
    echo "MUR 9 rompu — « $racine/$sub » n'est pas une NATURE de LCARS_STORE_TREES" >&2
    rompu=1
  done < <(sort -u "$BATS_TEST_TMPDIR/vus")
  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 11: tout fichier de /etc/lcars est DECLARE par le manifeste, ou nomme ici" {
  # un fichier de configuration machine qui n'est pas au manifeste n'a ni mode ni propriétaire garantis
  local manifeste="$REPO/deploy/system.manifest"
  [ -r "$manifeste" ] || { echo "MUR 11 — manifeste introuvable" >&2; return 1; }

  local declares
  # délimiteur @ : un | de sed couperait l'alternance du motif
  declares="$(sed -nE 's@^(anchor|file|dir|runtime)[[:space:]]+/etc/lcars/([A-Za-z0-9_.-]+)[[:space:]].*@\2@p' "$manifeste" | sort -u)"
  [ "$(printf '%s\n' "$declares" | grep -c .)" -ge 3 ] || {
    echo "MUR 11 — moins de 3 declarations lues sous /etc/lcars : l'instrument ne lit plus le manifeste" >&2
    return 1
  }

  # fleet.json — les réglages de l'administrateur, lus au boot, que le provisionnement ne pose pas
  local hors_manifeste="fleet.json"

  : > "$BATS_TEST_TMPDIR/etcl"
  local f
  while read -r f; do
    [ -r "$f" ] || continue
    python3 - "$f" <<'PYX' >> "$BATS_TEST_TMPDIR/etcl" 2>/dev/null || true
import io, re, sys
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
if '\x00' in s[:4096]: raise SystemExit
s = re.sub(r'@(?:module)?doc\s+"""(.*?)"""', '', s, flags=re.S)
s = '\n'.join(re.sub(r'#.*', '', l) for l in s.split('\n'))
for m in re.finditer(r'/etc/lcars/([A-Za-z0-9_.-]+)', s):
    print(re.sub(r'[.\-]+$', '', m.group(1)))
PYX
  done < <(grep -rl '/etc/lcars/' "$REPO" --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp \
             --exclude-dir=.expert --exclude-dir=tests --exclude-dir=worktrees 2>/dev/null | grep -v '/deps/[a-z_]*/')

  [ -s "$BATS_TEST_TMPDIR/etcl" ] || { echo "MUR 11 — aucun porteur lu : le balayage est casse" >&2; return 1; }
  local rompu=0 nom
  while read -r nom; do
    [ -n "$nom" ] || continue
    printf '%s\n' "$declares" | grep -qx "$nom" && continue
    printf '%s\n' $hors_manifeste | grep -qx "$nom" && continue
    echo "MUR 11 rompu — /etc/lcars/$nom est utilise mais le manifeste ne le declare pas : ni mode," >&2
    echo "   ni proprietaire, ni rail — et rien ne le dira" >&2
    rompu=1
  done < <(sort -u "$BATS_TEST_TMPDIR/etcl")
  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 12: tout fichier grave sous le repertoire des secrets est un fichier que les constantes de l'installeur declarent" {
  # un secret qui apparaîtrait sous un nom que le provisionnement ne déclare nulle part serait un
  # fichier que personne ne crée, lu par quelqu'un qui l'attend ; les porteurs du runtime gardent
  # leurs chemins complets, ce mur exige que leur nom de fichier soit déclaré
  local lib="$REPO/deploy/lib/provision-lib.sh" constantes="$REPO/deploy/installer-constants.env"
  [ -r "$lib" ] || { echo "MUR 12 — provision-lib.sh introuvable" >&2; return 1; }

  local derives jetons
  jetons="$(sed -n 's/^PROV_TOKENS_DIR=//p' "$constantes")"
  derives="$(sed -nE "s@^PROV_[A-Z0-9_]+=${jetons//\//\\/}/([A-Za-z0-9_.-]+)\$@\1@p" "$constantes" | sort -u)"
  [ -n "$derives" ] || {
    echo "MUR 12 — aucun fichier declare sous $jetons dans installer-constants.env : l'instrument est casse" >&2
    return 1
  }

  # forge-role-passwords.json — la carte des mots de passe par role, posee par `provision-forge-charte`
  # et jamais composee par la lib. Nommee ici plutot que laissee passer par un motif.
  local hors_derivation="forge-role-passwords.json"

  : > "$BATS_TEST_TMPDIR/sec"
  local secdir
  secdir="$(env -i PATH="$PATH" bash -c ". '$lib' >/dev/null 2>&1; printf '%s' \"\$PROV_TOKENS_DIR\"")"
  [ -n "$secdir" ] || { echo "MUR 12 — PROV_TOKENS_DIR ne se lit plus dans provision-lib" >&2; return 1; }

  local f
  while read -r f; do
    [ -r "$f" ] || continue
    python3 - "$f" "$secdir" <<'PYX' >> "$BATS_TEST_TMPDIR/sec" 2>/dev/null || true
import io, re, sys
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
if '\x00' in s[:4096]: raise SystemExit
s = re.sub(r'@(?:module)?doc\s+"""(.*?)"""', '', s, flags=re.S)
s = '\n'.join(re.sub(r'#.*', '', l) for l in s.split('\n'))
for m in re.finditer(re.escape(sys.argv[2]) + r'/([A-Za-z0-9_.$-]+)', s):
    nom = re.sub(r'[.\-]+$', '', m.group(1))
    # un nom composé à l'exécution ($SYSTEM_ACCOUNT.gitea_token) ne se lit pas ici
    if nom.startswith('$') or not nom:
        continue
    print(nom)
PYX
  # les témoins (tests/ et runtime/test/) écrivent les chemins qu'ils refusent
  done < <(grep -rl "$secdir/" "$REPO" --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp \
             --exclude-dir=.expert --exclude-dir=tests --exclude-dir=test --exclude-dir=worktrees 2>/dev/null | grep -v '/deps/[a-z_]*/')

  [ -s "$BATS_TEST_TMPDIR/sec" ] || { echo "MUR 12 — aucun porteur lu : le balayage est casse" >&2; return 1; }
  local rompu=0 nom
  while read -r nom; do
    [ -n "$nom" ] || continue
    printf '%s\n' "$derives" | grep -qx "$nom" && continue
    printf '%s\n' "$derives" | grep -q -- "\\${nom##*.}\$" && [ "${nom#*.}" = "gitea_token" ] && continue
    printf '%s\n' $hors_derivation | grep -qx "$nom" && continue
    echo "MUR 12 rompu — $secdir/$nom est grave, mais installer-constants.env ne declare ce nom nulle part" >&2
    rompu=1
  done < <(sort -u "$BATS_TEST_TMPDIR/sec")
  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 13: le compte de service du deck a un nom — les replis du produit et la table le nomment, le groupe du secret en derive" {
  # le groupe du compte porte le secret OIDC du deck : un groupe qui ne dérive pas du compte se crée
  # d'un côté et se chown de l'autre ; la pose du compte sur son groupe éponyme et la traduction de la
  # lib se jouent (modules.d/21-service-accounts.bats, modules.d/thin_callers.bats)
  local nom
  nom="$(sed -nE 's/^PROV_SYSTEM_USER=([a-z0-9_-]+)$/\1/p' "$REPO/deploy/installer-constants.env")"
  [ -n "$nom" ] || { echo "MUR 13 — PROV_SYSTEM_USER ne se lit plus dans installer-constants.env" >&2; return 1; }

  local rompu=0
  need13() { sed 's/#.*//' "$REPO/$1" 2>/dev/null | grep -qE -- "$2" || {
      echo "MUR 13 rompu — $1 ne porte pas « $nom » pour $3" >&2; rompu=1; }; }
  need13 runtime/services/forge.d/deck-oidc.sh "OIDC_GROUP=\"\\\$\{LCARS_SYSTEM_GROUP:-\\\$\{LCARS_SYSTEM_USER:-$nom\}\}\"" \
                                     "le groupe du secret OIDC, dérivé du compte"
  need13 runtime/services/console-landing.sh "LCARS_DECK_USER:-$nom\}"                    "l'identite sous laquelle le deck tourne"
  need13 deploy/system.manifest      "^anchor[[:space:]]+/etc/lcars/deck-oidc.json[[:space:]]+0640[[:space:]]+root:$nom" \
                                     "le proprietaire du secret OIDC"
  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 14: un nom de service compose est une ENTREE DNS et un nom de CONTENEUR — ses lecteurs le derivent" {
  # compose publie le nom d'un service comme entrée DNS du réseau, segment du nom de conteneur
  # (<projet>-<service>-1) et valeur de label : un renommage ne se voit que sur un conteneur neuf
  local rompu=0

  # (1) la forge : le service que forge-compose.yml définit est l'hôte des URL internes, sur son port
  local forge_svc
  forge_svc="$(python3 -c "
import yaml,io
d=yaml.safe_load(io.open('$REPO/deploy/docker/forge-compose.yml'))
print(next(iter((d.get('services') or {}).keys()), ''))" 2>/dev/null)"
  [ -n "$forge_svc" ] || { echo "MUR 14 — le service de forge-compose.yml ne se lit plus" >&2; return 1; }

  # le code seul : un mur qui accuserait un commentaire interdirait d'expliquer le défaut qu'il garde
  local hotes
  hotes="$(grep -rhE 'https?://[a-z][a-z0-9_.-]*:3000' "$REPO" \
             --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp --exclude-dir=.expert \
             --exclude-dir=tests --exclude-dir=test --exclude-dir=worktrees 2>/dev/null \
           | sed 's/#.*//' | grep -oE 'https?://[a-z][a-z0-9_.-]*:3000' \
           | sed -E 's@https?://([a-z][a-z0-9_.-]*):3000@\1@' | sort -u \
           | grep -vE '^(localhost|127\.0\.0\.1|0\.0\.0\.0)$' || true)"
  local port_conteneur
  port_conteneur="$(sed 's/#.*//' "$REPO/deploy/docker/forge-compose.yml" \
                    | sed -nE 's@^[[:space:]]*-[[:space:]]*".*:([0-9]{2,5})"[[:space:]]*$@\1@p' | head -n1)"
  [ -n "$port_conteneur" ] || { echo "MUR 14 — le port du conteneur ne se lit plus dans forge-compose.yml" >&2; return 1; }

  local ports
  ports="$(grep -rhE 'https?://[a-z][a-z0-9_.-]*:[0-9]+' "$REPO" \
             --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp --exclude-dir=.expert \
             --exclude-dir=tests --exclude-dir=test --exclude-dir=worktrees 2>/dev/null \
           | sed 's/#.*//' | grep -oE "https?://$forge_svc:[0-9]+" \
           | sed -E 's@.*:([0-9]+)$@\1@' | sort -u || true)"
  local pt
  for pt in $ports; do
    [ "$pt" = "$port_conteneur" ] && continue
    echo "MUR 14 rompu — une URL interne vise « $forge_svc:$pt » alors que le compose fait ecouter" >&2
    echo "   le conteneur sur $port_conteneur : l'hote est bon, le port ne repond pas" >&2
    rompu=1
  done

  local h
  for h in $hotes; do
    [ "$h" = "$forge_svc" ] && continue
    echo "MUR 14 rompu — une URL interne vise « $h:3000 » alors que le compose definit le service" >&2
    echo "   « $forge_svc » : c'est le nom DNS que le reseau publie, et « $h » n'existe pas" >&2
    rompu=1
  done

  # (2) les noms de conteneur : le segment est un service qu'un des compose définit, quel qu'il soit
  local services
  services="$(python3 -c "
import yaml, io, glob
noms = set()
for f in glob.glob('$REPO/deploy/docker/*compose*.yml'):
    try: d = yaml.safe_load(io.open(f)) or {}
    except Exception: continue
    noms |= set((d.get('services') or {}).keys())
print('\n'.join(sorted(noms)))" 2>/dev/null)"
  [ "$(printf '%s\n' "$services" | grep -c .)" -ge 2 ] || {
    echo "MUR 14 — moins de deux services lus dans les compose : l'instrument est casse" >&2; return 1; }

  local segs
  segs="$(grep -rhoE '\$\{?[A-Z_]*PROJECT\}?-(runner-)?[a-z]+-1' "$REPO/deploy" "$REPO/runtime/bin" "$REPO/runtime/services" \
            --exclude-dir=tests 2>/dev/null \
          | sed -E 's@.*-([a-z]+)-1$@\1@' | sort -u || true)"
  [ -n "$segs" ] || { echo "MUR 14 — aucune reference de conteneur lu : le balayage est casse" >&2; return 1; }
  local sg
  for sg in $segs; do
    printf '%s\n' "$services" | grep -qx "$sg" && continue
    echo "MUR 14 rompu — un nom de conteneur vise le service « $sg », qu'AUCUN compose ne definit :" >&2
    echo "   le conteneur n'existera jamais sous ce nom (services definis : $(printf '%s ' $services))" >&2
    rompu=1
  done

  # (3) les filtres par label : chaque emploi littéral est confronté aux services définis ; une valeur
  # dérivée ($VAR) passe
  local filtres
  filtres="$(grep -rhE 'com\.docker\.compose\.service=' "$REPO/deploy" "$REPO/runtime/bin" "$REPO/runtime/services" \
               --exclude-dir=tests 2>/dev/null \
             | sed 's/#.*//' | grep -oE 'com\.docker\.compose\.service=[A-Za-z0-9_${}-]+' \
             | sed -E 's/^com\.docker\.compose\.service=//' | sort -u || true)"
  local ft
  for ft in $filtres; do
    case "$ft" in '$'*) continue ;; esac
    printf '%s\n' "$services" | grep -qx "$ft" && continue
    echo "MUR 14 rompu — un filtre docker selectionne le service « $ft », qu'AUCUN compose ne" >&2
    echo "   definit : la sonde ne trouvera jamais de conteneur, et son appelant conclura que le" >&2
    echo "   service n'existe pas (services definis : $(printf '%s ' $services))" >&2
    rompu=1
  done

  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 15: AUCUNE adresse de LAN gravee en code — le compte declare est ZERO" {
  # le code livré seul : la prose (commentaires, exemples de README) peut montrer une adresse
  local racines=("$REPO/deploy" "$REPO/install.sh" \
                 "$REPO/runtime/lib" "$REPO/runtime/config" "$REPO/runtime/priv" \
                 "$REPO/runtime/services" "$REPO/runtime/bin" "$REPO/runtime/etc" \
                 "$REPO/catalogues")
  local motif='(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)'

  # GARDE D'INSTRUMENT : aucune adresse n'est attendue, le motif mord donc sur un décor posé ici
  printf 'image: "10.42.0.118:80/fleet/lcars:2"\n' > "$BATS_TEST_TMPDIR/appat.yml"
  grep -hE "$motif" "$BATS_TEST_TMPDIR/appat.yml" >/dev/null || {
    echo "MUR 15 — le motif ne reconnait plus une adresse de LAN : l'instrument est casse" >&2
    return 1
  }
  local r
  for r in "${racines[@]}"; do
    [ -e "$r" ] || { echo "MUR 15 — chemin balaye absent : $r (l'instrument ne lit plus rien)" >&2; return 1; }
  done
  # un appât par racine, fichier ou dossier, ressort des mêmes options de grep
  local sonde="$BATS_TEST_TMPDIR/sonde-mur15"; rm -rf "$sonde"; mkdir -p "$sonde"
  local i=0 r2
  for r2 in "${racines[@]}"; do
    i=$((i + 1))
    if [ -d "$r2" ]; then mkdir -p "$sonde/d$i"; printf 'x 10.42.0.118 x\n' > "$sonde/d$i/appat.sh"
    else printf 'x 10.42.0.118 x\n' > "$sonde/f$i.sh"; fi
  done
  local vus; vus="$(grep -rhE "$motif" "$sonde" 2>/dev/null | grep -cE "$motif" || true)"
  [ "$vus" -eq "${#racines[@]}" ] \
    || { echo "MUR 15 — l'instrument ne voit que $vus appats sur ${#racines[@]} : le balayage ne lit pas ce qu'il annonce" >&2; return 1; }

  local trouvees
  trouvees="$(grep -rhE "$motif" "${racines[@]}" --exclude-dir=tests 2>/dev/null \
              | sed 's/#.*//' | grep -oE "$motif" | sort -u || true)"

  [ -z "$trouvees" ] || {
    echo "MUR 15 rompu — adresse(s) de LAN gravee(s) en code : $(echo $trouvees)" >&2
    echo "   Une adresse de machine dans le code livré ne marche que chez nous : nommer la registry," >&2
    echo "   la forge ou l'hôte par une variable, pas par son IP." >&2
    grep -rnE "$motif" "${racines[@]}" --exclude-dir=tests 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+: *#' | sed 's/^/   /' >&2
    return 1
  }
}

@test "MUR 16: le fichier d'environnement de l'humain — un chemin, deux ecrivains, un lecteur" {
  # le répertoire d'état a une autorité (Fleet.Layout @state_dirname), le nom du fichier n'en a pas :
  # il se compare entre son lecteur (bin/fleet) et ses écrivains
  local dir_etat
  # délimiteur , : @ ouvre @state_dirname
  dir_etat="$(sed -nE 's,^[[:space:]]*@state_dirname[[:space:]]+"([^"]+)".*,\1,p' "$REPO/runtime/lib/fleet/layout.ex" | head -n1)"
  [ -n "$dir_etat" ] || { echo "MUR 16 — @state_dirname ne se lit plus dans Fleet.Layout" >&2; return 1; }

  # Le nom, lu chez le LECTEUR (`bin/fleet`), puis compare chez les ecrivains.
  local nom
  nom="$(sed 's/#.*//' "$REPO/runtime/bin/fleet" \
         | sed -nE "s@.*LCARS_FLEET_ENV:-\\\$HOME/$dir_etat/([A-Za-z0-9_.-]+)\\}.*@\1@p" | head -n1)"
  [ -n "$nom" ] || {
    echo "MUR 16 — le lecteur ne compose plus son chemin depuis « $dir_etat » : bin/fleet a change de forme" >&2
    return 1
  }

  local rompu=0
  need16() { sed 's/#.*//' "$REPO/$1" 2>/dev/null | grep -qF -- "$2" || {
      echo "MUR 16 rompu — $1 ne porte pas « $2 » ($3)" >&2; rompu=1; }; }
  need16 runtime/services/human.d/70-human.sh "$dir_etat/$nom" "l'ecrivain du rail poste"
  need16 runtime/services/human.d/70-human.sh "$nom.template"  "le template dont il derive le fichier"
  [ -r "$REPO/runtime/etc/$nom.template" ] || {
    echo "MUR 16 rompu — etc/$nom.template n'existe pas : l'ecrivain derive d'un fichier absent" >&2
    rompu=1
  }
  # Les DEUX lectures de `bin/fleet` doivent viser le meme fichier — une seule corrigee serait
  # un demarrage qui lit un fichier et un arret qui en lit un autre.
  [ "$(sed 's/#.*//' "$REPO/runtime/bin/fleet" | grep -cF "$dir_etat/$nom")" -ge 2 ] || {
    echo "MUR 16 rompu — bin/fleet ne vise plus le meme fichier a ses deux lectures" >&2
    rompu=1
  }
  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 17: l'image et le port SSH du conteneur ont UNE declaration dans deploy/container, et le compose replie sur la meme valeur" {
  # deploy/container pose et exporte (compose est un fils) ; le compose se joue aussi nu, avec les
  # constantes : son repli SSH est celui de container, et son image par défaut est celle que le checkout bâtit
  local container="$REPO/deploy/container" compose="$REPO/deploy/docker/docker-compose.yml"
  local port img
  port="$(sed 's/#.*//' "$container" | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{LCARS_SSH_PORT:=([^}]+)\}".*$/\1/p' | head -n1)"
  img="$(sed 's/#.*//' "$container"  | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{LCARS_IMAGE:=([^}]+)\}".*$/\1/p' | head -n1)"
  [ -n "$port" ] || { echo "MUR 17 — LCARS_SSH_PORT sans declaration \`: \"\${X:=…}\"\` dans deploy/container" >&2; return 1; }
  [ -n "$img" ] || { echo "MUR 17 — LCARS_IMAGE sans declaration \`: \"\${X:=…}\"\` dans deploy/container" >&2; return 1; }
  [ "$port" = "127.0.0.1:\$PROV_SSH_PORT_DEFAULT" ] || { echo "MUR 17 rompu — deploy/container ne lit pas le port SSH dans les constantes : « $port »" >&2; return 1; }

  local rompu=0 code
  code="$(sed 's/#.*//' "$container")"
  grep -qE '\$\{LCARS_(IMAGE|SSH_PORT):-' <<<"$code" && { echo "MUR 17 rompu — deploy/container porte un repli \${LCARS_IMAGE:-…} ou \${LCARS_SSH_PORT:-…} a cote de sa declaration" >&2; rompu=1; }
  [ "$(grep -cF -- "$img" <<<"$code")" -eq 1 ]  || { echo "MUR 17 rompu — « $img » ecrit plus d'une fois dans deploy/container" >&2; rompu=1; }
  [ "$(grep -cF -- "$port" <<<"$code")" -eq 1 ] || { echo "MUR 17 rompu — « $port » ecrit plus d'une fois dans deploy/container" >&2; rompu=1; }
  grep -qE '^export( +[A-Z_]+)* +LCARS_SSH_PORT( |$)' "$container" || { echo "MUR 17 rompu — LCARS_SSH_PORT non exportee par deploy/container : compose ne la verra pas" >&2; rompu=1; }
  grep -qE '^export( +[A-Z_]+)* +LCARS_IMAGE( |$)' "$container" || { echo "MUR 17 rompu — LCARS_IMAGE non exportee par deploy/container : compose ne la verra pas" >&2; rompu=1; }
  grep -qF -- '${LCARS_SSH_PORT:-127.0.0.1:${PROV_SSH_PORT_DEFAULT:?' "$compose" || { echo "MUR 17 rompu — docker-compose.yml ne replie pas LCARS_SSH_PORT sur 127.0.0.1 et la constante" >&2; rompu=1; }
  # un checkout nomme l'image qu'il bâtit, jamais une image de registre : une version écrite ici se périme à la
  # suivante (v0.9-beta restée dans le kit de v0.9-beta2). Le kit reçoit l'image de sa version de pack.sh (pack.bats)
  grep -qF 'image: "${LCARS_IMAGE:-lcars-fleet:local}"' "$compose" || { echo "MUR 17 rompu — docker-compose.yml n'a pas pour image par defaut lcars-fleet:local, que pack.sh remplace par l'image de la version" >&2; rompu=1; }
  [ "$rompu" -eq 0 ] || { echo "L'autorite est deploy/container (\`: \"\${LCARS_IMAGE:=…}\"\`, \`: \"\${LCARS_SSH_PORT:=…}\"\`) — le compose la lit et replie sur la meme valeur." >&2; return 1; }
}

# ⚠ MUR 18 — LA LECTURE DU SIÈGE TIENT SUR TROIS FAITS QUI NE SE VOIENT PAS ENSEMBLE. Le skill
# `system-issues` du siège lit `forge.url` dans le dossier des jetons. Il ne peut le faire que si :
# le dossier est TRAVERSABLE par le groupe fleet (0710, groupe fleet), le fichier est LISIBLE
# (0644), et le siège EST dans fleet (20-groups l'y met, et ne met que lui). Retirer l'un des trois
# ne casse rien de visible ici : c'est la boîte de réception d'un humain qui devient muette sur une
# machine, et personne ne relie la cause à l'effet. Les trois se mesurent donc ensemble.
@test "MUR 18: le siège lit forge.url — dossier traversable, fichier lisible, siège dans fleet" {
  local manifeste="$REPO/deploy/system.manifest"
  local jetons; jetons="$(sed -n 's/^PROV_TOKENS_DIR=//p' "$REPO/deploy/installer-constants.env")"
  [ -n "$jetons" ] || { echo "MUR 18 — PROV_TOKENS_DIR illisible dans installer-constants.env" >&2; return 1; }

  # 1. le dossier : traversable par fleet, et non listable
  local ligne; ligne="$(awk -v p="$jetons" '$1 == "dir" && $2 == p { print $3, $4 }' "$manifeste")"
  [ "$ligne" = "0710 lcars-authority:fleet" ] \
    || { echo "MUR 18 rompu — $jetons déclaré « $ligne », attendu « 0710 lcars-authority:fleet » : le siège ne traverse plus" >&2; return 1; }

  # 2. le fichier : écrit 0644 au groupe fleet, sur LES DEUX rails (le poste et l'init du conteneur)
  local poste conteneur
  poste="$(grep -c 'write_atomic "\$PROV_FORGE_URL_FILE" 0644 "root:\$PROV_FLEET_GROUP"' "$REPO/deploy/modules.d/48-forge-host.sh")"
  conteneur="$(grep -c 'write_atomic "\$f" 0644 "root:\$LCARS_FLEET_GROUP"' "$REPO/runtime/services/container/init.sh")"
  [ "$poste" -ge 1 ] || { echo "MUR 18 rompu — le poste n'écrit plus forge.url en 0644 root:fleet" >&2; return 1; }
  [ "$conteneur" -ge 1 ] || { echo "MUR 18 rompu — l'init du conteneur n'écrit plus forge.url en 0644 root:fleet" >&2; return 1; }

  # 3. le siège dans fleet : 20-groups le pose, et le drift qu'il émet NOMME la conséquence
  local groupes="$REPO/deploy/modules.d/20-groups.sh"
  grep -q 'ne traverse pas \$PROV_TOKENS_DIR' "$groupes" \
    || { echo "MUR 18 rompu — 20-groups ne relie plus l'appartenance du siège à la traversée du dossier des jetons" >&2; return 1; }

  # 4. et c'est bien ce chemin que le skill lit — sinon les trois faits ci-dessus ne servent personne
  grep -q 'LCARS_PRIVATE_DIR:-/opt/lcars/var/tokens' "$REPO/runtime/services/admiral/skills/system-issues/list.sh" \
    || { echo "MUR 18 rompu — le skill du siège ne lit plus forge.url dans le dossier des jetons" >&2; return 1; }
}

# ⚠ MUR 19 — L'ORG SYSTÈME A UN NOM, ÉCRIT HUIT FOIS. L'installeur le décide (`PROV_FORGE_ORG_DEFAULT`),
# le protocole des gestes, les deux daemons python et le convergeur le lisent en `LCARS_FORGE_ORG` avec
# un défaut, la recette le porte en `system_org`, le geste de forge en `SYSTEM_ORG`, et le dépôt système
# (`Fleet.Toolchain.ops_repo/0`, ses copies shell) vit dans cette org. Aucun de ces lecteurs ne peut
# dériver le nom d'un autre (un daemon en boucle ne source pas la lib de l'installeur ; tofu ne lit pas
# l'env du produit), donc l'égalité se mesure. Une seule copie qui diverge, et la team `humans` ou le
# dépôt `_ops` sont cherchés dans une org qui n'existe pas — sans qu'aucun message ne nomme la cause.
@test "MUR 19: l'org système porte le même nom chez l'installeur, le protocole, la recette, le geste, les daemons et le dépôt système" {
  local attendu; attendu="$(sed -n 's/^PROV_FORGE_ORG_DEFAULT=//p' "$REPO/deploy/installer-constants.env")"
  [ -n "$attendu" ] || { echo "MUR 19 — PROV_FORGE_ORG_DEFAULT illisible dans installer-constants.env" >&2; return 1; }

  local -a lectures=(
    "runtime/services/lib/module-protocol.sh|^: \"\\\${LCARS_FORGE_ORG:=\([^}]*\)}\"\$|le protocole des gestes"
    "runtime/services/forge-gestures.sh|^SYSTEM_ORG=\"\\\${LCARS_FORGE_ORG:-\([^}]*\)}\"\$|le geste de forge"
    "runtime/services/human-converger.sh|^ORG=\"\\\${LCARS_FORGE_ORG:-\([^}]*\)}\"\$|le convergeur d'humains"
    "runtime/services/catalogue-executor.py|^FORGE_ORG = os.environ.get(\"LCARS_FORGE_ORG\", \"\([^\"]*\)\")\$|l'exécuteur de catalogue"
    "runtime/services/console-deck.py|^FORGE_ORG = os.environ.get(\"LCARS_FORGE_ORG\", \"\([^\"]*\)\")\$|le deck"
    "runtime/lib/fleet/toolchain.ex|^  def ops_repo, do: Application.get_env(:lcars_fleet, :pilot_ops_repo, \"\([^/\"]*\)/[^\"]*\")\$|le dépôt système du runtime"
    "runtime/services/admiral/skills/system-issues/list.sh|^OPS_REPO=\"\\\${LCARS_OPS_REPO:-\([^/}]*\)/[^}]*}\"\$|le skill du siège"
    "runtime/bin/lcars-toolchain-converge|^OPS_REPO=\"\\\${LCARS_OPS_REPO:-\([^/}]*\)/[^}]*}\"\$|le convergeur d'outillage"
  )
  local l f motif qui lu manque=""
  for l in "${lectures[@]}"; do
    IFS='|' read -r f motif qui <<<"$l"
    lu="$(sed -n "s|$motif|\1|p" "$REPO/$f" | head -n1)"
    [ -n "$lu" ] || { echo "MUR 19 — instrument cassé : $qui ($f) ne porte plus la ligne attendue" >&2; return 1; }
    [ "$lu" = "$attendu" ] || manque="$manque\n  $qui ($f) : « $lu », attendu « $attendu »"
  done
  # le produit : `Fleet.Catalogue` porte le même défaut, pour l'org où vit le magasin des catalogues
  lu="$(sed -n 's/^  @system_org_default "\([^"]*\)"$/\1/p' "$REPO/runtime/lib/fleet/catalogue.ex" | head -n1)"
  [ -n "$lu" ] || { echo "MUR 19 — instrument cassé : Fleet.Catalogue ne déclare plus @system_org_default" >&2; return 1; }
  [ "$lu" = "$attendu" ] || manque="$manque\n  Fleet.Catalogue (runtime/lib/fleet/catalogue.ex) : « $lu », attendu « $attendu »"

  # le runtime : hors de la table (sa ligne porte un « || » d'Elixir, que le séparateur mangerait)
  lu="$(sed -n 's/.*System.get_env("LCARS_FORGE_ORG", "\([^"]*\)").*/\1/p' "$REPO/runtime/config/runtime.exs" | head -n1)"
  [ -n "$lu" ] || { echo "MUR 19 — instrument cassé : runtime.exs ne dérive plus le dépôt du système de l'org" >&2; return 1; }
  [ "$lu" = "$attendu" ] || manque="$manque\n  le runtime (runtime/config/runtime.exs) : « $lu », attendu « $attendu »"

  # le geste ops-repo et le protocole DÉRIVENT le dépôt de l'org : une org renommée l'emmène
  grep -q '^: "\${LCARS_OPS_REPO:=\${LCARS_FORGE_ORG}/_ops}"$' "$REPO/runtime/services/forge.d/ops-repo.sh" \
    || { echo "MUR 19 rompu — le geste ops-repo ne dérive plus le dépôt du système de l'org" >&2; return 1; }
  grep -q '^: "\${LCARS_OPS_REPO:=\${LCARS_FORGE_ORG}/_ops}"$' "$REPO/runtime/services/lib/module-protocol.sh" \
    || { echo "MUR 19 rompu — le protocole ne dérive plus le dépôt du système de l'org" >&2; return 1; }
  # la recette : le défaut de `system_org`, lu dans son bloc et pas ailleurs
  lu="$(awk '/^variable "system_org" \{/ { in_bloc = 1 } in_bloc && /^  default/ { gsub(/.*= *"|".*/, ""); print; exit }' \
        "$REPO/runtime/services/forge-recipe/forge.tf")"
  [ -n "$lu" ] || { echo "MUR 19 — instrument cassé : la recette ne porte plus variable \"system_org\" avec un défaut" >&2; return 1; }
  [ "$lu" = "$attendu" ] || manque="$manque\n  la recette (system_org) : « $lu », attendu « $attendu »"
  [ -z "$manque" ] || { echo "MUR 19 rompu — des lecteurs de l'org système ne portent pas le nom que l'installeur décide :" >&2; printf '%b\n' "$manque" >&2; return 1; }
}

# ⚠ MUR 21 — LCARS EST UN PROJET DE LA FLEET QU'IL INSTALLE, ET CE PROJET A UN SEUL NOM. La source
# dont une machine est installée est la FACE DE CODE d'un projet (`Fleet.Layout.system_project/0`),
# pas un arbre posé à côté : son répertoire sur disque, le dépôt que le banc sème et l'adresse que
# le conteneur clone sont le même objet. Avant, c'était `/home/projects/LCARS` sur disque et
# `<org>/lcars` sur la forge — deux noms pour une chose, que rien ne tenait ensemble.
@test "MUR 21: le projet du système porte le même nom dans le layout, l'init du conteneur, le rail conteneur et le banc" {
  local attendu
  attendu="$(sed -n 's/^  @system_project "\([^"]*\)"$/\1/p' "$REPO/runtime/lib/fleet/layout.ex")"
  [ -n "$attendu" ] || { echo "MUR 21 — Fleet.Layout ne déclare plus @system_project" >&2; return 1; }

  local -a lectures=(
    "runtime/services/container/init.sh|^  local src=\"\\\${LCARS_SOURCE_DIR:-/home/projects/\([a-z0-9-]*\)}\".*\$|l'init du conteneur"
    "deploy/container|^SOURCE_DANS_CONTENEUR=/home/projects/\([a-z0-9-]*\)\$|le rail conteneur"
    "deploy/docker/bench/bench-up.sh|^SOURCE_IN=\"/home/projects/\([a-z0-9-]*\)\"\$|la source dans le conteneur du banc"
    "deploy/docker/bench/bench-up.sh|^PROJET_SYSTEME=\([a-z0-9-]*\)\$|le dépôt semé par le banc"
  )
  local l f motif qui lu manque=""
  for l in "${lectures[@]}"; do
    IFS='|' read -r f motif qui <<<"$l"
    lu="$(sed -n "s|$motif|\1|p" "$REPO/$f" | head -n1)"
    [ -n "$lu" ] || { echo "MUR 21 — instrument cassé : $qui ($f) ne porte plus la ligne attendue" >&2; return 1; }
    [ "$lu" = "$attendu" ] || manque="$manque\n  $qui ($f) : « $lu », attendu « $attendu »"
  done
  # le compose du banc clone ce dépôt : son URL porte le même nom
  grep -q "/$attendu.git\"\$" "$REPO/deploy/docker/docker-compose.bench.yml" \
    || { echo "MUR 21 rompu — le compose du banc ne clone pas « $attendu »" >&2; return 1; }
  [ -z "$manque" ] || { echo "MUR 21 rompu — des lecteurs du projet du système ont dérivé :" >&2; printf '%b\n' "$manque" >&2; return 1; }
}

# ⚠ MUR 20 — LE CATALOGUE DE LA RELEASE A UN NOM, ET C'EST LE SIEN. `Fleet.Catalogue.bundled_name/0`
# le gèle pour le runtime, `priv/catalogue/catalogue.yaml` le déclare, et l'installeur le recopie
# (`PROV_BUNDLED_CATALOGUE`) parce qu'un compose de banc ne peut pas le demander à une release qui
# n'est pas encore lancée. Ce n'est PAS l'org système (MUR 19) : un catalogue nomme l'org de ses projets.
@test "MUR 20: le catalogue embarqué porte le même nom dans son manifeste, dans Fleet.Catalogue et chez l'installeur, et ce nom n'est pas l'org système" {
  local manifeste runtime installeur systeme
  manifeste="$(awk '/^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t]*#.*$/, ""); gsub(/"/, ""); print; exit }' "$REPO/runtime/priv/catalogue/catalogue.yaml")"
  runtime="$(sed -n 's/^  @bundled_name "\([^"]*\)"$/\1/p' "$REPO/runtime/lib/fleet/catalogue.ex")"
  installeur="$(sed -n 's/^PROV_BUNDLED_CATALOGUE=//p' "$REPO/deploy/installer-constants.env")"
  systeme="$(sed -n 's/^PROV_FORGE_ORG_DEFAULT=//p' "$REPO/deploy/installer-constants.env")"
  [ -n "$manifeste" ] && [ -n "$runtime" ] && [ -n "$installeur" ] \
    || { echo "MUR 20 — instrument cassé : manifeste « $manifeste », runtime « $runtime », installeur « $installeur »" >&2; return 1; }
  [ "$manifeste" = "$runtime" ] && [ "$runtime" = "$installeur" ] \
    || { echo "MUR 20 rompu — manifeste « $manifeste », Fleet.Catalogue « $runtime », PROV_BUNDLED_CATALOGUE « $installeur »" >&2; return 1; }
  [ "$installeur" != "$systeme" ] \
    || { echo "MUR 20 rompu — le catalogue embarqué porte le nom de l'org système « $systeme » : ses projets vivraient dans l'org du système" >&2; return 1; }
}

# ⚠ MUR 23 — L'HUMAIN DE DÉMONSTRATION D'UN BANC EST UN COMPTE DE FORGE, ET SUR GITEA UNE ORG *EST*
# UN UTILISATEUR : les deux partagent un espace de noms. La structure de la forge pose, dans LE MÊME
# plan tofu, l'org système, l'org du catalogue embarqué, le compte système et cet humain. Deux d'entre
# eux du même nom, et le plan meurt en « user already exists », sur une ligne qui parle d'org — mesuré
# le 2026-09-17 sur un banc vierge. Ce mur tient les noms écartés à la source, une fois pour les deux
# rails ; les refus de `provision-lib.sh`, `bench.sh` et `forge-gestures.sh` tiennent ce qu'un
# opérateur tape, que ce mur ne voit pas.
@test "MUR 23: l'humain de démonstration d'un banc ne porte aucun nom que la recette de la forge pose" {
  local humain org catalogue compte
  humain="$(sed -n 's/^PROV_BENCH_HUMAN_DEFAULT=//p' "$REPO/deploy/installer-constants.env")"
  org="$(sed -n 's/^PROV_FORGE_ORG_DEFAULT=//p' "$REPO/deploy/installer-constants.env")"
  catalogue="$(sed -n 's/^PROV_BUNDLED_CATALOGUE=//p' "$REPO/deploy/installer-constants.env")"
  compte="$(sed -n 's/^SYSTEM_ACCOUNT="${LCARS_SYSTEM_ACCOUNT:-\([^}]*\)}"$/\1/p' "$REPO/runtime/services/forge-gestures.sh")"
  [ -n "$humain" ] && [ -n "$org" ] && [ -n "$catalogue" ] && [ -n "$compte" ] \
    || { echo "MUR 23 — instrument cassé : humain « $humain », org « $org », catalogue « $catalogue », compte « $compte »" >&2; return 1; }

  local pris
  for pris in "$org" "$catalogue" "$compte"; do
    [ "$humain" != "$pris" ] \
      || { echo "MUR 23 rompu — l'humain de démonstration « $humain » porte un nom que la recette pose : la structure de la forge mourrait en « user already exists »" >&2; return 1; }
  done
}

# ⚠ MUR 23 (suite) — CE NOM S'ÉCRIT DANS DE LA PROSE, et une prose qui ment oriente tout le monde.
# Les aides de `install.sh`, `deploy/workstation` et des scripts de banc annoncent le défaut à
# l'opérateur ; `installer_constants.bats` ne balaie pas les valeurs d'un seul mot, donc rien
# d'autre ne tient cette recopie.
@test "MUR 23: toute aide qui annonce le défaut de l'humain de démonstration annonce la constante" {
  local humain f ligne trouvees=0
  humain="$(sed -n 's/^PROV_BENCH_HUMAN_DEFAULT=//p' "$REPO/deploy/installer-constants.env")"
  [ -n "$humain" ]
  for f in "$REPO/install.sh" "$REPO/deploy/workstation" "$REPO/deploy/docker/bench/bench-up.sh" \
           "$REPO/deploy/docker/bench/bench-swap-image.sh"; do
    while IFS= read -r ligne; do
      trouvees=$((trouvees + 1))
      [[ "$ligne" == *"$humain"* ]] \
        || { echo "MUR 23 rompu — $f annonce un défaut qui n'est pas « $humain » :$ligne" >&2; return 1; }
    done < <(grep -E '^#.*(--humain-demo.*défaut [a-z]+|\[--human [a-z]+\]|, [a-z]+ / toto)' "$f" || true)
  done
  [ "$trouvees" -ge 4 ] \
    || { echo "MUR 23 — instrument cassé : $trouvees ligne(s) d'aide trouvée(s), au moins 4 attendues" >&2; return 1; }
}
