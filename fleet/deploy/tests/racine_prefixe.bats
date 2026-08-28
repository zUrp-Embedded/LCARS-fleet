#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/racine_prefixe.bats
# AUTHOR: alice
# STARDATE: (posee par /push-github)
# STATUS: mur — le prefixe d'install RO a UNE valeur, et onze sites la disent
#
# ⚠ ECRIT AVANT LE DEPLACEMENT, ET C'EST TOUT L'INTERET. Le deplacement de `/usr/share/lcars` n'a
# ete sur que parce qu'un temoin epinglait deja l'accord de ses cinq defauts : il a rougi au
# moment du geste. Celui de `/home/private` n'avait rien — le mur a ete ecrit d'abord, et il a
# attrape une perte de volume qu'aucune relecture n'aurait vue. Ici non plus il n'y a rien.
#
# ⚠ DEUX SSoT, ET RIEN NE LES CONFRONTE. `etc/install.sh` (`LCARS_INSTALL_PREFIX`) pose le runtime ;
# `deploy/lib/provision-lib.sh` (`PROV_PREFIX`) le VERIFIE et le reverrouille. Deux defauts
# separes, dans deux fichiers, jamais compares. Le jour ou l'un bouge, le rail pose a un endroit
# et verifie a un autre : `60-deploy` annonce « release absente » sur une release parfaitement
# posee, et son `chown -R` part sur un chemin qui n'existe pas.
#
# ⚠ ET UN SECOND CONSTANT DERIVE QUE PERSONNE NE NOMME : `<prefixe>/rel/lcars_fleet/bin/lcars_fleet`,
# ecrit SEPT fois — une dans la lib, deux dans `bin/lcars`, quatre dans l'entrypoint. Aucune
# variable ne le porte. C'est la forme exacte du defaut que ce mur existe pour rendre bruyant.
#
# CE QU'IL N'EPINGLE PAS : la VALEUR. Elle est derivee de la SSoT, jamais gravee — un mur qu'il
# faut reecrire a chaque deplacement ne garde rien entre deux.

load refute

setup() {
  R="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # fleet/
  LIB="$R/deploy/lib/provision-lib.sh"

  # ⚠ ON SOURCE, ON N'EXTRAIT PAS LE TEXTE. Un `sed` sur `${PROV_PREFIX:=…}` mesure une SYNTAXE :
  # le jour ou la lib se met a DERIVER (`$PROV_ROOT/rt`), il rend le texte non developpe et le mur
  # rougit sur un geste correct. La lecon vient du mur des jetons, qui a rendu six rouges d'un coup.
  ATTENDU="$(bash -c ". '$LIB' >/dev/null 2>&1; printf '%s' \"\$PROV_PREFIX\"")"
  BIN_REL="$ATTENDU/rel/lcars_fleet/bin/lcars_fleet"
}

# Tout chemin absolu du fichier qui se termine par le binaire de release.
bins_de() { grep -ohE '/[A-Za-z0-9_./-]*/rel/lcars_fleet/bin/lcars_fleet' "$1" 2>/dev/null; }

@test "GARDE D'INSTRUMENT : la SSoT rend un prefixe absolu de profondeur >= 2" {
  # `etc/install.sh` REFUSE lui-meme un prefixe de profondeur 1 (il y effacerait une racine
  # systeme). Un mur qui accepterait moins que ce que le produit exige mesurerait autre chose.
  [[ "$ATTENDU" == /*/* ]] || { echo "prefixe inexploitable : « $ATTENDU »" >&2; return 1; }
  [ -n "$BIN_REL" ]
}

@test "LES DEUX SSoT s'accordent — celle qui POSE et celle qui VERIFIE" {
  # `install.sh` pose sous `LCARS_INSTALL_PREFIX`, le rail verifie sous `PROV_PREFIX`. Rien d'autre
  # ne les confronte, et leur desaccord est SILENCIEUX : la release existe, le rail ne la voit pas.
  local pose
  pose="$(sed -n 's/^PREFIX="${LCARS_INSTALL_PREFIX:-\([^}]*\)}".*/\1/p' "$R/etc/install.sh" | head -1)"
  [ -n "$pose" ] || { echo "le defaut de LCARS_INSTALL_PREFIX n'est plus lisible dans etc/install.sh" >&2; return 1; }
  [ "$pose" = "$ATTENDU" ] \
    || { echo "install.sh pose sous « $pose », le rail verifie sous « $ATTENDU »" >&2; return 1; }
}

@test "LES SEPT chemins de binaire de release sont le MEME, derive du prefixe" {
  # Sept litteraux, aucune variable pour les porter. Le mur les compte ET les compare : un compte
  # seul passerait au vert le jour ou l'un d'eux change ailleurs.
  local f n=0 b
  for f in "$R/deploy/lib/provision-lib.sh" "$R/bin/lcars" "$R/deploy/docker/entrypoint.sh"; do
    while read -r b; do
      [ -n "$b" ] || continue
      n=$(( n + 1 ))
      [ "$b" = "$BIN_REL" ] || { echo "$f : « $b » au lieu de « $BIN_REL »" >&2; return 1; }
    done < <(bins_de "$f")
  done
  [ "$n" -eq 7 ] || { echo "sept chemins de release attendus, $n trouve(s) — le corpus a bouge, ce mur aussi doit bouger" >&2; return 1; }
}

@test "LE DOCKERFILE construit, copie et cable sous le MEME prefixe" {
  # Cinq gestes : le `LCARS_INSTALL_PREFIX=` du build, le `COPY` depuis l'etage de build, le
  # `chown -R`, le `chmod -R` et les deux `ln -sf`. Un seul en desaccord donne une image ou le
  # runtime est pose a un endroit et les symlinks pointent ailleurs — `lcars` en « No such file ».
  local d="$R/deploy/docker/Dockerfile" n
  grep -qE "LCARS_INSTALL_PREFIX=$ATTENDU\b" "$d" \
    || { echo "le build du Dockerfile n'installe pas sous « $ATTENDU »" >&2; return 1; }
  grep -qE "^COPY --from=build $ATTENDU $ATTENDU\$" "$d" \
    || { echo "le COPY du Dockerfile ne porte pas « $ATTENDU » des deux cotes" >&2; return 1; }
  n="$(grep -cE "(chown -R|chmod -R)[^\n]* $ATTENDU( |\$)" "$d" || true)"
  [ "$n" -eq 2 ] || { echo "attendu 2 verrouillages (chown/chmod) sur « $ATTENDU », vu $n" >&2; return 1; }
  n="$(grep -cE "ln -sf $ATTENDU/bin/" "$d" || true)"
  [ "$n" -eq 2 ] || { echo "attendu 2 symlinks depuis « $ATTENDU/bin/ », vu $n" >&2; return 1; }
}

@test "LA TABLE declare ce prefixe, et c'est le meme" {
  # Le manifeste est ce que l'uninstall lit. Une ligne qui nomme l'ancien prefixe laisse le nouveau
  # en place a la desinstallation — un residu qu'aucun message ne signale.
  # ⚠ ACCENTS GRAVES ECHAPPES. Dans une chaine a guillemets DOUBLES, bash fait de la substitution
  # de commande : le premier jet de cette ligne executait `prefix`. Meme famille que la prose des
  # heredocs non quotes — un message d'erreur qui lance une commande.
  grep -qE "^prefix[[:space:]]+$ATTENDU[[:space:]]" "$R/deploy/system.manifest" \
    || { echo "« $ATTENDU » n'est pas declare en classe \`prefix\` dans le manifeste" >&2; return 1; }
  # ⚠ AUCUN CLIQUET SUR L'ANCIENNE VALEUR ICI, ET C'EST DELIBERE. L'interdit du retour appartient
  # a `racines_ssot.bats`, qui porte deja `/local/LCARS_v2` dans sa liste. Un cliquet ecrit AVANT
  # le deplacement interdit la valeur qui est encore la bonne : il rougirait sur un depot sain.
}
