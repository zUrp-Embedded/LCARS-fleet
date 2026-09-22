#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/modules.d/system_manifest.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests for deploy/system.manifest — le TROISIEME temoin ISO, celui de l'EMPREINTE

load ../refute

setup() {
  MANIFEST="$BATS_TEST_DIRNAME/../../system.manifest"
  ROOT="$BATS_TEST_DIRNAME/../../.."
  [ -f "$MANIFEST" ]

  DECL="$BATS_TEST_TMPDIR/decl"; ROOTS="$BATS_TEST_TMPDIR/roots"
  rows > "$BATS_TEST_TMPDIR/rows"
  awk '{print $2}' "$BATS_TEST_TMPDIR/rows" | sort -u > "$DECL"
  awk '{c=$1;sub(/:.*/,"",c)} c=="prefix"||c=="dir"{print $2}' "$BATS_TEST_TMPDIR/rows" | sort -u > "$ROOTS"

  EXEMPT="$BATS_TEST_TMPDIR/exempt"
  # /run/lcars-seat.login : écrit par l'init du conteneur (services/container/, hors du code lu ici) ; forge.d/tokens.sh le lit
  printf '%s\n' /usr/local/bin /etc/systemd/system /etc/tmpfiles.d /home/projects/LCARS /run/lcars-seat.login > "$EXEMPT"
}

# Les lignes de donnees du manifeste : ni commentaire, ni vide.
rows() { grep -vE '^\s*#|^\s*$' "$MANIFEST"; }

code() { poseurs; grep -hvE '^\s*#' "$BATS_TEST_DIRNAME"/../../installer-constants.env; }

# le code qui pose, sans le fichier de constantes : une valeur déclarée n'est pas un geste
poseurs() {
  grep -hvE '^\s*#' \
    "$BATS_TEST_DIRNAME"/../../modules.d/*.sh \
    "$ROOT"/install.sh \
    "$BATS_TEST_DIRNAME"/../../lib/deploy-release.sh \
    "$BATS_TEST_DIRNAME"/../../docker/*.sh \
    "$BATS_TEST_DIRNAME"/../../../runtime/services/*.sh \
    "$BATS_TEST_DIRNAME"/../../../runtime/services/*.py \
    "$BATS_TEST_DIRNAME"/../../../runtime/services/human.d/*.sh \
    "$BATS_TEST_DIRNAME"/../../../runtime/services/forge.d/*.sh \
    ${_bins_du_rail[@]+"${_bins_du_rail[@]}"} \
    "$BATS_TEST_DIRNAME"/../../lib/*.sh 2>/dev/null
}

resolu() { # le code qui pose, les constantes remplacées par leur valeur et « $(prov_decor X) » par X
  local c k v
  c="$(poseurs)"
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^PROV_[A-Z0-9_]+$ ]] || continue
    c="${c//\$\{$k\}/$v}"; c="${c//\$$k/$v}"
  done < <(sort -r "$BATS_TEST_DIRNAME/../../installer-constants.env")
  # ⚖ décision 3 : le produit nomme ces chemins par leur FAIT (`runtime/etc/facts.env`) et non plus
  # par un littéral recopié. Les faits se résolvent donc comme les constantes — sans quoi un objet
  # de la table paraîtrait sans poseur alors que son poseur le nomme, mieux qu'avant.
  while IFS='=' read -r k v; do
    [[ "$k" =~ ^LCARS_[A-Z0-9_]+$ ]] || continue
    c="${c//\$\{$k\}/$v}"; c="${c//\$$k/$v}"
  done < <(sort -r "$BATS_TEST_DIRNAME/../../../runtime/etc/facts.env")
  sed -E 's/\$\(prov_decor "?([^")]*)"?\)/\1/g' <<<"$c"
}

ere() { sed 's/[][\.*^$+?(){}|]/\\&/g' <<<"$1"; }   # ere <texte> → le texte en motif étendu littéral

chemin_entier() { grep -qE -- "$(ere "$1")([^A-Za-z0-9_.-]|$)" <<<"$2"; }   # chemin_entier <objet> <corpus>

a_un_poseur() { # a_un_poseur <objet> <corpus résolu> — son chemin entier, ou son nom borné : jamais un fragment d'un autre mot
  local stem
  chemin_entier "$1" "$2" && return 0
  stem="$(basename "$1" | sed -e 's#-<version>$##' -e 's#\.service$##')"
  grep -qE -- "(^|[^A-Za-z0-9_.-])$(ere "$stem")([^A-Za-z0-9_-]|$)" <<<"$2"
}

_bins_du_rail=()
while read -r _n; do
  [ -n "$_n" ] && [ -f "$BATS_TEST_DIRNAME/../../../runtime/bin/$_n" ] \
    && _bins_du_rail+=("$BATS_TEST_DIRNAME/../../../runtime/bin/$_n")
done < <(grep -oE '"\$BIN_SRC_DIR/[a-zA-Z0-9._-]+"' \
           "$BATS_TEST_DIRNAME"/../../modules.d/62-runtime-helpers.sh 2>/dev/null \
         | sed 's|.*/||; s|"$||' | sort -u)

posed() {
  code | grep -ohE '(/usr/local/bin|/usr/share/lcars|/etc/systemd/system|/etc/tmpfiles\.d|/etc/wsl\.conf|/etc/apt/keyrings/|/etc/apt/sources\.list\.d/[a-z]|/opt/[a-z]|/home/projects|/var/lib/lcars|/var/tmp/lcars|/opt/lcars/runtime|/etc/lcars|/run/lock|/run/lcars)[^"$ ),;:'"'"']*' \
    | tr -d '}' \
    | sed -e 's#/$##' -e 's#\.$##' \
          -e 's#/opt/node-[^ ]*#/opt/node-<version>#' \
          -e 's#/opt/elixir-[^ ]*#/opt/elixir-<version>#' \
          `# le joker de l'humain s'ecrit <humain> dans la prose du code et <human> dans la table :` \
          `# deux orthographes pour UN meme fait. La table gagne — code et identifiants en anglais.` \
          -e 's#<humain>#<human>#' \
    | sort -u
}

lib() { env -i PATH="$PATH" bash -c ". '$BATS_TEST_DIRNAME/../../lib/provision-lib.sh' >/dev/null 2>&1; $1"; }   # lib <code> — joué après la lib, sans décor

covered() { # covered <chemin> -> 0 si lui-meme ou un ancetre est declare, ou s'il est exempte
  local p="$1" r
  grep -qxF "$p" "$DECL" && return 0
  grep -qxF "$p" "$EXEMPT" && return 0
  while read -r r; do [[ "$p" == "$r"/* ]] && return 0; done < "$ROOTS"
  return 1
}

@test "LCARS header: SOURCE/STARDATE/STATUS, et il se declare DATA" {
  run head -3 "$MANIFEST"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"data, not code"* ]]
}

@test "FORME : cinq colonnes par ligne, et une classe du vocabulaire" {
  local line n cls trait
  while read -r line; do
    n="$(awk '{print NF}' <<<"$line")"
    [ "$n" -eq 5 ] || { echo "ligne a $n colonnes : $line"; return 1; }
    cls="$(awk '{print $1}' <<<"$line")"
    trait="${cls#*:}"; [[ "$trait" != "$cls" ]] || trait=""
    cls="${cls%%:*}"
    case "$trait" in
      ""|unset) ;;
      *) echo "trait inconnu « $trait » : $line"; return 1 ;;
    esac
    case "$cls" in
      prefix|dir|anchor|link|group|runtime|human|account|person) ;;
      *) echo "classe inconnue « $cls » : $line"; return 1 ;;
    esac
  done < "$BATS_TEST_TMPDIR/rows"
}

@test "SUBSTRAT : un parent déclaré couvre au moins les substrats de ses enfants" {
  # un enfant posé sur un substrat exige son parent sur ce substrat : le parent déclaré plus étroit ment
  local cls p s rest parent ps m etroit bad=0 vus=0
  while read -r cls p rest; do
    [[ "$p" == /* ]] || continue
    s="$(awk '{print $NF}' <<<"$rest")"
    parent="${p%/*}"
    while [[ -n "$parent" ]]; do
      ps="$(awk -v o="$parent" '$2==o {print $5; exit}' "$BATS_TEST_TMPDIR/rows")"
      [[ -z "$ps" ]] || break
      parent="${parent%/*}"
    done
    [[ -n "$parent" ]] || continue
    vus=$((vus + 1))
    etroit=0
    for m in ${s//+/ }; do
      [[ "$ps" == any || ( "$m" != any && "+$ps+" == *"+$m+"* ) ]] || etroit=1
    done
    [[ "$etroit" -eq 0 ]] || { echo "$p ($s) sous $parent ($ps)"; bad=1; }
  done < "$BATS_TEST_TMPDIR/rows"
  [ "$vus" -ge 10 ] || { echo "seulement $vus parents trouvés — l'instrument ne lit plus la table"; return 1; }
  [ "$bad" -eq 0 ]
}

@test "SUBSTRAT : la cinquieme colonne est du vocabulaire connu" {
  local s
  while read -r s; do
    [[ "$s" =~ ^(any|wsl|linux|docker)(\+(any|wsl|linux|docker))*$ ]] \
      || { echo "substrat inconnu : $s"; return 1; }
  done < <(awk '{print $5}' "$BATS_TEST_TMPDIR/rows")
}

@test "ISO 1/2 : tout chemin POSE par le code est couvert par la table" {
  # Le sens qui attrape un module neuf. `44-media` a pose `/usr/share/lcars` pendant des heures sans
  # que rien ne le declare — trouve parce qu'une recette a plante, pas par un temoin.
  local p bad=0
  while read -r p; do
    covered "$p" || { echo "POSE, NON DECLARE : $p"; bad=1; }
  done < <(posed)
  [ "$bad" -eq 0 ]
}

@test "le scraper BORNE un chemin sur le deux-points — un PATH= n'est pas un objet a declarer" {
  local ech; ech="$BATS_TEST_TMPDIR/echantillon.sh"
  printf '%s\n' 'env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin cmd' \
                'install -d /run/lcars/quelque-chose' > "$ech"
  local vus; vus="$(code() { cat "$ech"; }; posed)"

  # Le PATH ne produit AUCUN objet a rallonge…
  refute grep -q ':' <<<"$vus"
  # …et le chemin simple qu'il contient est quand meme vu, comme le chemin ordinaire d'a cote.
  grep -qx '/usr/local/bin' <<<"$vus"
  grep -qx '/run/lcars/quelque-chose' <<<"$vus"
}

@test "ISO 2/2 : tout objet DECLARE a un poseur dans le code" {
  local cls p rest bad=0 CODE entiers=0
  CODE="$(resolu)"
  while read -r cls p rest; do
    cls="${cls%%:*}"        # le trait qualifie la classe, il ne la remplace pas
    if [[ "$cls" == "group" ]]; then
      grep -qwF "$p" <<<"$CODE" || { echo "GROUPE DECLARE, aucun poseur : $p"; bad=1; }
      continue
    fi
    [[ "$(basename "$p")" == "<human>" ]] && continue
    case "$p" in
      /root/.terraform.d)      continue ;;   # tiers : le binaire `tofu`, invoque par 46-tofu
      /home/\<human\>/.hex)    continue ;;   # tiers : `mix local.hex`,   60-deploy
      /home/\<human\>/.mix)    continue ;;   # tiers : `mix local.rebar`, 60-deploy
    esac
    if chemin_entier "$p" "$CODE"; then entiers=$((entiers + 1)); fi
    a_un_poseur "$p" "$CODE" || { echo "DECLARE, aucun poseur : $p"; bad=1; }
  done < "$BATS_TEST_TMPDIR/rows"
  [ "$bad" -eq 0 ]
  # garde d'instrument : sans résolution des constantes, presque rien ne se trouve par son chemin entier
  [ "$entiers" -ge 20 ] || { echo "$entiers objets trouvés par leur chemin entier — la résolution des constantes est cassée"; return 1; }
}

@test "ISO 2/2, témoin du témoin : un nom qui n'est qu'un fragment d'un autre mot ne vaut pas poseur" {
  local corpus
  corpus="$(printf '%s\n' 'ensure_dir "$MEDIA_ROOT/avatars" 0755' 'x=/opt/lcars/var/tokens')"
  a_un_poseur /opt/lcars/share/avatars "$corpus"
  a_un_poseur /opt/lcars/var/tokens "$corpus"
  refute a_un_poseur /opt/lcars/share/ava "$corpus"
  refute a_un_poseur /opt/lcars/var/tok "$corpus"
}

@test "le fichier tmpfiles que 25-directories ecrit est celui que la table declare" {
  # /etc/tmpfiles.d est exempté du balayage ISO 1/2 : le nom posé se confronte ici à la table
  local pose
  pose="$(sed 's/#.*//' "$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh" \
          | sed -nE 's#^TMPFILES_CONF="\$\(prov_decor (/etc/tmpfiles\.d/[^)]+)\)"$#\1#p')"
  [ -n "$pose" ] || { echo "le chemin tmpfiles ne se lit plus dans 25-directories" >&2; return 1; }
  awk -v p="$pose" '$1 == "anchor" && $2 == p {t=1} END {exit !t}' "$BATS_TEST_TMPDIR/rows" \
    || { echo "25-directories écrit $pose, que la table ne déclare pas" >&2; return 1; }
}

@test "un GID absent de la table reste FLOTTANT — on ne l'invente pas" {
  # La table dit ce qu'on a le droit de poser ; elle ne fabrique pas de numero. Un groupe qu'elle
  # ne nomme pas doit passer par `groupadd` nu, sans `-g`.
  run lib 'prov_manifest_gid groupe-que-la-table-ne-nomme-pas'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run lib 'prov_manifest_gid fleet'
  [ "$output" = "2000" ]
}

@test "LA TABLE A DEUX LECTEURS DE PLUS — mode et proprietaire, vides pour un chemin absent, un mode observe ou une colonne sans valeur" {
  run lib 'prov_manifest_mode /opt/lcars/share/avatars'
  [ "$output" = "0755" ]
  run lib 'prov_manifest_owner /opt/lcars/share/avatars'
  [ "$output" = "root:root" ]
  run lib 'prov_manifest_mode /opt/lcars/tofu/providers'
  [ "$output" = "0755" ]
  run lib 'prov_manifest_owner /opt/lcars/var/tokens'
  [ "$output" = "lcars-authority:fleet" ]
  run lib 'prov_manifest_mode /chemin/que/la/table/ne/nomme/pas'
  [ -z "$output" ]
  # `unset` : MODE OBSERVE, jamais affirme — le lecteur rend VIDE, donc aucun poseur ne compare
  run lib "prov_manifest_mode '/home/<human>/.claude'"
  [ -z "$output" ]
  # `-` est une colonne absente, pas une valeur : un lien n'a ni mode ni proprietaire
  run lib 'prov_manifest_mode /usr/local/bin/lcars'
  [ -z "$output" ]
  run lib 'prov_manifest_owner /usr/local/bin/lcars'
  [ -z "$output" ]
}


@test "ACTIVATION : chaque unite de UNITS= a son lien declare dans la table" {
  local mod="$BATS_TEST_DIRNAME/../../modules.d/64-services.sh"
  local units u bad=0
  units="$(grep '^UNITS=' "$mod" | head -1 | tr -d '()' | sed 's/^UNITS=//' | tr ' ' '\n' | grep -v '^$')"
  # Garde d'instrument : une extraction cassee rendrait vide, donc verte sur rien.
  [ "$(grep -c . <<<"$units")" -ge 4 ]
  for u in $units; do
    grep -qE "^link +/etc/systemd/system/multi-user\.target\.wants/${u}\.service " "$MANIFEST" \
      || { echo "unite ACTIVEE mais lien NON declare : $u"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}


@test "SUBSTRAT : celui des unites suit l'APPLY-ON du module qui les pose" {
  local mod="$BATS_TEST_DIRNAME/../../modules.d/64-services.sh"
  local applique u col bad=0
  applique="$(grep -m1 '^# APPLY-ON:' "$mod" | sed 's/^# APPLY-ON: *//' | tr ' ' '\n' | grep -v '^$' | sort | tr '\n' ' ')"
  # Garde d'instrument : un en-tete illisible rendrait vide, donc vert sur rien.
  [ -n "$applique" ]
  for u in $(grep '^UNITS=' "$mod" | head -1 | tr -d '()' | sed 's/^UNITS=//'); do
    col="$(awk -v u="/etc/systemd/system/$u.service" '{c=$1;sub(/:.*/,"",c)} c=="anchor" && $2==u { print $5 }' "$MANIFEST")"
    [ -n "$col" ] || { echo "unite non declaree : $u"; bad=1; continue; }
    # `wsl+linux` en table doit couvrir `wsl linux` en en-tete, dans les deux sens.
    local vu; vu="$(tr '+' '\n' <<<"$col" | sort | tr '\n' ' ')"
    [ "$vu" = "$applique" ] || { echo "$u : table dit « $col », le module pose sur « $applique »"; bad=1; }
  done
  [ "$bad" -eq 0 ]
}

@test "les GID declares sont FIXES, au-dessus du plancher, et les deux groupes des constantes en ont un" {
  local g gid n=0
  while read -r g gid; do
    n=$((n + 1))
    [[ "$gid" =~ ^[0-9]+$ ]] || { echo "GID non numerique pour $g : $gid"; return 1; }
    [ "$gid" -ge 2000 ] || { echo "GID $gid sous le plancher fixe (2000) pour $g"; return 1; }
  done < <(awk '$1=="group"{print $2, $3}' "$BATS_TEST_TMPDIR/rows")
  [ "$n" -ge 2 ]
  local constantes="$BATS_TEST_DIRNAME/../../installer-constants.env" k nom
  for k in PROV_FLEET_GROUP PROV_CONSOLE_GROUP; do
    nom="$(sed -n "s/^$k=//p" "$constantes")"
    [ -n "$nom" ]
    awk -v g="$nom" '$1 == "group" && $2 == g && $3 ~ /^[0-9]+$/ {t=1} END {exit !t}' "$BATS_TEST_TMPDIR/rows" \
      || { echo "$k=$nom n'a pas de GID fixe dans la table"; return 1; }
  done
}

@test "PREFIX : la classe la plus importante de la table a un POSEUR, pas un effet de bord" {
  local dirs_mod="$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh"
  local liste; liste="$(sed -n '/^prov_dirs()/,/^}$/p' "$dirs_mod")"
  [ -n "$liste" ]
  grep -qF '"$PROV_PREFIX"' <<<"$liste"
  # 25 le pose au mode et au propriétaire que la table déclare pour lui
  local decl; decl="$(awk '{c=$1;sub(/:.*/,"",c)} c=="prefix"{print $3, $4; exit}' "$MANIFEST")"
  [ "$decl" = "0750 root:fleet" ]
  run lib 'prov_manifest_mode "$PROV_PREFIX"; prov_manifest_owner "$PROV_PREFIX"'
  [ "$output" = "$(printf '0750\nroot:fleet')" ]
}


@test "TRAVAIL : les racines de travail sous /var sont declarees, et couvrent les DEUX rails" {
  local r col vues=0
  for r in $(code | grep -ohE '/var/(lib|tmp)/lcars' | sort -u); do
    vues=$(( vues + 1 ))
    col="$(awk -v p="$r" '{cl=$1; sub(/:.*/,"",cl)} (cl=="dir"||cl=="prefix") && $2==p {print $NF; exit}' \
           "$BATS_TEST_TMPDIR/rows")"
    [ -n "$col" ] \
      || { echo "racine de travail POSEE et NON DECLAREE : $r"; return 1; }
    [ "$col" = "any" ] \
      || { echo "$r declare « $col » — or les scripts qui le creent partent sur LES DEUX rails, donc il est pose partout et retire nulle part"; return 1; }
  done
  # GARDE D INSTRUMENT : si l extraction ne trouve plus rien, ce mur devient vert en n ayant rien vu.
  [ "$vues" -ge 2 ] \
    || { echo "extraction ratee : $vues racine(s) de travail trouvee(s) dans le code, 2 attendues"; return 1; }
}

@test "TRAVAIL : le repertoire ou root telecharge PUIS execute est 0700 root:root" {
  local l; l="$(awk '$2=="/var/tmp/lcars/toolchain-work"{print; exit}' "$BATS_TEST_TMPDIR/rows")"
  [ -n "$l" ] || { echo "le repertoire de travail du convergeur de toolchain n est plus declare"; return 1; }
  [ "$(awk '{print $3}' <<<"$l")" = "0700" ] \
    || { echo "mode « $(awk '{print $3}' <<<"$l") » : root y telecharge et y execute, 0700 est le contrat"; return 1; }
  [ "$(awk '{print $4}' <<<"$l")" = "root:root" ] \
    || { echo "proprietaire « $(awk '{print $4}' <<<"$l") » au lieu de root:root"; return 1; }
}

@test "POSEUR : tout \`dir\` sans ancetre declare est ENUMERE par le poseur, pas seulement mentionne" {
  local poseur
  poseur="$(env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR" bash -c '
    . "'"$BATS_TEST_DIRNAME"'/../../lib/provision-lib.sh" >/dev/null 2>&1
    PROV_SUBSTRATE=linux
    # TOUTES les fonctions `prov_*` du module, pas deux noms epingles : le poseur central a le
    # droit de se lire en plusieurs fonctions, et une liste nominative ici rendait ce mur VERT
    # en silence des qu une d elles etait extraite — `prov_dirs` appelait alors un nom inconnu et
    # ne rendait plus les chemins qu il enumere (mesure du 2026-09-17).
    '"$(sed -n '/^prov_[a-z_]*()/,/^}/p' \
          "$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh")"'
    prov_dirs 2>/dev/null | awk "{print \$1}"
  ' 2>/dev/null)"
  [ -n "$poseur" ] \
    || { echo "le poseur n a rendu AUCUN chemin — instrument casse, pas table vide"; return 1; }

  local p orphelins="" vus=0 couvert
  while read -r p; do
    # Les JOKERS ne sont pas des chemins : le poseur les compose a l execution, le nom complet
    # n apparait nulle part. Meme raison que le `<human>` d ISO 2/2.
    [[ "$p" == *"<human>"* || "$p" == *"<version>"* ]] && continue
    [[ "$p" == /root/.terraform.d ]] && continue
    # Couvert par un ancetre DECLARE ? (regle 1 : un chemin est couvert par ses ancetres)
    couvert=0
    local a="$p"
    while [[ "$a" == */* ]]; do
      a="${a%/*}"; [ -z "$a" ] && break
      grep -qE "^(dir|prefix)[a-z:]* +${a}( |$)" "$MANIFEST" && { couvert=1; break; }
    done
    [ "$couvert" -eq 1 ] && continue
    vus=$(( vus + 1 ))
    # Le poseur rend des chemins DEVELOPPES : on compare des chemins entiers, jamais des morceaux.
    grep -qxF "$p" <<<"$poseur" || orphelins="$orphelins $p"
  done < <(awk '{c=$1; sub(/:.*/,"",c)} c=="dir" {print $2}' "$BATS_TEST_TMPDIR/rows")

  [ -z "$orphelins" ] \
    || { echo "DECLARE sans ancetre et NON ENUMERE par le poseur central — son mode et son proprietaire ne convergent depuis nulle part :$orphelins"; return 1; }
  [ "$vus" -ge 3 ] \
    || { echo "instrument casse : $vus repertoire(s) racine examine(s), 3 au moins attendus"; return 1; }
}
