#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/variable_walls.bats
# AUTHOR: vanille
# STARDATE: 2026-08-27
# STATUS: actif — les invariants d'ECRITURE des variables, tenus par une mesure et non par la relecture

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES

  mapfile -t BASH_CODE < <(
    find "$REPO" -type f \
      -not -path '*/tests/*' -not -path '*/_build/*' -not -path '*/deps/*' -not -path '*/.git/*' \
      2>/dev/null \
      | while read -r f; do
          head -1 "$f" 2>/dev/null | grep -qE '^#!.*(bash|bats)' && echo "$f"
        done | sort
  )
}

code_of() { sed 's/#.*//' "$1"; }

@test "MUR: le perimetre n'est pas VIDE — un balayage casse compte zero, comme un sans-faute" {
  local t
  # `runtime/etc` ne contribue plus (Q3, 2026-09-04) : ses outils d'install sont dans `deploy/lib`.
  for t in deploy runtime/test runtime/bin runtime/services; do
    printf '%s\n' "${BASH_CODE[@]}" | grep -q "^$REPO/$t/" || {
      echo "MUR 0 rompu — l'arbre « $t » ne contribue AUCUN fichier bash au perimetre" >&2
      return 1
    }
  done
  [ "${#BASH_CODE[@]}" -ge 85 ]
  # Trois membres NOMMES, un par forme de nom : suffixe, sans suffixe, et le fichier meme pour
  # lequel ce mur a ete ecrit. Si `install.sh` sort du perimetre, c'est ici que ca rougit.
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/deploy/lib/deploy-release.sh$'
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/bin/fleet$'
  printf '%s\n' "${BASH_CODE[@]}" | grep -q '/deploy/lib/provision-lib.sh$'
}

@test "MUR 1: aucun repli sur une variable que bash pose TOUJOURS" {
  local internes='EUID|UID|PPID|BASHPID|RANDOM|SECONDS|LINENO|SHLVL|GROUPS|PWD|IFS|BASH_VERSION|MACHTYPE|OSTYPE|HOSTTYPE'

  local motif="\\\$\\{($internes):?[-=]"

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
  local lib="$REPO/deploy/lib/provision-lib.sh"
  [ -r "$lib" ] || { echo "provision-lib.sh introuvable : $lib" >&2; return 1; }

  # Les noms poses a une valeur NON VIDE. `sed` sur la forme `: "${X:=valeur}"`.
  local poseurs
  poseurs="$(sed 's/#.*//' "$lib" | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{(PROV_[A-Z_]+):=(.+)\}"[[:space:]]*$/\1/p' | sort -u)"
  [ -n "$poseurs" ] || { echo "aucun poseur lu dans la lib — l'instrument est casse" >&2; return 1; }
  [ "$(printf '%s\n' "$poseurs" | wc -l)" -ge 15 ] || {
    echo "seulement $(printf '%s\n' "$poseurs" | wc -l) poseurs lus — le motif ne suit plus la lib" >&2; return 1; }

  # La portee : les fichiers qui sourcent la lib, PLUS le runner qui la source lui-meme.
  local portee
  portee="$(grep -rl '\. "\${PROVISION_LIB' "$REPO/deploy" "$REPO/runtime/etc" 2>/dev/null; echo "$REPO/deploy/provision")"
  [ "$(printf '%s\n' "$portee" | wc -l)" -ge 20 ] || {
    echo "portee a $(printf '%s\n' "$portee" | wc -l) fichiers — le balayage est casse" >&2; return 1; }

  local alt; alt="$(printf '%s\n' "$poseurs" | paste -sd'|')"
  local f n src rompu=0
  while read -r f; do
    [ -r "$f" ] || continue
    # ⚠ LE POSEUR NE VAUT QU'APRES LE `source`. Une lecture au-dessus de cette ligne est VIVANTE, et
    # l'ignorer accuserait un repli legitime — la faute symetrique de celle qu'on repare.
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
    find "$REPO" "$REPO/../.claude" -type f \( -name '*.bats' -o -name '*.bash' \) \
      -not -path '*/_build/*' -not -path '*/deps/*' 2>/dev/null | sort -u
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

@test "MUR 4: le port du deck a UNE declaration, et les copies s'accordent" {
  local attendu
  attendu="$(sed 's/#.*//' "$REPO/deploy/lib/provision-lib.sh" \
             | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{PROV_DECK_PORT:=([0-9]+)\}".*$/\1/p' | head -n1)"
  [[ "$attendu" =~ ^[0-9]+$ ]] || {
    echo "MUR 4 — PROV_DECK_PORT illisible dans provision-lib.sh : l'autorite ne se lit plus" >&2
    return 1
  }

  # Chaque miroir avec SON geste. Un nombre present ailleurs dans le fichier ne doit pas suffire —
  # `MUR 4 bis` d'`adminite_walls` a coute cette lecon le meme jour.
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
  check deploy/docker/docker-compose.yml         ":$attendu\}:$attendu\""     "la publication du port"
  check deploy/docker/Dockerfile      "LCARS_LANDING_PORT:-$attendu\}"        "la sonde de sante"
  check deploy/docker/bench/bench-up.sh          "DECK_PORT=\"$attendu\""     "le banc"
  check deploy/docker/bench/bench-swap-image.sh  "DECK_PORT=\"$attendu\""     "le banc"

  [ "$rompu" -eq 0 ] || {
    echo "L'autorite est PROV_DECK_PORT dans provision-lib.sh — les copies la suivent." >&2
    return 1
  }
}

@test "MUR 5: le chemin du fichier de siege est le MEME partout, et le manifeste pose celui-la" {
  local sites=(
    "runtime/bin/fleet"
    "runtime/config/runtime.exs"
    "runtime/services/human-converger.sh"
    "deploy/modules.d/64-services.sh"
    "runtime/services/container/boot.sh"
    "deploy/lib/provision-lib.sh"
  )
  # Les chemins DECLARES, captures a la source : la forme shell `${LCARS_SEAT_UID_FILE:-<X>}` et la
  # forme BEAM `System.get_env("LCARS_SEAT_UID_FILE", "<X>")`.
  local f vus=() v
  for f in "${sites[@]}"; do
    [ -r "$REPO/$f" ] || { echo "MUR 5 rompu — $f illisible" >&2; return 1; }
    while read -r v; do [ -n "$v" ] && vus+=("$v"); done < <(
      sed 's/#.*//' "$REPO/$f" \
        | sed -nE -e 's/.*LCARS_SEAT_UID_FILE:-([^}]+)\}.*/\1/p' \
                  -e 's/.*LCARS_SEAT_UID_FILE", "([^"]+)".*/\1/p'
    )
  done
  [ "${#vus[@]}" -ge 6 ] || {
    echo "MUR 5 — seulement ${#vus[@]} declarations lues sur ${#sites[@]} fichiers : l'instrument ne lit plus la forme" >&2
    printf '   vu: %s\n' "${vus[@]}" >&2
    return 1
  }
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
  nom="$(sed 's/#.*//' "$REPO/deploy/lib/provision-lib.sh" \
         | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{PROV_CONSOLE_GROUP:=([a-z0-9_-]+)\}".*$/\1/p' | head -n1)"
  [ -n "$nom" ] || { echo "MUR 6 — PROV_CONSOLE_GROUP illisible dans provision-lib.sh" >&2; return 1; }
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
  need deploy/modules.d/20-groups.sh "ensure_group \"\\\$PROV_CONSOLE_GROUP\""    "la creation sur le rail natif"
  need deploy/system.manifest       "^runtime[[:space:]]+/run/lcars/console/<human>[[:space:]]+2710[[:space:]]+<human>:$nom" "la possession du repertoire de socket"

  [ "$rompu" -eq 0 ] || { echo "L'autorite est PROV_CONSOLE_GROUP dans provision-lib.sh." >&2; return 1; }
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
  # le jumeau installeur d'un nom produit : LCARS_X -> PROV_X, sauf les quatre noms que le lot 8 a
  # rapproches d'un nom que le produit possedait deja
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
      grep -qE "^[[:space:]]*:[[:space:]]*\"\\\$\{$j:=" "$lib" || continue   # pas decidee par l'installeur
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
  # TEMOIN APPARIE : une entree retiree de la table doit rougir — la premiere decidee sert de sonde
  local sonde; sonde="$(printf '%s\n' "$decidees" | head -1)"
  printf '%s\n' "$table" | grep -qx "$sonde"
}

@test "MUR 8: l'override genere nomme le service que la base DEFINIT, et sa prose ne s'execute pas" {
  local src="$REPO/deploy/docker/forge-runner.sh" base="$REPO/deploy/docker/runner-compose.yml"
  [ -r "$src" ] && [ -r "$base" ] || { echo "MUR 8 — source ou base illisible" >&2; return 1; }

  # (1) Le nom se DERIVE de la base, il ne se recopie pas : le script doit le lire, pas l'ecrire.
  grep -qE 'SERVICE="\$\(sed' "$src" || {
    echo "MUR 8 rompu — forge-runner.sh ne DERIVE plus le nom du service de runner-compose.yml" >&2
    return 1
  }
  # (2) Et aucun nom de service en dur ne subsiste dans le heredoc de l'override.
  # ⚠ LE MOTIF DE PLAGE ETAIT INERTE, ET SEULE LA MUTATION L'A MONTRE. Il disait
  # `/override.yml <</` alors que la ligne porte `…override.yml" <<EOF` — un guillemet entre les
  # deux. La plage ne capturait RIEN, donc ce controle passait au vert sans rien lire, y compris
  # quand on recodait le nom du service en dur. Un mur vert qui n'a rien lu est le defaut que ce
  # fichier existe pour interdire, commis en l'ecrivant.
  local codees; codees="$(sed -n '/override\.yml.*<</,/^EOF$/p' "$src" | sed -nE 's/^  ([a-z][a-z0-9_-]+):[[:space:]]*$/\1/p' | grep -v '^default$' || true)"
  [ -z "$codees" ] || {
    echo "MUR 8 rompu — l'override code un nom de service en dur : $codees" >&2
    return 1
  }

  # (3) LES HEREDOCS QUI N'ONT RIEN A EXPANSER SONT QUOTES. Un `<<EOF` nu evalue sa prose : les
  # accents graves y sont des substitutions de commande. Mesure du banc : `bridge`, `host`, `none`,
  # `getent`, `wget` et `git ls-remote` EXECUTES, et le fichier produit troue de leurs sorties vides.
  # Meme defaut que `bats.descriptions_inert`, a un endroit qu'aucun mur ne regardait.
  local f n=0
  for f in "$REPO"/deploy/docker/*.sh "$REPO"/services/*.sh; do
    [ -r "$f" ] || continue
    # Pour chaque heredoc NON quote, le corps doit etre exempt d'accent grave.
    awk '
      /<<[[:space:]]*EOF[[:space:]]*$/ { inhd=1; start=NR; body=""; next }
      inhd && /^EOF$/ { if (body ~ /`/) printf "%s:%d\n", FILENAME, start; inhd=0; next }
      inhd { body = body $0 "\n" }
    ' "$f"
  done > "$BATS_TEST_TMPDIR/hd" 2>/dev/null || true
  n="$(grep -c . "$BATS_TEST_TMPDIR/hd" || true)"
  [ "$n" -eq 0 ] || {
    echo "MUR 8 rompu — $n heredoc(s) NON quote(s) dont la prose porte un accent grave : elle sera EXECUTEE" >&2
    cat "$BATS_TEST_TMPDIR/hd" >&2
    echo "   Le geste : <<'EOF' si rien n'est a expanser, sinon echapper les accents graves." >&2
    return 1
  }
}

@test "MUR 9: le chemin du magasin s'accorde partout avec celui que le compose declare" {
  # ⚠ LA REGLE EXISTE DEJA, ECRITE ET GARDEE — SUR UN FICHIER SUR CINQ. `store_volumes.bats` dit :
  # « store.sh possede les NOMS, le compose possede le CHEMIN. Un `/var/lib/lcars` en dur dans un
  # script serait une seconde verite, et c'est celle qu'on ne relit pas qui derive. » Son assertion
  # ne porte que sur `store.sh`. Mesure du 2026-08-28 : TROIS autres scripts portent le chemin
  # (`bin/lcars-toolchain-converge`, `services/forge-gestures.sh`, `deploy/lib/provision-lib.sh`),
  # plus le manifeste. Une regle gardee sur un cinquieme de son sujet est le verrou partiel du §22.
  #
  # ⚠ ET J'AI FAILLI L'ENFREINDRE. Le balayage derive m'a fait conclure « la racine n'a aucun
  # foyer » et j'ai declare un `LCARS_STORE_ROOT_DEFAULT` dans `store.sh` — exactement la seconde
  # verite que la regle interdit. C'est le temoin existant qui m'a arrete, en rougissant. Le
  # balayage voit les COPIES ; il ne voit pas qui a deja ete DESIGNE.
  #
  # CE MUR N'INVENTE DONC AUCUNE AUTORITE : il consomme celle que la regle designe (le compose) et
  # l'etend aux porteurs que le temoin d'origine ne regardait pas. Rien n'est retire : ce qui se
  # verifie est l'ACCORD.
  local compose="$REPO/deploy/docker/docker-compose.yml"
  local lib="$REPO/deploy/lib/store.sh"
  [ -r "$compose" ] && [ -r "$lib" ] || { echo "MUR 9 — compose ou store.sh illisible" >&2; return 1; }

  local racine
  racine="$(sed -nE 's/^[[:space:]]*LCARS_STORE_ROOT:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "$compose" | head -n1)"
  [ -n "$racine" ] || { echo "MUR 9 — le compose ne declare plus LCARS_STORE_ROOT : l'autorite est illisible" >&2; return 1; }

  local natures
  natures="$(sed -n '/^LCARS_STORE_TREES=(/,/^)/p' "$lib" | sed -nE 's/^  ([a-z]+)\b.*/\1/p')"
  [ "$(printf '%s\n' "$natures" | grep -c .)" -ge 3 ] || {
    echo "MUR 9 — moins de 3 natures lues dans store.sh : l'instrument ne lit plus la liste" >&2; return 1; }

  # ⚠ LES SOUS-ARBRES HORS NATURE SE DECLARENT PAR LEUR NOM, chacun une decision visible.
  #   tofu — l'arbre de travail d'OpenTofu, pose par le manifeste en 0700 lcars-authority. Ce n'est
  #          pas une nature de magasin (il ne se purge pas par duree de vie) mais il partage la
  #          persistance de la racine.
  local hors_nature="tofu"

  : > "$BATS_TEST_TMPDIR/vus"
  local f
  while read -r f; do
    [ -r "$f" ] || continue
    # ⚠ CODE SEUL, ET LES DOCSTRINGS ELIXIR COMPTENT. Sans les depouiller, ce mur accusait
    # `admiral/toolchain_reconciler.ex`, dont le `@moduledoc` cite `/var/lib/lcars/toolchain` (au
    # SINGULIER) pour raconter une faute de la v2 — 0 occurrence en code, 1 en prose. Un mur qui lit
    # la prose interdit de l'ecrire, et `MUR 4 bis` a coute cette lecon le meme jour.
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
  done < <(grep -rl '/var/lib/.*lcars' "$REPO" --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp 2>/dev/null | grep -v '/deps/[a-z_]*/')

  [ -s "$BATS_TEST_TMPDIR/vus" ] || { echo "MUR 9 — aucun porteur lu : le balayage est casse" >&2; return 1; }
  local rompu=0 sub
  while read -r sub; do
    [ -n "$sub" ] || continue
    case "$sub" in
      ORPHELIN:*)
        echo "MUR 9 rompu — « ${sub#ORPHELIN:} » ne s'accorde pas avec la racine que le compose declare (« $racine »)" >&2
        rompu=1; continue ;;
    esac
    printf '%s\n' "$natures" | grep -qx "$sub" && continue
    printf '%s\n' "$hors_nature" | grep -qx "$sub" && continue
    echo "MUR 9 rompu — « $racine/$sub » n'est ni une NATURE de LCARS_STORE_TREES ni un sous-arbre declare" >&2
    rompu=1
  done < <(sort -u "$BATS_TEST_TMPDIR/vus")
  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 10: le prefixe d'install s'accorde — y compris dans la garde qui le protege" {
  # ⚠ TROIS PORTEURS, ET LE TROISIEME EST UNE GARDE. `deploy/lib/deploy-release.sh` et `provision-lib.sh`
  # declarent le prefixe chacun de leur cote ; `.claude/hooks/runtime-guard.sh` REFUSE les ecritures
  # dans l'arbre d'install, en le nommant. Si le prefixe bougeait sans que le hook suive, la garde
  # cesserait de proteger l'install reelle — sans un mot, et c'est le pire mode : elle continuerait
  # de dire non sur un chemin que plus personne n'utilise.
  #
  # ⚠ AUCUNE AUTORITE N'EST DESIGNEE, et on ne s'en invente pas. `60-deploy` passe `PROV_PREFIX` a
  # `install.sh`, donc `provision-lib` est en amont — mais `install.sh` joue aussi SEUL, avec son
  # propre repli. Ce qui se verifie est donc l'ACCORD, comme pour `/home/private`. Une designation
  # pourra s'ajouter ; l'inventer ici serait une decision que personne n'a prise.
  local inst="$REPO/deploy/lib/deploy-release.sh" lib="$REPO/deploy/lib/provision-lib.sh"
  local guard="$REPO/../.claude/hooks/runtime-guard.sh"
  [ -r "$inst" ] && [ -r "$lib" ] || { echo "MUR 10 — install.sh ou provision-lib.sh illisible" >&2; return 1; }

  local a b
  a="$(sed 's/#.*//' "$inst" | sed -nE 's/.*LCARS_INSTALL_PREFIX:-([^}]+)\}.*/\1/p' | head -n1)"
  # ⚠ LU RESOLU, PAS EN TEXTE. Depuis que la racine est nommee UNE fois (`PROV_ROOT`), ce repli est
  # DERIVE : `$PROV_ROOT/runtime`. Comparer son TEXTE a celui d'install.sh rendrait « deux prefixes
  # declares » sur deux declarations parfaitement d'accord — et la seule facon de faire taire ce
  # mur serait de regraver le litteral ici, c'est-a-dire d'ajouter la copie qu'il traque. L'idiome
  # est celui d'`authority_walls.bats` : sourcer dans un env vierge et lire la valeur.
  b="$(env -i PATH="$PATH" bash -c ". '$lib' >/dev/null 2>&1; printf '%s' \"\$PROV_PREFIX\"")"
  [ -n "$a" ] || { echo "MUR 10 — le repli de LCARS_INSTALL_PREFIX ne se lit plus dans install.sh" >&2; return 1; }
  [ -n "$b" ] || { echo "MUR 10 — PROV_PREFIX ne se lit plus dans provision-lib.sh" >&2; return 1; }
  [ "$a" = "$b" ] || {
    echo "MUR 10 rompu — deux prefixes declares : install.sh dit « $a », provision-lib.sh dit « $b »" >&2
    return 1
  }

  # La garde doit NOMMER ce prefixe. Elle protege aussi l'arbre v1 (`/local/LCARS`), ce qui est
  # deliberé et hors sujet ici : on ne verifie que la presence du prefixe COURANT.
  if [ -r "$guard" ]; then
    sed 's/#.*//' "$guard" | grep -qF -- "$a" || {
      echo "MUR 10 rompu — .claude/hooks/runtime-guard.sh ne protege pas « $a » : la garde vise un" >&2
      echo "   arbre que l'install n'utilise plus, et laisse le vrai ouvert" >&2
      return 1
    }
  fi

  # Et aucun litteral du corpus ne nomme un AUTRE prefixe de la meme forme.
  local orphelins
  #
  # ⚠ LA TRONCATURE GARDE LE POINT. Sans lui `/local/LCARS-v1.5` sortait en `/local/LCARS-v1`, et
  # l'exemption ecrite plus bas ne le reconnaissait pas : le mur accusait un arbre qu'il declarait
  # connaitre. Un motif qui mutile le nom qu'il compare ne compare rien.
  #
  # LES ARBRES NON-INSTALL SE DECLARENT PAR LEUR NOM, chacun avec sa raison :
  #   /local/LCARS      — l'arbre v1, que la garde protege AUSSI et deliberement
  #   /local/LCARS-v1.5 — cite par une donnee de CATALOGUE (`systemPrompt:` d'un cap-profile) ;
  #                       un catalogue est substituable, son contenu n'est pas un fait de la fleet
  #   /local/LCARS-fleet— un nom d'avant, qui ne vit plus que dans le CHANGELOG et un plan
  #   /local/LCARS_v2   — le prefixe d'AVANT la descente sous `/opt/lcars`. Il n'a pas eu besoin
  #                       d'etre declare tant qu'il ETAIT `$a` : le balayage l'excluait a ce titre.
  #                       La migration l'a rendu orphelin sans que personne ne le nomme, et il ne
  #                       vit plus que dans la cicatrice de `25-directories` qui raconte le scraper
  #                       qui ne connaissait que lui. Meme statut que ses trois voisins ci-dessus.
  #
  # ⚠ ET LES `tests/` SONT HORS BALAYAGE, PARCE QUE CE MUR S'EST ACCUSE LUI-MEME. La cicatrice
  # ci-dessus cite le nom tronque pour expliquer le defaut ; le balayage l'a lue et l'a comptee
  # comme un prefixe etranger. C'est la lecon nº2 du chantier, mot pour mot : « un temoin qui lit
  # la prose accuse la prose ». `adminite_walls` la porte deja — « un mur qui attraperait
  # l'explication d'un defaut interdirait de l'expliquer ».
  orphelins="$(grep -rhoE '/local/LCARS[A-Za-z0-9_.-]*' "$REPO" "$REPO/../.claude" \
                 --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp --exclude-dir=.expert \
                 --exclude-dir=tests 2>/dev/null \
               | sed -E 's|(/local/LCARS[A-Za-z0-9_.-]*).*|\1|' | sed -E 's|\.$||' | sort -u \
               | grep -vxF -- "$a" \
               | grep -vxF -- '/local/LCARS' \
               | grep -vxF -- '/local/LCARS-v1.5' \
               | grep -vxF -- '/local/LCARS-fleet' \
               | grep -vxF -- '/local/LCARS_v2' || true)"
  [ -z "$orphelins" ] || {
    echo "MUR 10 rompu — prefixe(s) etranger(s) sous /local, ni « $a » ni un arbre v1 declare :" >&2
    printf '     %s\n' $orphelins >&2
    return 1
  }
}

@test "MUR 11: tout fichier de /etc/lcars est DECLARE par le manifeste, ou nomme ici" {
  # `/etc/lcars` est la configuration MACHINE : le siege, le secret OIDC du deck, le consentement
  # d'hote, la table de transport des services. Le manifeste est l'inventaire de ce que le
  # provisionnement TIENT — mode, proprietaire, rail. Un fichier qui y vit sans y figurer n'a ni
  # mode garanti ni proprietaire garanti, et personne ne le sait.
  #
  # ⚠ DEUX FICHIERS N'Y SONT PAS, ET C'EST LEGITIME — POUR DEUX RAISONS DIFFERENTES. Les nommer
  # separement est le point : une exemption groupee cacherait qu'elles ne disent pas la meme chose.
  local manifeste="$REPO/deploy/system.manifest"
  [ -r "$manifeste" ] || { echo "MUR 11 — manifeste introuvable" >&2; return 1; }

  local declares
  # ⚠ DELIMITEUR `@`, ET PAS `|` : `sed` prend le premier `|` pour sa borne, donc une alternance
  # `(anchor|file|…)` coupe le motif en deux et l'extraction rend VIDE. Deuxieme fois aujourd'hui
  # que ce delimiteur mord — le sigil `~r|…|` d'Elixir avait le meme piege dans la famille A.
  declares="$(sed -nE 's@^(anchor|file|dir|preserve|runtime)[[:space:]]+/etc/lcars/([A-Za-z0-9_.-]+)[[:space:]].*@\2@p' "$manifeste" | sort -u)"
  [ "$(printf '%s\n' "$declares" | grep -c .)" -ge 3 ] || {
    echo "MUR 11 — moins de 3 declarations lues sous /etc/lcars : l'instrument ne lit plus le manifeste" >&2
    return 1
  }

  # fleet.json      — ADMIN-OWNED. `Fleet.SystemConfig` le LIT au boot ; rien ne le cree, et c'est
  #                   voulu : le provisionnement ne pose pas les reglages de l'administrateur.
  # install.journal — l'artefact de l'INSTALLEUR lui-meme (`deploy/provision`), pas un etat converge.
  # (`channel` a quitte cette liste : la table le declare, ecrit par `60-deploy`, lu par `prov_channel`.
  #  `forge.conf` et `provision.conf` aussi : seuls les postinst des .deb les lisaient, et la chaine
  #  .deb est partie le 2026-09-11 — plus aucun porteur ne les nomme.)
  local hors_manifeste="fleet.json install.journal"

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
             --exclude-dir=.expert --exclude-dir=tests 2>/dev/null | grep -v '/deps/[a-z_]*/')

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

@test "MUR 12: tout fichier grave sous le repertoire des secrets est un fichier que provision-lib DERIVE" {
  # ⚠ LA DERIVATION EXISTE DEJA, ET SEPT SITES LA CONTOURNENT. `provision-lib.sh` compose les
  # chemins des secrets depuis `$PROV_TOKENS_DIR` — le seed, le jeton master, la carte d'uid, le
  # jeton systeme. Sept fichiers gravent le chemin complet a la place : l'entrypoint (deux fois),
  # `catalogue-executor.py`, `human-converger.sh`, deux bancs, un message d'`enroll-catalogue`.
  #
  # CE MUR NE LEUR RETIRE RIEN — ils tournent hors de la portee de la lib et leur repli est leur
  # seule source (mesure du §7b : `provision-lib` n'exporte pas, et ces scripts sont des enfants).
  # Ce qu'il exige est que le NOM DE FICHIER grave soit un nom que la lib derive. Un secret qui
  # apparaitrait sous un nom que le provisionnement ne compose nulle part serait un fichier que
  # personne ne cree, lu par quelqu'un qui l'attend.
  local lib="$REPO/deploy/lib/provision-lib.sh"
  [ -r "$lib" ] || { echo "MUR 12 — provision-lib.sh introuvable" >&2; return 1; }

  # Les noms DERIVES, lus a la source. `$PROV_SYSTEM_ACCOUNT.gitea_token` est une composition : on
  # garde son suffixe, parce que le compte, lui, est verrouille ailleurs (forge.system_account).
  local derives
  derives="$(sed 's/#.*//' "$lib" \
             | sed -nE 's@.*PROV_[A-Z_]+:=\$PROV_TOKENS_DIR/([A-Za-z0-9_.$-]+).*@\1@p' \
             | sed -E 's@^\$[A-Z_]+@@' | sort -u)"
  [ "$(printf '%s\n' "$derives" | grep -c .)" -ge 3 ] || {
    echo "MUR 12 — moins de 3 chemins derives lus dans provision-lib : l'instrument est casse" >&2
    return 1
  }

  # forge-role-passwords.json — la carte des mots de passe par role, posee par `provision-forge-charte`
  # et jamais composee par la lib. Nommee ici plutot que laissee passer par un motif.
  local hors_derivation="forge-role-passwords.json"

  : > "$BATS_TEST_TMPDIR/sec"
  # ⚠ LE REPERTOIRE SE DEMANDE, IL NE SE GRAVE PLUS. Il valait `/home/private` en dur ici, aux trois
  # endroits de ce mur ; depuis que la racine est unique il derive (`$PROV_ROOT/var/tokens`), et un
  # littéral fige laisse le balayage sans AUCUN porteur — la garde d'instrument rougit alors sur un
  # dépôt sain. Sourcer la lib, c'est lire le meme fait que le code qu'on mesure.
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
    # ⚠ UNE EXPANSION N'EST PAS UN NOM. `<secrets>/$SYSTEM_ACCOUNT.gitea_token` compose son
    # nom a l'execution : ce mur ne peut pas le lire, et l'accuser serait accuser une derivation.
    if nom.startswith('$') or not nom:
        continue
    print(nom)
PYX
  # ⚠ `test` AU SINGULIER AUSSI. `--exclude-dir=tests` ne couvre pas `runtime/test/`, et ce mur
  # accusait `test_catalogue_executor.py`, dont un fixture porte « ../../home/private/forge-master »
  # — une tentative de traversee que le temoin REFUSE. Accuser un temoin pour la chaine qu'il
  # interdit est la meme faute que lire la prose : on punit celui qui documente le defaut.
  done < <(grep -rl "$secdir/" "$REPO" --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp \
             --exclude-dir=.expert --exclude-dir=tests --exclude-dir=test 2>/dev/null | grep -v '/deps/[a-z_]*/')

  [ -s "$BATS_TEST_TMPDIR/sec" ] || { echo "MUR 12 — aucun porteur lu : le balayage est casse" >&2; return 1; }
  local rompu=0 nom
  while read -r nom; do
    [ -n "$nom" ] || continue
    printf '%s\n' "$derives" | grep -qx "$nom" && continue
    printf '%s\n' "$derives" | grep -q -- "\\${nom##*.}\$" && [ "${nom#*.}" = "gitea_token" ] && continue
    printf '%s\n' $hors_derivation | grep -qx "$nom" && continue
    echo "MUR 12 rompu — $secdir/$nom est grave, mais provision-lib ne compose ce nom nulle part" >&2
    rompu=1
  done < <(sort -u "$BATS_TEST_TMPDIR/sec")
  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 13: le compte de service du deck — un nom, et les replis qui le nomment derivent" {
  # `lcars-system` est le compte SANS shell et SANS home sous lequel tourne le deck du conteneur. Il
  # a ete cree le 2026-08-26 pour sortir le deck de `nobody`, dont le groupe `nogroup` est partage
  # par `sync`, `_apt` et `dhcpcd` — le fichier d'identification OIDC du deck s'y posait en
  # `0640 root:nogroup`, donc un demon reseau le lisait. C'est MON compte, propage sans verrou.
  #
  # ⚠ ET SES DEUX REPLIS NE DISAIENT PAS LA MEME CHOSE. `21-service-accounts` (qui CREE le compte)
  # derive le groupe du user ; `66-deck-oidc` gravait `lcars-system`. Regler `PROV_SYSTEM_USER`
  # seul faisait creer un groupe d'un cote et chown vers un autre — un groupe inexistant, un deck
  # qui sert 503, et la cause dans un autre module.
  local nom
  nom="$(sed 's/#.*//' "$REPO/deploy/modules.d/21-service-accounts.sh" \
         | sed -nE 's@^SYSTEM_USER="\$\{PROV_SYSTEM_USER:-([a-z0-9_-]+)\}".*@\1@p' | head -n1)"
  [ -n "$nom" ] || { echo "MUR 13 — le nom du compte ne se lit plus dans 21-service-accounts" >&2; return 1; }

  local rompu=0
  # (1) Le groupe se DERIVE du compte partout, il ne se grave pas.
  sed 's/#.*//' "$REPO/deploy/modules.d/21-service-accounts.sh" \
    | grep -qE 'SYSTEM_GROUP="\$\{PROV_SYSTEM_GROUP:-\$SYSTEM_USER\}"' || {
      echo "MUR 13 rompu — 21-service-accounts ne derive plus le groupe du compte" >&2; rompu=1; }
  sed 's/#.*//' "$REPO/runtime/services/forge.d/deck-oidc.sh" \
    | grep -qE 'LCARS_SYSTEM_GROUP:-\$\{LCARS_SYSTEM_USER:-'"$nom"'\}' || {
      echo "MUR 13 rompu — 66-deck-oidc grave un groupe au lieu de le deriver du compte" >&2; rompu=1; }

  # (2) Les autres porteurs nomment le MEME compte, chacun sur son geste.
  need13() { sed 's/#.*//' "$REPO/$1" 2>/dev/null | grep -qE -- "$2" || {
      echo "MUR 13 rompu — $1 ne porte pas « $nom » pour $3" >&2; rompu=1; }; }
  need13 runtime/services/console-landing.sh "LCARS_DECK_USER:-$nom\}"                    "l'identite sous laquelle le deck tourne"
  need13 deploy/system.manifest      "^anchor[[:space:]]+/etc/lcars/deck-oidc.json[[:space:]]+0640[[:space:]]+root:$nom" \
                                     "le proprietaire du secret OIDC"
  [ "$rompu" -eq 0 ] || return 1
}

@test "MUR 14: un nom de service compose est une ENTREE DNS et un nom de CONTENEUR — ses lecteurs le derivent" {
  # ⚠ CETTE CLASSE A CASSE LA CI DEUX FOIS LE 2026-08-28, ET LES DEUX FOIS PAR LE MEME COMMIT.
  # `b01fe3164` a renomme deux services compose — `forge` -> `gitea`, `runner` -> `act` — et compose
  # publie le nom du service a la fois comme ENTREE DNS du reseau et comme segment du nom de
  # conteneur (`<projet>-<service>-1`). Les consommateurs le portent en CHAINE :
  #
  #   · l'override genere de `forge-runner.sh` nommait `runner:` -> compose creait un service sans
  #     image, « invalid compose project », le runner ne demarrait pas ;
  #   · une fois cela repare, l'URL interne disait encore `http://forge:3000` -> le runner tournait
  #     et bouclait sur « lookup forge : no such host ».
  #
  # Un nom dans une URL et un nom dans un nom de conteneur ne RESSEMBLENT pas a des references :
  # aucun grep sur « le nom du service » ne les trouve. Ce mur les trouve.
  #
  # ⚠ ET LE RENOMMAGE NE SE VOIT QUE SUR UN CONTENEUR NEUF — le rail ne reapplique pas un compose a
  # une forge debout. D'ou quinze jours sans rien casser, puis deux pannes a la premiere install
  # fraiche. Un mur est le seul instrument qui puisse voir ca sans monter une machine.
  local rompu=0

  # (1) LA FORGE : le service que `forge-compose.yml` definit EST l'hote des URL internes.
  local forge_svc
  forge_svc="$(python3 -c "
import yaml,io
d=yaml.safe_load(io.open('$REPO/deploy/docker/forge-compose.yml'))
print(next(iter((d.get('services') or {}).keys()), ''))" 2>/dev/null)"
  [ -n "$forge_svc" ] || { echo "MUR 14 — le service de forge-compose.yml ne se lit plus" >&2; return 1; }

  # ⚠ CODE SEUL — ET LA PROSE COMPTE QUAND MEME, AILLEURS. Ce mur ne lit que le code (quatrieme
  # fois qu'un extracteur de ce fichier avale de la prose). Un mur qui accuserait un commentaire
  # interdirait d'expliquer le defaut qu'il garde ; la prose se repare a la main.
  #
  # ⚠ ET CETTE PHRASE DISAIT « les commentaires qui nommaient `http://forge:3000` ont ete corriges
  # dans le meme geste ». C'ETAIT FAUX, mesure le 2026-08-29 : SEIZE lignes de prose survivaient
  # dans six fichiers de production — `forge-runner.sh` (7), `entrypoint.sh` (2), `bench-up.sh` (2),
  # `forge-compose.yml` (2), `provision-lib.sh` (2), un commentaire de temoin (1). Deux d'entre
  # elles documentaient l'ENTREE `FORGE_BASE_URL` a l'operateur, et `bench-up.sh` se contredisait
  # dans un seul fichier : la ligne 17 prescrivait `forge:3000`, la ligne 364 passait `gitea:3000`.
  #
  # LA LECON EST SUR L'ANGLE, PAS SUR LE COMPTE. Deux relectures adverses ont debattu de la GRAVITE
  # de deux de ces lignes sans jamais demander CE QU'ELLES DEVRAIENT DIRE — et la question, posee,
  # transforme l'arbitrage en balayage et rend les quatorze autres. Un mur ne peut pas poser cette
  # question a notre place : il ne lit pas la prose, et c'est bien.
  local hotes
  hotes="$(grep -rhE 'https?://[a-z][a-z0-9_.-]*:3000' "$REPO" \
             --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp --exclude-dir=.expert \
             --exclude-dir=tests --exclude-dir=test 2>/dev/null \
           | sed 's/#.*//' | grep -oE 'https?://[a-z][a-z0-9_.-]*:3000' \
           | sed -E 's@https?://([a-z][a-z0-9_.-]*):3000@\1@' | sort -u \
           | grep -vE '^(localhost|127\.0\.0\.1|0\.0\.0\.0)$' || true)"
  # ⚠ ET LE PORT EST L'AUTRE MOITIE DE L'ADRESSE. Ce mur tenait l'HOTE et pas le PORT : un
  # `http://gitea:3001` aurait passe, alors que le conteneur ecoute sur ce que le compose MAPPE.
  # Garder une moitie d'une adresse est la forme exacte que le §22 denonce — et c'est la deuxieme
  # fois aujourd'hui qu'on la trouve sur ce meme fait (le depot ops etait garde sans sa branche).
  local port_conteneur
  port_conteneur="$(sed 's/#.*//' "$REPO/deploy/docker/forge-compose.yml" \
                    | sed -nE 's@^[[:space:]]*-[[:space:]]*".*:([0-9]{2,5})"[[:space:]]*$@\1@p' | head -n1)"
  [ -n "$port_conteneur" ] || { echo "MUR 14 — le port du conteneur ne se lit plus dans forge-compose.yml" >&2; return 1; }

  local ports
  ports="$(grep -rhE 'https?://[a-z][a-z0-9_.-]*:[0-9]+' "$REPO" \
             --exclude-dir=_build --exclude-dir=.git --exclude-dir=tmp --exclude-dir=.expert \
             --exclude-dir=tests --exclude-dir=test 2>/dev/null \
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

  # (2) LE RUNNER : le service que `runner-compose.yml` definit EST le segment du nom de conteneur.
  # (2) LES NOMS DE CONTENEUR : `<projet>-<service>-1`. Le segment doit etre un service qu'UN des
  # compose definit — pas forcement celui du runner : ce depot en a trois (`lcars` pour le conteneur,
  # `gitea` pour la forge, `act` pour le runner) et les references les nomment tous les trois.
  # Ma premiere ecriture comparait tout au service du RUNNER et accusait `${PROJECT}-lcars-1`, une
  # reference parfaitement juste vers le conteneur. Comparer a l'ENSEMBLE evite d'avoir a deviner quel
  # compose une variable de projet designe — et c'est aussi ce qui rend le mur juste quand un
  # quatrieme compose arrive.
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

  # (3) LES FILTRES PAR LABEL — LA TROISIEME FORME, ET CE MUR NE LA GARDAIT PAS.
  #
  # ⚠ CE MUR ETAIT VERT PENDANT QUE `48-forge-host.sh` PORTAIT LE NOM MORT, ET C'EST LA CLASSE §22 :
  # il tenait l'hote DNS, le port, et le segment de nom de conteneur — trois expressions du meme
  # fait sur QUATRE. La quatrieme est `docker ps --filter label=com.docker.compose.service=<nom>`,
  # et c'est celle qui avait garde `forge` apres `b01fe3164`.
  #
  # ⚠ ET IL NE POUVAIT PAS LA VOIR EN CHERCHANT DES COPIES DE `gitea` : une copie qui a DEJA diverge
  # ne ressemble plus au fait qu'elle copie. Un verrou qui balaie les occurrences du bon nom est
  # aveugle a celle qui porte l'ancien — il faut balayer les EMPLOIS, puis confronter chacun a la
  # declaration. C'est la difference entre « toutes les copies se ressemblent » et « toute copie est
  # une valeur que le compose definit ».
  #
  # ⚠ MESURE DU 2026-08-28, banc 1241 : sur une machine dont la forge TOURNE DEJA, la sonde ne
  # reconnaissait plus sa propre forge, et le module refusait l'install en accusant l'operateur —
  # « ce n'est pas la forge de cette machine ». Invisible en CI : on n'y installe jamais deux fois.
  #
  # Une valeur DERIVEE (`$VAR`) passe : c'est la forme qu'on veut. Seul un litteral est confronte.
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
  # ⚠ CE MUR A CHANGE DE SUJET LE 2026-09-08, PARCE QUE SA CONDITION DE SORTIE EST TOMBEE.
  # Il gardait UNE adresse tolereee (`10.42.0.118`) et comptait ses SITES (deux : le defaut d'image
  # et `LCARS_SOURCE_REMOTE`), parce que le compose d'install ne pouvait pointer nulle part ailleurs :
  # aucune registry publique ne portait l'image, et « un defaut qui ment est pire qu'un defaut
  # local ». La promesse ecrite etait : « le jour ou GHCR est alimente, ce defaut change, et LUI
  # SEUL ».
  #
  # GHCR EST ALIMENTE (mesure du 2026-09-08 : paquet publie par le workflow du depot, rattache,
  # public, manifeste anonyme en HTTP 200, `docker pull` sans compte). Les deux sites ont bascule
  # dans le meme geste — exactement ce que le compte de sites servait a garantir. Il ne reste rien
  # a tolerer, donc le compte declare devient ZERO et ce mur redevient ce qu'il aurait toujours du
  # etre : aucune adresse de machine dans le code livre.
  #
  # LES DEUX FORMES DE PROSE RESTENT HORS SUJET et le mur ne les lit pas : les exemples d'un
  # template ou d'un `@doc`, et la sortie de banc recopiee dans les README. Ce sont des
  # ILLUSTRATIONS, pas des defauts — un mur qui les accuserait interdirait de montrer une URL.
  # C'est pourquoi le balayage coupe les commentaires (`sed 's/#.*//'`) avant de compter.
  # ⚠ LE TITRE DIT « EN CODE », LE BALAYAGE NE LISAIT QUE QUATRE RACINES. Mesuré par relecture
  # hostile le 2026-09-08 : des appâts posés dans `runtime/lib/` (toute l'application Elixir livrée),
  # `runtime/config/` (`runtime.exs`, l'endroit le plus naturel pour un hôte par défaut) et à la
  # racine (`install.sh`, et `pack.sh` qui y vivait encore) laissaient ce mur VERT. Un mur dont le périmètre est plus
  # étroit que sa promesse ne protège pas : il certifie.
  local racines=("$REPO/deploy" "$REPO/install.sh" \
                 "$REPO/runtime/lib" "$REPO/runtime/config" "$REPO/runtime/priv" \
                 "$REPO/runtime/services" "$REPO/runtime/bin" "$REPO/runtime/etc" \
                 "$REPO/catalogues")
  local motif='(10\.[0-9]+\.[0-9]+\.[0-9]+|192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)'

  # GARDE D'INSTRUMENT — elle ne peut plus s'appuyer sur une adresse attendue, puisqu'on n'en
  # attend aucune. Un mur qui n'accuse jamais et un balayage qui ne lit rien rendent le meme vert :
  # on prouve donc que le motif MORD, sur un decor pose ici.
  printf 'image: "10.42.0.118:80/fleet/lcars:2"\n' > "$BATS_TEST_TMPDIR/appat.yml"
  grep -hE "$motif" "$BATS_TEST_TMPDIR/appat.yml" >/dev/null || {
    echo "MUR 15 — le motif ne reconnait plus une adresse de LAN : l'instrument est casse" >&2
    return 1
  }
  local r
  for r in "${racines[@]}"; do
    [ -e "$r" ] || { echo "MUR 15 — chemin balaye absent : $r (l'instrument ne lit plus rien)" >&2; return 1; }
  done
  # ⚠ ET ON PROUVE QUE LE BALAYAGE LIT VRAIMENT CES CHEMINS, pas seulement qu'ils existent : un
  # appât posé pour CHAQUE racine doit ressortir. Sans ça, des options de `grep` qui changent ou un
  # chemin qui se déplace rendraient un vert sur du vide — la forme d'échec qui certifie. On mesure
  # sur des copies sous le bac à sable : le mur ne modifie jamais l'arbre.
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
    echo "   Le compte declare est ZERO depuis le basculement GHCR. Une adresse de machine dans" >&2
    echo "   le code livre est un defaut qui ne marche que chez nous — nomme la registry, la forge" >&2
    echo "   ou l'hote par une variable, pas par son IP." >&2
    # Ou est-elle ? Le refus doit nommer le fichier, pas seulement l'adresse.
    grep -rnE "$motif" "${racines[@]}" --exclude-dir=tests 2>/dev/null \
      | grep -vE '^[^:]+:[0-9]+: *#' | sed 's/^/   /' >&2
    return 1
  }
}

@test "MUR 16: le fichier d'environnement de l'humain — un chemin, deux ecrivains, un lecteur" {
  # ⚠ QUATORZE PORTEURS, AUCUNE AUTORITE. `bin/fleet` LIT `$HOME/.lcars/fleet.env` (deux
  # fois), `70-human` l'ECRIT depuis un template, et le template lui-meme porte le nom. Le
  # repertoire d'etat a une autorite — `Fleet.Layout` `@state_dirname` — le NOM DU FICHIER n'en a
  # aucune, et c'est lui qui porte `FORGE_BASE_URL` : sans ce fichier, `fleet start` refuse.
  #
  # UNE DIVERGENCE ICI EST MUETTE DANS LE PIRE SENS : `70-human` ecrirait un fichier que personne
  # ne lit, `fleet` lirait un fichier que personne n'ecrit, et le module RAPPORTERAIT « posé »
  # pendant que le lanceur dit « FORGE_BASE_URL manquant — édite <un autre chemin> ». L'operateur
  # editerait le fichier que le module nomme, sans effet.
  #
  # LE REPERTOIRE SE DERIVE DE `Fleet.Layout`, le nom du fichier se compare entre ses porteurs :
  # c'est l'ACCORD, faute d'autorite designee — meme forme que `/home/private`.
  local dir_etat
  # ⚠ DELIMITEUR `,` : `@` separe le `sed` ET ouvre `@state_dirname`. Troisieme fois aujourd'hui
  # qu'un delimiteur mange son propre motif — apres `~r|…|` en Elixir et `s|(anchor|file)|` plus
  # haut dans ce fichier. Le choix du delimiteur n'est pas cosmetique : c'est une partie du motif.
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
  # deploy/container pose et EXPORTE (compose est un fils). Le compose unique se joue aussi nu (le
  # banc, un pull a la main) : son repli SSH est celui de container, et son image par defaut est une
  # release publiee — container pose l'image locale de dev par-dessus.
  local container="$REPO/deploy/container" compose="$REPO/deploy/docker/docker-compose.yml"
  local port img
  port="$(sed 's/#.*//' "$container" | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{LCARS_SSH_PORT:=([^}]+)\}".*$/\1/p' | head -n1)"
  img="$(sed 's/#.*//' "$container"  | sed -nE 's/^[[:space:]]*:[[:space:]]*"\$\{LCARS_IMAGE:=([^}]+)\}".*$/\1/p' | head -n1)"
  [ -n "$port" ] && [ -n "$img" ] || { echo "MUR 17 — LCARS_SSH_PORT ou LCARS_IMAGE sans declaration \`: \"\${X:=…}\"\` dans deploy/container" >&2; return 1; }

  local rompu=0 code
  code="$(sed 's/#.*//' "$container")"
  grep -qE '\$\{LCARS_(IMAGE|SSH_PORT):-' <<<"$code" && { echo "MUR 17 rompu — deploy/container porte un repli \${LCARS_IMAGE:-…} ou \${LCARS_SSH_PORT:-…} a cote de sa declaration" >&2; rompu=1; }
  [ "$(grep -cF -- "$img" <<<"$code")" -eq 1 ]  || { echo "MUR 17 rompu — « $img » ecrit plus d'une fois dans deploy/container" >&2; rompu=1; }
  [ "$(grep -cF -- "$port" <<<"$code")" -eq 1 ] || { echo "MUR 17 rompu — « $port » ecrit plus d'une fois dans deploy/container" >&2; rompu=1; }
  grep -qE '^export( +[A-Z_]+)* +LCARS_SSH_PORT( |$)' "$container" && grep -qE '^export( +[A-Z_]+)* +LCARS_IMAGE( |$)' "$container" \
    || { echo "MUR 17 rompu — LCARS_SSH_PORT / LCARS_IMAGE non exportees par deploy/container : compose ne les verra pas" >&2; rompu=1; }
  grep -qF -- "\${LCARS_SSH_PORT:-$port}:22" "$compose" || { echo "MUR 17 rompu — docker-compose.yml ne replie pas LCARS_SSH_PORT sur « $port »" >&2; rompu=1; }
  # une release : un tag qui commence par un chiffre après le dernier /, jamais :main ni :latest ni un nom nu
  grep -qE 'image: "\$\{LCARS_IMAGE:-[^} ]*/[^}/:]+:[0-9][^}/:]*\}"' "$compose" || { echo "MUR 17 rompu — docker-compose.yml n'a pas pour image par defaut une release taguee" >&2; rompu=1; }
  grep -qE 'image: "\$\{LCARS_IMAGE:-[^}]*:(main|latest)\}"' "$compose" && { echo "MUR 17 rompu — l'image par defaut vise une tete de branche" >&2; rompu=1; }
  grep -qE "^#   LCARS_SSH_PORT .*défaut $port\)" "$container" || { echo "MUR 17 rompu — l'aide de container n'annonce pas « $port » pour LCARS_SSH_PORT" >&2; rompu=1; }
  [ "$rompu" -eq 0 ] || { echo "L'autorite est deploy/container (\`: \"\${LCARS_IMAGE:=…}\"\`, \`: \"\${LCARS_SSH_PORT:=…}\"\`) — le compose la lit et replie sur la meme valeur." >&2; return 1; }
}
