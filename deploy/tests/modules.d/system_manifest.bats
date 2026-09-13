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
  printf '%s\n' /usr/local/bin /etc/systemd/system /etc/sudoers.d /etc/tmpfiles.d \
                /home/projects/LCARS /opt/elixir- /home/catalogues /etc/apt/keyrings > "$EXEMPT"
}

# Les lignes de donnees du manifeste : ni commentaire, ni vide.
rows() { grep -vE '^\s*#|^\s*$' "$MANIFEST"; }

code() {
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

_bins_du_rail=()
while read -r _n; do
  [ -n "$_n" ] && [ -f "$BATS_TEST_DIRNAME/../../../runtime/bin/$_n" ] \
    && _bins_du_rail+=("$BATS_TEST_DIRNAME/../../../runtime/bin/$_n")
done < <(grep -oE '"\$BIN_SRC_DIR/[a-zA-Z0-9._-]+"' \
           "$BATS_TEST_DIRNAME"/../../modules.d/62-runtime-helpers.sh 2>/dev/null \
         | sed 's|.*/||; s|"$||' | sort -u)

posed() {
  code | grep -ohE '(/usr/local/bin|/usr/share/lcars|/etc/systemd/system|/etc/tmpfiles\.d|/etc/sudoers\.d|/opt/[a-z]|/home/catalogues|/home/projects|/var/lib/lcars|/var/tmp/lcars|/opt/lcars/runtime|/etc/lcars|/run/lock|/run/lcars)[^"$ ),;:'"'"']*' \
    | tr -d '}' \
    | sed -e 's#/$##' -e 's#\.$##' \
          `# ⚠ LA NORMALISATION D'ELIXIR EST PARTIE AVEC SON OBJET. Elle ramenait` \
          `# \`/opt/elixir-$PROV_ELIXIR_VERSION\` sur le joker de la table ; le precompile pinne a` \
          `# ete remplace par le paquet apt de la distro, donc plus aucun module ne nomme ce chemin.` \
          `# Une normalisation qui survit a l'objet qu'elle normalise est un decor : elle fait croire` \
          `# que la sonde couvre un cas que le code ne produit plus.` \
          -e 's#/opt/node-[^ ]*#/opt/node-<version>#' \
          `# le joker de l'humain s'ecrit <humain> dans la prose du code et <human> dans la table :` \
          `# deux orthographes pour UN meme fait. La table gagne — code et identifiants en anglais.` \
          -e 's#<humain>#<human>#' \
    | sort -u
}

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
      ""|cond|merge|single|unset) ;;
      *) echo "trait inconnu « $trait » : $line"; return 1 ;;
    esac
    case "$cls" in
      prefix|dir|anchor|link|group|runtime|human|preserve) ;;
      account|person|docker) ;;
      *) echo "classe inconnue « $cls » : $line"; return 1 ;;
    esac
  done < "$BATS_TEST_TMPDIR/rows"
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
  local cls p rest base stem bad=0 CODE
  CODE="$(code)"
  while read -r cls p rest; do
    cls="${cls%%:*}"        # le trait qualifie la classe, il ne la remplace pas
    if [[ "$cls" == "group" ]]; then
      grep -qF "$p" <<<"$CODE" || { echo "GROUPE DECLARE, aucun poseur : $p"; bad=1; }
      continue
    fi
    base="$(basename "$p")"
    [[ "$base" == "<human>" ]] && continue
    case "$p" in
      /root/.terraform.d)      continue ;;   # tiers : le binaire `tofu`, invoque par 46-tofu
      /home/\<human\>/.hex)    continue ;;   # tiers : `mix local.hex`,   60-deploy (48 ne compile plus, lot 4)
      /home/\<human\>/.mix)    continue ;;   # tiers : `mix local.rebar`, 60-deploy
      /opt/lcars/.verified)    continue ;;   # pose par le DOCKERFILE (stage final, tampon de verify) — hors du corpus de ce mur, qui lit le rail et le runtime, pas l'image
    esac
    stem="$(sed -e 's#-<version>$##' -e 's#\.service$##' <<<"$base")"
    grep -qF "$stem" <<<"$CODE" || { echo "DECLARE, aucun poseur : $p (radical « $stem »)"; bad=1; }
  done < "$BATS_TEST_TMPDIR/rows"
  [ "$bad" -eq 0 ]
}

@test "le nom REEL du fichier tmpfiles, pas celui qu'on croit" {
  grep -qE '^anchor +/etc/tmpfiles\.d/lcars-console\.conf ' "$MANIFEST"
  refute grep -qE '^anchor +/etc/tmpfiles\.d/lcars\.conf ' "$MANIFEST"
  grep -q 'lcars-console.conf' "$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh"
}

@test "le marqueur HORS de l'arbre /run/lcars est declare" {
  grep -qE '^runtime +/run/lcars-converger\.refused ' "$MANIFEST"
  grep -q 'lcars-converger.refused' "$BATS_TEST_DIRNAME/../../../runtime/services/human-converger.sh"
}

@test "preserve = POSE mais JAMAIS RETIRE — pas « non pose »" {
  local p
  while read -r p; do
    grep -rqF -- "$p" "$BATS_TEST_DIRNAME"/../../modules.d/*.sh \
      || { echo "objet preserve sans poseur dans modules.d : $p"; return 1; }
  done < <(awk '{c=$1;sub(/:.*/,"",c)} c=="preserve"{print $2}' "$BATS_TEST_TMPDIR/rows")

  local f
  for f in /home/projects /home/projects.ops /home/projects.workshop; do
    awk '{c=$1;sub(/:.*/,"",c)} c=="preserve"{print $2}' "$BATS_TEST_TMPDIR/rows" | grep -qx -- "$f" \
      || { echo "face canonique DISPARUE de preserve : $f"; return 1; }
  done

  # ⚠ GARDE DE POPULATION : zero ligne `preserve` passerait les deux boucles ci-dessus.
  [ "$(awk '{c=$1;sub(/:.*/,"",c)} c=="preserve"' "$BATS_TEST_TMPDIR/rows" | wc -l)" -ge 3 ]
}


@test "LA TABLE A UN LECTEUR DE PRODUCTION, et il applique la colonne GID" {
  local lib="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  # Le lecteur existe et il lit bien CE fichier.
  grep -q '^prov_manifest_gid()' "$lib"
  sed 's/#.*//' "$lib" | grep -q 'system\.manifest'
  # Et il sert : `ensure_group` en derive le `-g`, jamais un litteral.
  local body; body="$(sed -n '/^ensure_group()/,/^}$/p' "$lib")"
  grep -q 'prov_manifest_gid' <<<"$body"
  grep -q 'groupadd' <<<"$body"
  # Garde d'instrument : une extraction cassee rendrait vide, donc verte sur rien.
  [ "$(wc -l <<<"$body")" -gt 10 ]
}

@test "un GID absent de la table reste FLOTTANT — on ne l'invente pas" {
  # La table dit ce qu'on a le droit de poser ; elle ne fabrique pas de numero. Un groupe qu'elle
  # ne nomme pas doit passer par `groupadd` nu, sans `-g`.
  local lib="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  eval "$(sed -n '/^prov_manifest_gid()/,/^}$/p' "$lib")"
  # ⚠ PORTANT, malgre le signalement : la fonction eval-uee lit `$PROVISION_LIB` pour retrouver la
  # table. Verifie par mutation — un chemin bidon fait rougir ce temoin.
  # shellcheck disable=SC2034 # lu a l'interieur de l'`eval`, invisible a l'analyse statique
  PROVISION_LIB="$lib"
  run prov_manifest_gid "groupe-que-la-table-ne-nomme-pas"
  [ -z "$output" ]
  run prov_manifest_gid "fleet"
  [ "$output" = "2000" ]
}

@test "LA TABLE A DEUX LECTEURS DE PLUS — mode et proprietaire — et ce sont les POSEURS qui les lisent (lot 15)" {
  local lib="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
  eval "$(sed -n '/^prov_manifest_mode()/,/^}$/p' "$lib")"
  eval "$(sed -n '/^prov_manifest_owner()/,/^}$/p' "$lib")"
  # shellcheck disable=SC2034 # lu a l'interieur de l'`eval`, invisible a l'analyse statique
  PROVISION_LIB="$lib"
  run prov_manifest_mode /opt/lcars/share/avatars
  [ "$output" = "0755" ]
  run prov_manifest_owner /opt/lcars/share/avatars
  [ "$output" = "root:root" ]
  run prov_manifest_mode /opt/lcars/tofu/providers
  [ "$output" = "0755" ]
  run prov_manifest_owner /opt/lcars/var/tokens
  [ "$output" = "lcars-authority:fleet" ]
  run prov_manifest_mode /chemin/que/la/table/ne/nomme/pas
  [ -z "$output" ]
  # `unset` : MODE OBSERVE, jamais affirme — le lecteur rend VIDE, donc aucun poseur ne compare
  run prov_manifest_mode '/home/<human>/.claude'
  [ -z "$output" ]
  # `-` est une colonne absente, pas une valeur : un lien n'a ni mode ni proprietaire
  run prov_manifest_mode /usr/local/bin/lcars
  [ -z "$output" ]
  run prov_manifest_owner /usr/local/bin/lcars
  [ -z "$output" ]
  # et les deux poseurs les lisent — sur le code, pas sur la prose
  local m
  for m in 44-media 46-tofu; do
    sed 's/#.*//' "$BATS_TEST_DIRNAME/../../modules.d/$m.sh" | grep -q 'prov_manifest_mode' \
      || { echo "$m ne lit pas le mode dans la table"; return 1; }
    sed 's/#.*//' "$BATS_TEST_DIRNAME/../../modules.d/$m.sh" | grep -q 'prov_manifest_owner' \
      || { echo "$m ne lit pas le proprietaire dans la table"; return 1; }
  done
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

@test "les GID declares sont FIXES, et ils sont ceux de l'image" {
  local g gid
  while read -r g gid; do
    [[ "$gid" =~ ^[0-9]+$ ]] || { echo "GID non numerique pour $g : $gid"; return 1; }
    [ "$gid" -ge 2000 ] || { echo "GID $gid sous le plancher fixe (2000) pour $g"; return 1; }
  done < <(awk '$1=="group"{print $2, $3}' "$BATS_TEST_TMPDIR/rows")
  grep -qE '^group +fleet +2000 ' "$MANIFEST"
  grep -qE '^group +lcars-console +2001 ' "$MANIFEST"
}

@test "PREFIX : la classe la plus importante de la table a un POSEUR, pas un effet de bord" {
  local dirs_mod="$BATS_TEST_DIRNAME/../../modules.d/25-directories.sh"
  local liste; liste="$(sed -n '/^prov_dirs()/,/^}$/p' "$dirs_mod")"
  [ -n "$liste" ]
  grep -q 'PROV_PREFIX' <<<"$liste"

  # et il est pose avec ce que la TABLE declare, pas avec autre chose
  local decl; decl="$(awk '{c=$1;sub(/:.*/,"",c)} c=="prefix"{print $3, $4; exit}' "$MANIFEST")"
  [ "$decl" = "0750 root:fleet" ]
  grep -qE 'PROV_PREFIX 0750 root:\$PROV_FLEET_GROUP' <<<"$liste"
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
    prov_console_human() { echo "<human>"; }
    '"$(sed -n '/^prov_runtime_dirs()/,/^}/p;/^prov_dirs()/,/^}/p' \
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
