#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/system_manifest.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests for deploy/system.manifest — le TROISIEME temoin ISO, celui de l'EMPREINTE
#
# ─── POURQUOI CE TEMOIN EXISTE ──────────────────────────────────────────────────────────────────
#
# Trois classes d'ecart entre ce que le produit DECLARE et ce qu'il POSE ont mordu en 24 h :
#
#   paquets   ce qu'`apt` installe de chaque cote        -> `deploy_manifest.bats`, bidirectionnel
#   fichiers  `/usr/share/lcars/*` pose par personne     -> `media_tree.bats`
#   EMPREINTE tout le reste                              -> CE FICHIER
#
# Les deux premieres ont ete trouvees par accident : l'une parce qu'une recette a plante, l'autre
# parce qu'un operateur s'est plaint d'une console. Un ecart qu'on decouvre par symptome est un
# ecart qu'on a mis des jours a voir.
#
# ⚠ CE TEMOIN NE LIT AUCUNE MACHINE, et c'est une limite qu'il faut connaitre. Il tient la moitie
# STATIQUE du contrat — tout ce que le code pose est declare, tout ce qui est declare a un poseur.
# La moitie vivante — opposer la table a un `find` reel — appartient au doctor et a
# `provision uninstall`, qui lisent la MEME table. Un temoin qui pretendrait mesurer la machine
# depuis ce poste mesurerait ce poste.
#
# ─── DEUX REGLES QUE CE FICHIER ENCODE, ET QUI ONT COUTE ────────────────────────────────────────
#
# 1. UN CHEMIN EST COUVERT PAR SES ANCETRES. Declarer chaque fichier de `/opt/lcars` ferait une
#    table de cent lignes que personne ne relit. `dir /opt/lcars` couvre ce qu'il contient — meme
#    idee que la couverture par glob de `site_path_covered?` dans le controleur de contrats.
#
# 2. `preserve` NE VEUT PAS DIRE « NON POSE ». `25-directories:139` cree bien les trois faces. Ca
#    veut dire POSE, JAMAIS RETIRE. Un temoin qui confondrait les deux declarerait une faute la ou
#    il n'y en a pas, et le vrai contrat — celui de l'uninstall — resterait sans gardien.

setup() {
  MANIFEST="$BATS_TEST_DIRNAME/../system.manifest"
  ROOT="$BATS_TEST_DIRNAME/../../.."
  [ -f "$MANIFEST" ]

  DECL="$BATS_TEST_TMPDIR/decl"; ROOTS="$BATS_TEST_TMPDIR/roots"
  rows > "$BATS_TEST_TMPDIR/rows"
  awk '{print $2}' "$BATS_TEST_TMPDIR/rows" | sort -u > "$DECL"
  awk '$1=="prefix"||$1=="dir"{print $2}' "$BATS_TEST_TMPDIR/rows" | sort -u > "$ROOTS"

  # ⚠ EXEMPTIONS NOMMEES, JAMAIS GLISSEES DANS UNE LISTE. Ces quatre repertoires appartiennent a
  # l'OS : LCARS y DEPOSE des fichiers, il ne les CREE pas, et un uninstall qui les retirerait
  # casserait la machine. C'est la meme convention que `deploy_manifest.bats` pour les paquets.
  #
  # `/home/projects/LCARS` est le CHECKOUT, monte dans la boite par l'operateur
  # (`entrypoint.sh:226`, `LCARS_SOURCE_DIR`). LCARS le LIT ; il ne le pose pas, et un uninstall qui
  # y toucherait detruirait le depot de quelqu'un.
  EXEMPT="$BATS_TEST_TMPDIR/exempt"
  printf '%s\n' /usr/local/bin /etc/systemd/system /etc/sudoers.d /etc/tmpfiles.d \
                /home/projects/LCARS > "$EXEMPT"
}

# Les lignes de donnees du manifeste : ni commentaire, ni vide.
rows() { grep -vE '^\s*#|^\s*$' "$MANIFEST"; }

# Tout le code qui POSE quelque chose : les modules, les deux installeurs, et le RUNTIME — qui pose
# apres l'install, en boucle. Ignorer le troisieme declare une machine qui n'existe que la premiere
# seconde.
code() {
  grep -hvE '^\s*#' \
    "$BATS_TEST_DIRNAME"/../modules.d/*.sh \
    "$ROOT"/install.sh \
    "$BATS_TEST_DIRNAME"/../../etc/install.sh \
    "$BATS_TEST_DIRNAME"/../docker/*.sh \
    "$BATS_TEST_DIRNAME"/../lib/*.sh 2>/dev/null
}

# Les chemins litteraux que le code pose, normalises : `}` de `${VAR:-/chemin}` retire, ponctuation
# de fin retiree, versions repliees sur le joker du manifeste.
posed() {
  code | grep -ohE '(/usr/local/bin|/usr/share/lcars|/etc/systemd/system|/etc/tmpfiles\.d|/etc/sudoers\.d|/opt/[a-z]|/home/private|/home/catalogues|/home/projects|/var/lib/lcars|/local/LCARS_v2|/etc/lcars|/run/lcars)[^"$ ),;'"'"']*' \
    | tr -d '}' \
    | sed -e 's#/$##' -e 's#\.$##' \
          -e 's#/opt/elixir-[^ ]*#/opt/elixir-<version>#' \
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
  local line n cls
  while read -r line; do
    n="$(awk '{print NF}' <<<"$line")"
    [ "$n" -eq 5 ] || { echo "ligne a $n colonnes : $line"; return 1; }
    cls="$(awk '{print $1}' <<<"$line")"
    case "$cls" in
      prefix|dir|anchor|link|group|runtime|human|preserve) ;;
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

@test "ISO 2/2 : tout objet DECLARE a un poseur dans le code" {
  # Le sens qui attrape une declaration morte — la faute exacte du corpus d'alice, qui declarait
  # `/etc/tmpfiles.d/lcars.conf` quand le fichier pose s'appelle `lcars-console.conf`.
  #
  # ⚠ ON CHERCHE LE RADICAL, PAS LE NOM COMPOSE. Le code ecrit `"/opt/elixir-${VERSION}"` et
  # `"$1.service"` depuis `UNITS=(…)` : le nom complet n'apparait JAMAIS littéralement. Un temoin
  # qui cherche `lcars-landing.service` declare quatre objets morts qui sont tous vivants — mesure
  # du 2026-08-22, sur ce fichier meme.
  local cls p rest base stem bad=0 CODE
  CODE="$(code)"
  while read -r cls p rest; do
    if [[ "$cls" == "group" ]]; then
      grep -qF "$p" <<<"$CODE" || { echo "GROUPE DECLARE, aucun poseur : $p"; bad=1; }
      continue
    fi
    base="$(basename "$p")"
    [[ "$base" == "<human>" ]] && continue
    stem="$(sed -e 's#-<version>$##' -e 's#\.service$##' <<<"$base")"
    grep -qF "$stem" <<<"$CODE" || { echo "DECLARE, aucun poseur : $p (radical « $stem »)"; bad=1; }
  done < "$BATS_TEST_TMPDIR/rows"
  [ "$bad" -eq 0 ]
}

@test "le nom REEL du fichier tmpfiles, pas celui qu'on croit" {
  # ⚠ L'ECART QUI JUSTIFIE A LUI SEUL CE FICHIER. Le corpus declarait `lcars.conf` ; `25-directories`
  # pose `lcars-console.conf`. Un desinstalleur ecrit depuis la table fausse le raterait,
  # silencieusement et pour toujours.
  grep -qE '^anchor +/etc/tmpfiles\.d/lcars-console\.conf ' "$MANIFEST"
  ! grep -qE '^anchor +/etc/tmpfiles\.d/lcars\.conf ' "$MANIFEST"
  grep -q 'lcars-console.conf' "$BATS_TEST_DIRNAME/../modules.d/25-directories.sh"
}

@test "le marqueur HORS de l'arbre /run/lcars est declare" {
  # `/run/lcars-converger.refused` vit a la RACINE de `/run`. Un `rm -rf /run/lcars` ne l'emporte
  # pas. Ni la mesure machine ni la table du corpus ne l'avaient : c'est la lecture du RUNTIME qui
  # l'a rendu visible.
  grep -qE '^runtime +/run/lcars-converger\.refused ' "$MANIFEST"
  grep -q 'lcars-converger.refused' "$BATS_TEST_DIRNAME/../docker/human-converger.sh"
}

@test "preserve = POSE mais JAMAIS RETIRE — pas « non pose »" {
  # `25-directories:139` cree les trois faces. Confondre les deux sens ferait declarer une faute la
  # ou il n'y en a pas, et laisserait le vrai contrat — celui de l'uninstall — sans gardien.
  local p
  while read -r p; do
    grep -q "$(basename "$p")" "$BATS_TEST_DIRNAME/../modules.d/25-directories.sh" \
      || { echo "face preservee sans poseur : $p"; return 1; }
  done < <(awk '$1=="preserve"{print $2}' "$BATS_TEST_TMPDIR/rows")
  # et les trois faces canoniques y sont
  [ "$(awk '$1=="preserve"' "$BATS_TEST_TMPDIR/rows" | wc -l)" -eq 3 ]
}

@test "AUCUN LECTEUR pour l'instant, et c'est l'etat attendu de la phase A" {
  # Le manifeste se pose AVANT ses trois lecteurs (`20-groups`, `25-directories`, `uninstall`) :
  # c'etait le trou d'ordre du corpus. Ce temoin tombera le jour ou le premier lecteur arrive — et
  # sa chute sera le signal de le reecrire, pas un accident.
  ! grep -rlq 'system\.manifest' "$BATS_TEST_DIRNAME"/../modules.d/ 2>/dev/null
}

@test "les GID declares sont FIXES, et ils sont ceux de l'image" {
  # Mesure .63 : fleet 1001, lcars-admin 1002, lcars-console 1003 — flottants, distribues par
  # `groupadd`. Le Dockerfile, lui, fixe fleet 2000 et lcars-console 2001. Les deux substrats
  # divergent donc sur un fait, et c'est la colonne de ce fichier qui les remettra d'accord.
  local g gid
  while read -r g gid; do
    [[ "$gid" =~ ^[0-9]+$ ]] || { echo "GID non numerique pour $g : $gid"; return 1; }
    [ "$gid" -ge 2000 ] || { echo "GID $gid sous le plancher fixe (2000) pour $g"; return 1; }
  done < <(awk '$1=="group"{print $2, $3}' "$BATS_TEST_TMPDIR/rows")
  grep -qE '^group +fleet +2000 ' "$MANIFEST"
  grep -qE '^group +lcars-console +2001 ' "$MANIFEST"
}
