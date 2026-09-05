#!/usr/bin/env bats
# SOURCE: deploy/tests/poseurs.bats
# AUTHOR: bob
# STARDATE: (posee par /push-github)
# STATUS: bats tests — CE QUE LES POSEURS LAISSENT DERRIERE EUX
#
# ─── UNE MEME FAUTE, CINQ FORMES ────────────────────────────────────────────────────────────────
#
# Ces cinq defauts n'ont rien a voir entre eux sauf leur nature : un module POSE un objet, et ce
# qu'il en dit ne correspond pas a ce qu'il en fait. Aucun ne casse quoi que ce soit tout de suite —
# c'est pourquoi ils ont vecu des semaines.
#
#   C1  `--bench` accepte sur le rail POSTE, annonce, et sans aucun effet
#   C2  `~/.lcars/log` cree au umask alors que la table affirme 0700 — et un check aveugle
#   C3  un `chown` dont l'echec est avale, sur un repertoire du home d'un humain
#   C4  le CONTENU de `/usr/share/lcars` appartenant a qui possedait le checkout
#   C6  la copie embarquee n'emportant pas l'arbre dont le meme module a besoin
#
# ⚠ LE PIRE DES CINQ EST LE DERNIER, et il ne se voyait pas : `EMBEDDED=(deploy etc)` privait
# `62-runtime-helpers` de sa propre source de comparaison sur toute machine provisionnee. Onze
# drifts faux par passage — mesure du 2026-09-01, banc 2004 — plus une sonde silencieuse de
# `25-directories` qui rendait vide.

# shellcheck disable=SC2030,SC2031

load refute

setup() {
  DEPLOY="$BATS_TEST_DIRNAME/.."
  MODS="$DEPLOY/modules.d"
  PORTE="$BATS_TEST_DIRNAME/../../install.sh"
  [ -d "$MODS" ] && [ -f "$PORTE" ]
}

# ─── C1 — UN DRAPEAU FAIT CE QU'IL DIT, OU IL EST REFUSE ────────────────────────────────────────

@test "C1 : --bench est CABLE sur le rail poste — il n'est plus avale" {
  # Mesure : les usages de `WITH_BENCH` en zone de sortie etaient TOUS dans la branche boite, et le
  # drapeau n'entre pas dans `PASSTHRU`. Sur le poste il posait une variable que personne ne lisait,
  # apres avoir annonce « forge jetable + runner CI + humain de demo ». Un drapeau accepte qui ne
  # fait rien est pire qu'un drapeau refuse : le refus laisse chercher, le silence laisse croire.
  grep -q 'export PROV_FORGE_MONTEE=1' "$PORTE"
  # et il traverse le `sudo` — ce qui n'est pas dans ESCALADE_ENV meurt a l'escalade, sans un mot
  grep -q 'PROV_FORGE_MONTEE' "$DEPLOY/workstation"
  grep -qE '^ESCALADE_ENV=\(.*PROV_FORGE_MONTEE' "$DEPLOY/workstation"
}

@test "C1 : le module HONORE la demande, meme quand FORGE_BASE_URL est posee" {
  # C'est le seul apport du drapeau sur ce rail : la montee est deja le defaut sans URL. S'il ne
  # gagnait pas sur `FORGE_BASE_URL`, il resterait exactement aussi inerte qu'avant.
  local mod="$MODS/48-forge-host.sh"
  local bloc; bloc="$(sed -n '/^if \[\[ "\${PROV_FORGE_MONTEE/,/^fi$/p' "$mod")"
  [ -n "$bloc" ]
  # la surcharge est TESTEE EN PREMIER, sinon `FORGE_BASE_URL` la court-circuite
  local n_montee n_url
  n_montee="$(grep -n 'PROV_FORGE_MONTEE' "$mod" | head -1 | cut -d: -f1)"
  n_url="$(grep -n 'elif \[\[ -n "\${FORGE_BASE_URL' "$mod" | head -1 | cut -d: -f1)"
  [ -n "$n_montee" ] && [ -n "$n_url" ]
  [ "$n_montee" -lt "$n_url" ]
}

@test "C1 : la banniere du POSTE ne promet pas ce que fait la BOITE" {
  # « forge jetable + runner CI + humain de demo » est vrai sur la boite. Le reprendre ici
  # promettrait deux choses que ce rail ne fait pas — elles sont l'axe DESTINATION, et il a son
  # porteur : `--disposable`.
  # ⚠ LE BLOC SE BORNE PAR SON DEBUT, PAS PAR SON NOM. `_box_emit "  RAIL POSTE …"` est la DERNIERE
  # ligne du bloc : partir de la faisait courir la plage jusqu'au `_box_emit` suivant — celui de la
  # BOITE — et le temoin rougissait sur la banniere qu'il n'examinait pas. Un intervalle `sed` mal
  # borne ne se voit pas, il change juste ce qu'on mesure.
  local bloc; bloc="$(sed -n '/Ce rail ne crée aucun humain/,/RAIL POSTE/p' "$PORTE")"
  [ -n "$bloc" ]
  grep -q 'bench' <<<"$bloc"                    # le bloc contient bien la ligne --bench du POSTE
  # Hors commentaires : le commentaire qui explique POURQUOI on ne reprend pas la phrase de la boite
  # la cite forcement. Un temoin qui lit la prose interdit d'expliquer ce qu'il garde.
  grep -vE '^[[:space:]]*#' <<<"$bloc" | refute_out 'runner CI|humain de d'
}

# ─── C2 — UN MODE AFFIRME SE POSE, ET SE VERIFIE ────────────────────────────────────────────────

@test "C2 : ~/.lcars/log est chmode par l'apply — il ne nait plus au umask" {
  # La table affirme 0700 ; l'apply creait le repertoire par `mkdir -p` et ne chmodait que `.lcars`
  # et `pods`. Mesure : 0755 chez les deux humains de la machine — l'ecart etait constant, pas
  # accidentel.
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/human.d/70-human.sh"
  local ligne; ligne="$(grep -n 'chmod 0700' "$mod" | head -1)"
  [ -n "$ligne" ]
  grep -q 'chmod 0700 .*\.lcars/log' "$mod"
}

@test "C2 : et le CHECK le regarde — sinon le doctor reste aveugle apres le correctif" {
  # L'angle mort etait double, et la seconde moitie est la plus sournoise : corriger l'apply sans
  # toucher au check aurait rendu le defaut invisible au lieu de le fermer.
  local mod="$BATS_TEST_DIRNAME/../../runtime/services/human.d/70-human.sh"
  local bloc; bloc="$(sed -n '/^check()/,/^}$/p' "$mod")"
  grep -q '\.lcars/log' <<<"$bloc"
}

# ─── C3 — UN ECHEC AVALE EST UN ETAT QUE PERSONNE NE CONNAIT ────────────────────────────────────

@test "C3 : l'echec du chown sur ~/.claude est DIT, plus avale" {
  # `2>/dev/null || true` sur le seul geste qui rend `~/.claude` et `~/.claude/skills` a leur
  # proprietaire — les deux naissent `root:root` du `mkdir -p`. Quand il echouait, deux repertoires
  # du home d'un humain restaient au groupe root ET le module annoncait « skill pose ».
  local mod="$MODS/45-sudoers-toolchain.sh"
  local bloc; bloc="$(sed -n '/chown -h "\$PROV_HUMAN:"/,/^          fi$/p' "$mod")"
  [ -n "$bloc" ]
  refute grep -q '|| true' <<<"$bloc"
  grep -q 'p_drift' <<<"$bloc"
  # et le p_ok ne survit plus a l'echec : il est dans la branche qui reussit
  grep -q 'if chown -h' <<<"$bloc"
}

# ─── C4 — `cp -a` PRESERVE LE PROPRIETAIRE DE LA SOURCE ─────────────────────────────────────────

@test "C4 : le contenu de /usr/share/lcars est rendu a root, pas laisse a l'operateur" {
  # Les deux `find … chmod` rattrapaient les modes et JAMAIS les proprietaires. Un arbre systeme
  # portait donc l'identite de qui avait lance l'install, et changeait de proprietaire selon QUI
  # deployait — sur un objet que la table declare `root:root`.
  local mod="$MODS/44-media.sh"
  grep -q 'chown -R root:root "$MEDIA_ROOT"' "$mod"
  # APRES les chmod : un chown qui precederait serait defait par rien, mais l'ordre dit l'intention
  local n_chmod n_chown
  n_chmod="$(grep -n 'find "$MEDIA_ROOT" -type f' "$mod" | head -1 | cut -d: -f1)"
  n_chown="$(grep -n 'chown -R root:root' "$mod" | head -1 | cut -d: -f1)"
  [ "$n_chmod" -lt "$n_chown" ]
}

# ─── C6 — LA COPIE EMBARQUEE PORTE CE DONT LE RAIL POSE A BESOIN ────────────────────────────────

@test "C6 : la copie embarquee emporte services/ — le module en depend LUI-MEME" {
  # ⚠ LE DEFAUT LE PLUS CHER DU RANG, ET IL TENAIT EN UN MOT. `62-runtime-helpers` pose onze
  # auxiliaires depuis `$(product_tree)/services` et n'emportait pas ce repertoire : sur une
  # machine provisionnee `repo_root()` resout `/opt/lcars`, et le comparateur n'avait jamais sa
  # source. Onze drifts « diverge de la source » par passage, tous faux.
  local mod="$MODS/62-runtime-helpers.sh"
  grep -qE '^EMBEDDED=\(.*services' "$mod"
  # et l'arbre que le module LIT est bien celui-la
  grep -q 'services' "$mod"
}

@test "C6 : le second lecteur de l'arbre est servi lui aussi" {
  # `25-directories` invoque `runtime/services/forge-gestures.sh builtin-human` pour connaitre
  # l'humain integre. Sans l'arbre, la sonde echouait derriere un `|| true` et rendait vide — le
  # repertoire de console de cet humain n'etait pas pose, sans un mot. Le meme correctif le sert.
  grep -q 'product_tree)/services/forge-gestures.sh' "$MODS/25-directories.sh"
  grep -qE '^EMBEDDED=\(.*services' "$MODS/62-runtime-helpers.sh"
}

# ─── C6, LA SUITE : LE RAIL POSE DOIT POUVOIR SE REJOUER ────────────────────────────────────────
#
# ⚠ MESURE DU 2026-09-01, BANC 2007. Un apply rejoue depuis `/opt/lcars/deploy/provision` —
# le rejeu depuis la copie posee, sur un poste sans checkout — echouait sur
# trois modules : « source absente : /opt/lcars/assets/avatars », « source runtime introuvable:
# /opt/lcars/services ». Le rail pose ne pouvait pas se rejouer entierement.
#
# `services` (C6) avait ete trouve parce qu il produisait ONZE FAUX DRIFTS visibles. Ceux-ci ne se
# voient qu en REJOUANT un apply depuis la copie — ce qu aucun geste de la suite ne faisait.

@test "C6+ : les arbres de la RACINE sont embarques, pas seulement ceux du produit" {
  local mod="$MODS/62-runtime-helpers.sh"
  grep -qE '^EMBEDDED_ROOT=\(.*assets' "$mod"
  grep -qE '^EMBEDDED_ROOT=\(.*catalogues' "$mod"
  # ⚠ DEUX LISTES, PAS UNE : la copie n a pas la meme forme. `EMBEDDED` va sous `fleet/`,
  # `EMBEDDED_ROOT` a cote. Les fondre ferait une liste dont chaque entree porte un chemin
  # implicite different.
  #
  # ⚠ ON VISE LE CHEMIN, PAS L OUTIL — et la premiere version visait l outil. Elle epinglait
  # `cp -a` pour la boucle de `fleet/` et `cd` pour celle de la racine : deux outils differents
  # etaient alors le signe le plus visible de deux listes, mais ce n est pas ce que ce temoin veut
  # dire. Le jour ou la boucle de `fleet/` est passee a `tar` elle aussi (pour cesser d emporter
  # 73 Mo de cache tofu), ce temoin a rougi sur un CORRECTIF — en accusant la seule chose qu il ne
  # mesurait pas. Ce qui distingue les deux listes est le chemin d ou elles partent, et lui seul.
  grep -q 'cd "$(product_tree)/$n"' "$mod"
  grep -q 'cd "$(repo_root)/$n"' "$mod"
}

@test "C6+ : ce que les modules LISENT a la RACINE (repo_root) est ce qui est embarque" {
  # Le sens qui ferme la boucle : si un module se met a lire un troisieme arbre de la racine, ce
  # temoin le dit. C est la moitie qui manquait a C6 — on avait ajoute `services` sans verifier
  # qu il ne restait rien d autre.
  local lus; lus="$(grep -rhoE 'repo_root\)/[a-z]+' "$MODS"/*.sh "$DEPLOY"/lib/*.sh 2>/dev/null \
    | sed 's|repo_root)/||' | sort -u | grep -vE '^(fleet|runtime)$')"
  local n
  for n in $lus; do
    grep -qE "^EMBEDDED_ROOT=\(.*\b$n\b" "$MODS/62-runtime-helpers.sh" \
      || { echo "lu sous repo_root mais PAS embarque : $n"; return 1; }
  done
}

# ⚠ CE TEMOIN-CI EST LA MOITIE QUE LE PRECEDENT N AVAIT PAS, ET SON ABSENCE A COUTE UN QUATRIEME
# DEFAUT DU MEME MOTIF. Celui du dessus ne regarde que les arbres de la RACINE (`assets`,
# `catalogues`). Les SOUS-ARBRES de `fleet/` relevent d une autre liste — `EMBEDDED` — et personne
# ne verifiait qu elle etait complete.
#
# MESURE DU 2026-09-02, BANC 2006 : `BIN_SRC_DIR="$(product_tree)/bin"` est lu par
# `62-runtime-helpers` lui-meme, `runtime/bin` n etait pas dans `EMBEDDED`, et un apply rejoue depuis
# /opt/lcars rendait « pose ratée: /usr/local/bin/lcars-toolchain-converge ». Le module echouait a
# poser un binaire dont il est l unique poseur, faute d avoir embarque sa propre source.
#
# Les deux temoins couvrent donc les deux niveaux, et ils sont distincts parce que les deux listes
# le sont : `EMBEDDED` va sous `fleet/`, `EMBEDDED_ROOT` a cote.
@test "C6+ : ce que les modules LISENT dans l ARBRE PRODUIT (product_tree) est dans EMBEDDED" {
  local lus; lus="$(grep -rhoE 'product_tree\)/[a-z_]+' "$MODS"/*.sh "$DEPLOY"/lib/*.sh 2>/dev/null \
    | sed 's|product_tree)/||' | sort -u)"
  [ -n "$lus" ] || { echo "extraction ratee : aucune lecture sous product_tree trouvee"; return 1; }
  local n manquants=""
  for n in $lus; do
    # `_build` est l arbre de BUILD : il ne s embarque pas, il se consomme la ou il est bati.
    # `prov_release_bin` le cherche dans le PAQUET, jamais dans la copie posee.
    [ "$n" = "_build" ] && continue
    grep -qE "^EMBEDDED=\(.*\b$n\b" "$MODS/62-runtime-helpers.sh" || manquants="$manquants $n"
  done
  [ -z "$manquants" ] \
    || { echo "lu sous product_tree mais PAS dans EMBEDDED :$manquants"; return 1; }
}

@test "C6+ : node_modules est EXCLU — 179 Mo sur 180" {
  # `assets/` pese 180 Mo sur disque et 904 Ko dans git : tout le reste est l arbre npm de la doc,
  # un artefact local. Un `cp -a` l aurait recopie sous /opt/lcars a CHAQUE apply.
  # ⚠ `dist/` RESTE : en livraison binaire c est lui que `44-media` pose, rien ne le batit la.
  local mod="$MODS/62-runtime-helpers.sh"
  grep -q 'exclude=node_modules' "$mod"
  grep -vE '^\s*#' "$mod" | refute_out 'exclude=dist'
}

@test "C6+ : le CHECK sonde la seconde liste — sinon le correctif est invisible" {
  # L angle mort double deja rencontre sur `~/.lcars/log` (C2) : corriger l apply sans toucher au
  # check rend le defaut invisible au lieu de le fermer.
  local bloc; bloc="$(sed -n '/^check()/,/^}$/p' "$MODS/62-runtime-helpers.sh")"
  grep -q 'EMBEDDED_ROOT' <<<"$bloc"
  grep -q 'arbre embarqué ABSENT' <<<"$bloc"
}
