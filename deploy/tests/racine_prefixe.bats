#!/usr/bin/env bats
# SOURCE: deploy/tests/racine_prefixe.bats
# AUTHOR: alice
# STARDATE: (posee par /push-github)
# STATUS: mur — le prefixe d'install RO a UNE valeur, et onze sites la disent
#
# ⚠ ECRIT AVANT LE DEPLACEMENT, ET C'EST TOUT L'INTERET. Le deplacement de `/usr/share/lcars` n'a
# ete sur que parce qu'un temoin epinglait deja l'accord de ses cinq defauts : il a rougi au
# moment du geste. Celui de `/home/private` n'avait rien — le mur a ete ecrit d'abord, et il a
# attrape une perte de volume qu'aucune relecture n'aurait vue. Ici non plus il n'y a rien.
#
# ⚠ DEUX SSoT, ET RIEN NE LES CONFRONTE. `deploy/lib/deploy-release.sh` (`LCARS_INSTALL_PREFIX`) pose le runtime ;
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
  R="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"          # la RACINE du depot — `deploy/` et `runtime/` y sont FRERES
  LIB="$R/deploy/lib/provision-lib.sh"

  # ⚠ ON SOURCE, ON N'EXTRAIT PAS LE TEXTE. Un `sed` sur `${PROV_PREFIX:=…}` mesure une SYNTAXE :
  # le jour ou la lib se met a DERIVER (`$PROV_ROOT/rt`), il rend le texte non developpe et le mur
  # rougit sur un geste correct. La lecon vient du mur des jetons, qui a rendu six rouges d'un coup.
  # ⚠ `env -i` : on resout le DEFAUT, pas la surcharge de l'appelant. Un `setup()` qui exporte
  # cette variable — plusieurs le font — la rendrait telle quelle, et le mur mesurerait le
  # temoin au lieu de la SSoT. Le motif complet est dans `deploy_manifest.bats`.
  ATTENDU="$(env -i PATH="$PATH" bash -c ". '$LIB' >/dev/null 2>&1; printf '%s' \"\$PROV_PREFIX\"")"
  BIN_REL="$ATTENDU/rel/lcars_fleet/bin/lcars_fleet"
}

# Tout chemin absolu du fichier qui se termine par le binaire de release.
bins_de() { grep -ohE '/[A-Za-z0-9_./-]*/rel/lcars_fleet/bin/lcars_fleet' "$1" 2>/dev/null; }

@test "GARDE D'INSTRUMENT : la SSoT rend un prefixe absolu de profondeur >= 2" {
  # `deploy/lib/deploy-release.sh` REFUSE lui-meme un prefixe de profondeur 1 (il y effacerait une racine
  # systeme). Un mur qui accepterait moins que ce que le produit exige mesurerait autre chose.
  [[ "$ATTENDU" == /*/* ]] || { echo "prefixe inexploitable : « $ATTENDU »" >&2; return 1; }
  [ -n "$BIN_REL" ]
}

# ⚠ L'ACCORD DES DEUX SSoT N'EST PAS TENU ICI, ET CE FICHIER L'A AFFIRME A TORT. Il disait « rien
# ne les confronte » : faux. `deploy_manifest.bats` porte « UN FAIT, DEUX RENDUS », ecrit pour ce
# chantier meme, et il a rougi au deplacement — exactement comme prevu. Je ne l'avais pas cherche.
# Deux murs sur une meme propriete derivent, et celui qu'on lit n'est jamais celui qu'on a corrige :
# l'accord reste la-bas, avec son jumeau sur `PROV_LINK_DIR`. Ce fichier-ci garde ce que l'autre ne
# regarde pas — les chemins de binaire, le Dockerfile, la table.

@test "LES DEUX chemins de binaire de release sont le MEME, derive du prefixe" {
  # ⚠ ILS ETAIENT SEPT, ILS SONT DEUX — et ce mur a exige le geste. Ecrit avant le deplacement, il
  # comptait sept litteraux : une dans la lib du rail, deux dans `bin/lcars`, quatre dans
  # l'entrypoint, et aucune variable pour les porter. Au deplacement, la lib a DERIVE de
  # `$PROV_PREFIX`, `bin/lcars` a rappele son propre `_release_bin` (dont le commentaire disait
  # deja « un seul defaut, pose ici » alors qu'il y en avait deux), et l'entrypoint a hisse ses
  # quatre invocations sur un `RELEASE_BIN`. Restent les deux defauts qui ne peuvent pas deriver :
  # ces deux fichiers ne sourcent pas la lib du rail.
  #
  # Le mur COMPTE autant qu'il compare : un compte seul passerait au vert le jour ou l'un d'eux
  # change ailleurs, et une comparaison seule ne dirait rien d'un huitieme qui apparait.
  # ⚠ ET IL Y A DEUX NATURES, PAS UNE — CE MUR N EN CONNAISSAIT QU UNE, ET IL A EU RAISON DE
  # ROUGIR QUAND LA SECONDE EST APPARUE. La release POSEE vit sous `$PROV_PREFIX` ; la release
  # BATIE vit dans l arbre, en `runtime/_build/prod/rel/…`, la ou `mix release` la depose et ou
  # `pack.sh:188` la prend pour l embarquer. Ce sont deux objets distincts au meme nom de binaire :
  # `prov_release_bin` cherche la seconde AVANT la premiere, precisement parce qu elle est celle que
  # la passe en cours apporte et que `60-deploy` posera.
  #
  # Confondre les deux serait exiger que la release du paquet vive sous le prefixe d install —
  # c est-a-dire qu elle y soit AVANT d y etre posee. Le mur classe donc par nature, et compte
  # chacune : un compte seul passerait au vert le jour ou l un d eux change ailleurs, une
  # comparaison seule ne dirait rien d un huitieme qui apparait.
  local f n=0 nb=0 b
  for f in "$R/deploy/lib/provision-lib.sh" "$R/runtime/bin/lcars" "$R/runtime/services/box/boot.sh"; do
    while read -r b; do
      [ -n "$b" ] || continue
      case "$b" in
        */_build/prod/rel/lcars_fleet/bin/lcars_fleet)
          nb=$(( nb + 1 ))
          # La release BATIE se derive de la racine de l arbre, jamais du prefixe d install : un
          # chemin absolu en dur ici designerait la machine de celui qui a ecrit la ligne.
          [ "$b" = "/runtime/_build/prod/rel/lcars_fleet/bin/lcars_fleet" ] \
            || { echo "$f : chemin de release BATIE non derive de la racine : « $b »" >&2; return 1; } ;;
        *)
          n=$(( n + 1 ))
          [ "$b" = "$BIN_REL" ] || { echo "$f : « $b » au lieu de « $BIN_REL »" >&2; return 1; } ;;
      esac
    done < <(bins_de "$f")
  done
  # Lot 6 (2026-09-04) : l'entrypoint n'evalue plus rien lui-meme — ses portes deleguent a
  # « lcars tool » — donc son RELEASE_BIN est parti avec elles. Reste UN chemin litteral de release
  # posee : `_release_bin` de bin/lcars (la lib DERIVE le sien de $PROV_PREFIX).
  [ "$n" -eq 1 ] || { echo "UN chemin de release POSEE attendu (bin/lcars), $n trouve(s) — le corpus a bouge, ce mur aussi doit bouger" >&2; return 1; }
  # ⚠ ZERO CHEMIN BATI DEPUIS LE 2026-09-04 (lot 4) : `prov_release_bin` est mort avec la coupe de
  # 48 — la structure se derive de la release POSEE (61-forge-structure), plus jamais de celle du
  # paquet. Un chemin `_build/prod/rel` qui reapparaitrait ici serait la devinette qui revient.
  [ "$nb" -eq 0 ] || { echo "AUCUN chemin de release BATIE attendu, $nb trouve(s) — la devinette entre paquet et prefixe est revenue" >&2; return 1; }
}

@test "LE DOCKERFILE construit, copie et cable sous le MEME prefixe" {
  # Cinq gestes : le `LCARS_INSTALL_PREFIX=` du build, le `COPY` depuis l'etage de build, le
  # `chown -R`, le `chmod -R` et les deux `ln -sf`. Un seul en desaccord donne une image ou le
  # runtime est pose a un endroit et les symlinks pointent ailleurs — `lcars` en « No such file ».
  local d="$R/deploy/docker/Dockerfile" n
  # ⚠ `\b` N'EST PAS UNE BORNE DE CHEMIN, ET CE MUR ETAIT MORT. Mutation jouee le 2026-08-29 :
  # `LCARS_INSTALL_PREFIX=/opt/lcars/runtime-drift` dans le Dockerfile — le test restait VERT. `\b`
  # marque une frontiere de MOT : le tiret n'est pas un caractere de mot, donc `runtime-drift`
  # satisfait `runtime\b`. Tout suffixe commencant par un tiret, un point ou un espace passait. Ce
  # qui borne un chemin dans un `ENV`/`ARG`, c'est l'espace, la fin de ligne ou le slash suivant.
  grep -qE "LCARS_INSTALL_PREFIX=$ATTENDU([[:space:]/]|\$)" "$d" \
    || { echo "le build du Dockerfile n'installe pas sous « $ATTENDU »" >&2; return 1; }
  grep -qE "^COPY --from=build $ATTENDU $ATTENDU\$" "$d" \
    || { echo "le COPY du Dockerfile ne porte pas « $ATTENDU » des deux cotes" >&2; return 1; }
  n="$(grep -cE "(chown -R|chmod -R).* $ATTENDU( |\$)" "$d" || true)"
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
  grep -qE "^prefix[[:space:]]+${ATTENDU}[[:space:]]" "$R/deploy/system.manifest" \
    || { echo "« $ATTENDU » n'est pas declare en classe \`prefix\` dans le manifeste" >&2; return 1; }
  # ⚠ AUCUN CLIQUET SUR L'ANCIENNE VALEUR ICI, ET C'EST DELIBERE. L'interdit du retour appartient
  # a `racines_ssot.bats`, qui porte deja `/opt/lcars/runtime` dans sa liste. Un cliquet ecrit AVANT
  # le deplacement interdit la valeur qui est encore la bonne : il rougirait sur un depot sain.
}

# ─── M4 : LA PROSE SUIT LE LAYOUT, ET NE JUSTIFIE PAS DU CODE PAR UN APPELANT DISPARU ───────────
#
# Relecture hostile du 2026-09-04 : cinq commentaires disaient encore `fleet/` pour l'arbre frere
# de `deploy/` (renomme `runtime/`), et trois justifiaient d'embarquer `deploy/` sous /opt/lcars
# par « LE GESTE NOMINAL DU CONVERGEUR », en citant `human-converger.sh:132` — une ligne qui est
# `first_free_uid`, dans un convergeur qui ne rejoue plus `provision` (il source `human.d/*.sh`).
# Une prose qui cite un appelant par son numero de ligne perime a la premiere edition de l'appelant.
@test "M4 : aucune prose de deploy/ ne nomme plus fleet/ comme arbre frere, ni un convergeur qui rejouerait provision" {
  local hits
  hits="$(grep -rnE 'deploy/. et .fleet/. y sont FRERES|GESTE NOMINAL DU CONVERGEUR|human-converger\.sh:[0-9]+|fleet/\{deploy' \
            "$BATS_TEST_DIRNAME/.." --include='*.sh' --include='*.bats' --include='*.md' --include=provision --include=gate.sh \
          | grep -v 'racine_prefixe.bats' || true)"
  [ -z "$hits" ] || { echo "prose perimee :" >&2; printf '%s\n' "$hits" >&2; return 1; }
  # GARDE D INSTRUMENT : le motif voit bien la forme qu il interdit
  grep -qE 'deploy/. et .fleet/. y sont FRERES' <<<'  R="$(pwd)"  # la RACINE du depot — `deploy/` et `fleet/` y sont FRERES'
  grep -qE 'human-converger\.sh:[0-9]+' <<<'# (`runtime/services/human-converger.sh:132`), rend'
}
