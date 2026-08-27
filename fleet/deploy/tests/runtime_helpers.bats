#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/runtime_helpers.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-21
# STATUS: bats tests for 62-runtime-helpers — ce que le `COPY` du Dockerfile pose, et que le rail poste ne posait pas
#
# ⚖ USER 2026-08-21 : « l'installeur doit livrer un système qui fonctionne. »
#
# CE QUE CES TEMOINS FERMENT. La console web, la landing, le convergeur d'humains et le convergeur
# de toolchain n'etaient poses QUE par le Dockerfile. Sur une machine native ils n'existaient nulle
# part — et le provisionnement rendait VERT, parce qu'aucun module ne peut constater ce qu'aucun
# module ne pose.
#
# ⚠ AUCUN TEMOIN ICI NE VA SUR LE RESEAU. Le client de terminal se recupere par `fetch_verify`
# (pin sha256) : ce qui se mesure ici est la TABLE, l'egalite des pins avec le Dockerfile, et le
# REFUS d'un contenu non conforme — pas la capacite de jsdelivr a repondre.

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../modules.d/62-runtime-helpers.sh"
  DOCKERFILE="$BATS_TEST_DIRNAME/../docker/Dockerfile"
  SRC_DIR="$BATS_TEST_DIRNAME/../../services"
  BIN_SRC_DIR="$BATS_TEST_DIRNAME/../../bin"
  [ -f "$MOD" ] && [ -f "$DOCKERFILE" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  export PROVISION_MODULE=62-runtime-helpers
  export LCARS_HELPERS_DIR="$BATS_TEST_TMPDIR/opt/lcars"
  export LCARS_TOOLCHAIN_CONVERGE_BIN="$BATS_TEST_TMPDIR/usr/local/bin/lcars-toolchain-converge"
  # Meme seam, meme raison : un temoin ne peut pas ecrire dans `/usr/local/bin`. Sans lui, `apply`
  # echoue sur la pose, `verdict_apply` sort, et TROIS temoins voisins rougissent sur une cause qui
  # n'est pas la leur — ce qui deplace le diagnostic au lieu de le donner.
  export LCARS_AUTHORITY_ASK_BIN="$BATS_TEST_TMPDIR/usr/local/bin/lcars-authority-ask"
  # Le SQUELETTE des humains, meme couture et meme raison : sa destination reelle est `/etc/skel`,
  # ou aucun temoin n'ecrit. Sans cette ligne, `apply` echoue sur la pose et CINQ temoins voisins
  # rougissent sur une cause qui n'est pas la leur — mesure du 2026-08-26, en ajoutant la table DATA.
  export LCARS_SKEL_FILE="$BATS_TEST_TMPDIR/etc/skel/.bashrc"
  export LCARS_HELPERS_OWNER="$(id -un):$(id -gn)"
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP="$(id -gn)"
  export PROV_TOKENS_DIR="$BATS_TEST_TMPDIR/private"
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"; mkdir -p "$XDG_RUNTIME_DIR"; chmod 0700 "$XDG_RUNTIME_DIR"

  # ttyd : une doublure sur le PATH. Sans elle le module irait vers `apt`, qui exige root — et ce
  # n'est pas apt qu'on mesure, c'est la branche « il est deja la ».
  BINDIR="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BINDIR"
  printf '#!/usr/bin/env bash\necho "ttyd version 1.7.7-stub"\n' > "$BINDIR/ttyd"
  chmod 0755 "$BINDIR/ttyd"
  export PATH="$BINDIR:$PATH"
  # ⚠ LE BINAIRE SE NOMME, IL NE SE CHERCHE PAS DANS LE PATH — sinon le temoin « ttyd absent »
  # mesure la MACHINE. Mesure du 2026-08-21, passe a froid : retirer la doublure du PATH ne prouve
  # rien apres que `10-packages` a pose /usr/bin/ttyd, donc vert sur un poste de dev et ROUGE dans
  # l'install. Un temoin ne peut pas desinstaller ttyd ; il peut viser un chemin qu'il possede.
  export LCARS_TTYD_BIN="$BINDIR/ttyd"
}

mod() { run bash "$MOD" "$1"; }

@test "LCARS header: SOURCE/AUTHOR/STARDATE/STATUS + les trois en-tetes de module" {
  run head -9 "$MOD"
  [[ "$output" == *"SOURCE:"* ]]
  [[ "$output" == *"AUTHOR:"* ]]
  [[ "$output" == *"STARDATE:"* ]]
  [[ "$output" == *"STATUS:"* ]]
  [[ "$output" == *"APPLY-ON: wsl linux"* ]]
  [[ "$output" == *"CHECK-ON: any"* ]]
  [[ "$output" == *"NEEDS: root"* ]]
}

@test "sur une machine nue, le check DERIVE et nomme chaque manque" {
  mod check
  [ "$status" -eq 1 ]
  [[ "$output" == *"console.sh absent"* ]]
  [[ "$output" == *"human-converger.sh absent"* ]]
  [[ "$output" == *"client de terminal absent"* ]]
  [[ "$output" == *"lcars-toolchain-converge absent"* ]]
  [[ "$output" == *"provisionnement embarqué absent"* ]]
}

@test "le manque de ttyd se DIT avec sa consequence — une socket sans serveur derriere" {
  rm -f "$BINDIR/ttyd"
  mod check
  [[ "$output" == *"ttyd absent"* ]]
  [[ "$output" == *"page noire"* ]]
}

# ─── LA POSE ────────────────────────────────────────────────────────────────────────────────────
#
# `fetch_verify` est neutralise par une doublure de `curl` : le sujet ici est ce qui se pose depuis
# l'ARBRE (les auxiliaires, le binaire de toolchain, le provisionnement embarque), pas le reseau.

stub_curl() { # <contenu rendu par curl>
  cat > "$BINDIR/curl" <<EOF
#!/usr/bin/env bash
# -o <dest> est le seul argument qui nous interesse
dest=""
while [[ \$# -gt 0 ]]; do case "\$1" in -o) dest="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s' '$1' > "\$dest"
EOF
  chmod 0755 "$BINDIR/curl"
}

# LA LISTE VIENT DU MODULE, ELLE N'EST PAS RECOPIEE ICI. Deux temoins portaient chacun leur copie
# des huit noms : ajouter un auxiliaire au module les laissait VERTS sur l'ancienne liste, donc
# muets sur exactement ce qu'ils gardent. Un instrument qui mesure une copie de la source ne mesure
# pas la source — il est vert au moment precis ou ca derive.
helpers() {
  sed -n '/^HELPERS=(/,/^)/p' "$MOD" | sed '1d;$d;s/#.*//' | tr -d ' \t' | grep -v '^$'
}

@test "la liste des auxiliaires n'est pas VIDE — un instrument casse rend zero, comme un sans-faute" {
  # Sans ce garde, une extraction cassee (tableau renomme, parenthese deplacee) rendrait une liste
  # vide et les deux temoins ci-dessous passeraient en n'ayant RIEN verifie.
  [ "$(helpers | wc -l)" -ge 8 ]
  helpers | grep -qx 'console-deck.py'
}

@test "apply POSE les auxiliaires du module, identiques a leur source" {
  stub_curl "peu importe"
  mod apply

  local n
  while read -r n; do
    [ -x "$LCARS_HELPERS_DIR/$n" ]
    cmp -s "$SRC_DIR/$n" "$LCARS_HELPERS_DIR/$n"
  done < <(helpers)
}

@test "apply POSE le convergeur de toolchain au chemin que le sudoers etroit designe" {
  # `45-sudoers-toolchain` accorde `%fleet ALL=(root) NOPASSWD: /usr/local/bin/lcars-toolchain-converge`.
  # Sur le rail poste ce binaire n'etait pose par RIEN : la regle designait une absence.
  stub_curl "peu importe"
  mod apply
  [ -x "$LCARS_TOOLCHAIN_CONVERGE_BIN" ]
  cmp -s "$BIN_SRC_DIR/lcars-toolchain-converge" "$LCARS_TOOLCHAIN_CONVERGE_BIN"
}

@test "apply POSE le client d'autorite sur le PATH — sinon trois gestes d'operateur n'ont aucun jeton" {
  # `lcars publish run`, `lcars approve` et le skill `system-issues` du siege obtiennent leur jeton
  # de forge par ce seul binaire. Sur le rail poste, rien ne le posait avant cette ligne : les trois
  # seraient morts sur « commande introuvable », au moment ou quelqu'un les tape.
  stub_curl "peu importe"
  mod apply
  [ -x "$LCARS_AUTHORITY_ASK_BIN" ]
  cmp -s "$BIN_SRC_DIR/lcars-authority-ask" "$LCARS_AUTHORITY_ASK_BIN"
}

@test "check DIT l'absence du client d'autorite — elle ne se decouvre pas au premier publish" {
  # Sans cette ligne, l'absence ne se voit qu'a l'usage, sous uid humain, avec « commande
  # introuvable » pour tout diagnostic. Les services, eux, tournent en root et ne la sentent pas :
  # c'est exactement le genre de panne qui n'apparait qu'au pire moment.
  stub_curl "peu importe"
  mod check   # `mod()` porte deja le `run` — en imbriquer un second perd la sortie
  [[ "$output" == *"lcars-authority-ask"* ]]
}

@test "apply POSE le provisionnement EN FORME DE REPO — repo_root() doit s'y retrouver" {
  # Le convergeur appelle `/opt/lcars/fleet/deploy/provision`, et `repo_root()` de la lib remonte
  # trois crans depuis `fleet/deploy/lib/` : la forme de l'arbre EST le contrat.
  stub_curl "peu importe"
  mod apply
  [ -x "$LCARS_HELPERS_DIR/fleet/deploy/provision" ]
  [ -d "$LCARS_HELPERS_DIR/fleet/deploy/modules.d" ]
  [ -d "$LCARS_HELPERS_DIR/fleet/etc" ]
}

@test "un client de terminal NON CONFORME a son pin est REFUSE — rien n'est pose" {
  stub_curl "ceci nest pas xterm.js"
  mod apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"sha256 MISMATCH"* ]]
  [ ! -e "$LCARS_HELPERS_DIR/deck-static/xterm.js" ]
}

@test "rejoue : un auxiliaire deja identique n'est pas re-pose" {
  stub_curl "peu importe"
  mod apply
  local before; before="$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")"
  mod apply
  [ "$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")" = "$before" ]
}

# ─── LES DEUX RAILS DISENT LA MEME VERSION ──────────────────────────────────────────────────────

@test "les pins du client de terminal sont IDENTIQUES a ceux du Dockerfile" {
  # Deux rails, deux mecanismes, UNE version. Un bump joue d'un seul cote donnerait deux consoles
  # qui ne se comportent pas pareil, et c'est le genre d'ecart qu'on ne voit qu'a l'usage.
  local k
  for k in XTERM_JS_SHA256 XTERM_CSS_SHA256 XTERM_FIT_SHA256; do
    local from_mod from_docker
    from_mod="$(grep -oE "^${k}=[0-9a-f]+" "$MOD" | cut -d= -f2)"
    from_docker="$(grep -oE "ARG ${k}=[0-9a-f]+" "$DOCKERFILE" | cut -d= -f2)"
    [ -n "$from_mod" ]
    [ -n "$from_docker" ]
    [ "$from_mod" = "$from_docker" ]
  done
}

@test "la liste des auxiliaires est le MIROIR du COPY de l'image — sans entrypoint.sh" {
  # ⚠ CE TEMOIN PROMETTAIT « et reciproquement » ET NE LE FAISAIT PAS. Il portait une liste
  # RECOPIEE de huit noms et verifiait un seul sens ; un auxiliaire ajoute au module sans son `COPY`
  # passait au vert, et le rail conteneur demarrait un service sur un fichier absent. Les deux sens
  # sont derives, maintenant, et c'est ce qui rend la phrase vraie.
  local n
  while read -r n; do
    grep -q "COPY fleet/services/$n */opt/lcars/$n" "$DOCKERFILE"
  done < <(helpers)

  # ⚠ LE SENS INVERSE A DEMENAGE, IL N'A PAS DISPARU. Il vivait ici avec deux exemptions nommees, et
  # il ne regardait qu'une destination — `/opt/lcars/X`. Le temoin « TOUTE destination » plus bas le
  # remplace : il lit les `COPY` QUELLE QUE SOIT leur cible, et accepte les trois poseurs du module
  # (executables, donnees, binaires nommes). Le garder ici en double aurait fait deux regles pour un
  # fait, dont une plus etroite — et c'est toujours la plus etroite qu'on croit avoir lue.
  ! grep -qE '^\s+entrypoint\.sh$' "$MOD"
}

# La seconde table du module : <source> <destination> <mode>, une par ligne.
data_srcs() {
  sed -n '/^DATA=(/,/^)/p' "$MOD" | sed '1d;$d;s/#.*//' | tr -d '"' \
    | awk 'NF {print $1}'
}

# ⚠ LE FILET DU TROISIEME POSEUR, ET IL EST VIDE PAR CONSTRUCTION DEPUIS LE 2026-08-27. Deux
# fichiers passaient ici : ils allaient sur le PATH sous un AUTRE nom que leur source
# (`toolchain-converger.sh` → `lcars-toolchain-converge`), donc chacun avait son propre `install`.
# Le renommage n'encodait rien — il traduisait un rangement faux : ce sont des BINAIRES, pas des
# services, et rien ne les demarre. Ils vivent sous `fleet/bin/` avec leur nom definitif, comme
# `lcars` et `fleet_v2`.
# Ce filet RESTE : il attrape le jour ou quelqu'un pose un fichier de `services/` par un `install`
# nu au lieu d'une table. Il rend vide aujourd'hui, et c'est le bon etat.
sources_citees() { grep -oE '\$SRC_DIR/[A-Za-z0-9_.-]+' "$MOD" | sed 's|.*/||' | sort -u; }

@test "TOUTE destination de l'image a un poseur sur le rail poste — pas seulement /opt/lcars" {
  # ⚠ LE MUR PRECEDENT NE VOYAIT QU'UN MOTIF : `COPY fleet/services/X /opt/lcars/X`. Ce que le
  # Dockerfile pose AILLEURS lui echappait par CONSTRUCTION — pas par exemption, par angle mort.
  # Un fichier y vivait deja : `COPY fleet/services/skel.bashrc /etc/skel/.bashrc`, pose par l'image
  # et par RIEN sur le rail poste. Le convergeur cree les humains avec `useradd -m`, qui recopie
  # `/etc/skel` : en boite un humain recevait le prompt LCARS et ses alias, sur un poste le
  # `.bashrc` de la distribution. Deux environnements pour un meme role, silencieux des deux cotes.
  #
  # Ce temoin lit TOUTES les lignes `COPY fleet/services/...` quelle que soit leur destination, et
  # exige que chaque source soit posee par le module — en executable (`HELPERS`) ou en donnee
  # (`DATA`). L'exemption se reduit a `entrypoint.sh`, qui n'a aucun sens hors conteneur.
  local n vus=0
  while read -r n; do
    case "$n" in entrypoint.sh) continue ;; esac
    vus=$((vus + 1))
    helpers        | grep -qx "$n" && continue
    data_srcs      | grep -qx "$n" && continue
    sources_citees | grep -qx "$n" && continue
    echo "POSE PAR L'IMAGE, PAR PERSONNE SUR LE POSTE : fleet/services/$n"
    return 1
  done < <(sed -n 's|^COPY fleet/services/\([^ ]*\) .*|\1|p' "$DOCKERFILE")

  # ⚠ GARDE D'INSTRUMENT : un `sed` casse rend zero ligne, et zero ligne examinee se lit comme un
  # accord parfait. C'est la forme exacte du defaut que ce temoin vient fermer.
  [ "$vus" -ge 10 ] || { echo "seulement $vus COPY examinees — l'extraction est cassee"; return 1; }
}

@test "les DONNEES sont posees a leur destination, avec leur mode, et identiques a la source" {
  stub_curl "peu importe"
  mod apply

  # Les deux destinations du decor, derivees comme le module les derive.
  [ -f "$LCARS_HELPERS_DIR/console.tmux.conf" ]
  cmp -s "$SRC_DIR/console.tmux.conf" "$LCARS_HELPERS_DIR/console.tmux.conf"
  [ "$(stat -c %a "$LCARS_HELPERS_DIR/console.tmux.conf")" = "644" ]

  [ -f "$LCARS_SKEL_FILE" ]
  cmp -s "$SRC_DIR/skel.bashrc" "$LCARS_SKEL_FILE"
  [ "$(stat -c %a "$LCARS_SKEL_FILE")" = "644" ]

  # ⚠ ET PAS EXECUTABLES. C'est toute la raison de la seconde table : `HELPERS` pose en 0755, et
  # un `.bashrc` executable est un fichier que quelqu'un finira par lancer au lieu de le sourcer.
  [[ "$(stat -c %A "$LCARS_SKEL_FILE")" != *x* ]]
}

# ─── LA REVISION VOYAGE AVEC LA COPIE ───────────────────────────────────────────────────────────
#
# ⚠ TROIS DES TEMOINS CI-DESSOUS MESURENT UN CHECKOUT, PAS UN ARBRE LIVRE — ils lisent `git
# rev-parse` du depot pour savoir ce que le tampon DOIT contenir. `git archive` n'emporte jamais
# `.git`, donc une install depuis un tarball les jouait sur un arbre sans revision : trois rouges
# sur un module sain. Le garde va sur EUX et pas dans `setup()`, parce que les douze autres
# temoins de ce fichier mesurent la copie des auxiliaires, qui n'a pas besoin de depot.
#
# Mesure du 2026-08-22 : avec les neuf temoins de `git-hooks/tests`, ces trois-la tuaient
# `60-deploy` sur « arbre source non atteste » a chaque install depuis un tarball.
need_git_checkout() {
  git -C "$BATS_TEST_DIRNAME" rev-parse --git-dir >/dev/null 2>&1 \
    || skip "pas de checkout git (arbre livre par tarball) — ce temoin lit la revision du depot"
}
#
# ⚖ USER 2026-08-21, apres la panne : « le rail natif se met a jour depuis un clone git, et rien ne
# dit a quel commit ce clone est. Un provision apply sur un checkout en retard reinstalle
# silencieusement l'etat d'avant. Aucun verdict ne le voit. »
#
# CE QUE CA A COUTE, MESURE LE MEME JOUR : un correctif d'allocation d'uid pose et verifie sur une
# machine, puis un apply depuis un clone reste six commits en arriere qui REMET l'ancienne formule.
# Le service systemd tournait dessus. La collision d'uid suivante etait mecanique, et rien nulle
# part ne pouvait la relier a un arbre en retard — le module avait fait exactement son travail.

@test "apply TAMPONNE la revision, a la racine que repo_root() de la copie retrouve" {
  need_git_checkout
  # `repo_root()` remonte trois crans depuis `<...>/fleet/deploy/lib` : pour la copie, la racine est
  # $HELPERS_DIR, pas $HELPERS_DIR/fleet. Un tampon un cran plus bas ne serait lu par personne.
  stub_curl "peu importe"
  mod apply
  # ⚠ ON EPINGLE LA RELATION, PAS LE CHEMIN. Le tampon doit se poser LA OU `repo_root()` de la copie
  # ira le chercher — trois crans au-dessus de `<copie>/fleet/deploy/lib`. Aujourd'hui ca tombe sur
  # `$LCARS_HELPERS_DIR`, mais par COINCIDENCE arithmetique : deplacer la copie d'un cran
  # (`libexec/fleet`) ferait diverger les deux, le tampon serait pose a cote, lu par personne — et un
  # temoin qui epingle le chemin litteral resterait VERT.
  local lu; lu="$(cd "$LCARS_HELPERS_DIR/fleet/deploy/lib" && readlink -f ../../..)"
  [ -s "$lu/.source-revision" ]
  [ -s "$LCARS_HELPERS_DIR/.source-revision" ]
  [ "$(cat "$LCARS_HELPERS_DIR/.source-revision")" = "$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)$(cd "$BATS_TEST_DIRNAME" && git diff --quiet HEAD -- || echo '+local')" ]
}

@test "sans tampon, le check DIT qu'il ne sait pas — il ne suppose pas que c'est a jour" {
  mod check
  [[ "$output" == *"impossible de dire de quelle révision"* ]]
}

@test "une source EN RETARD sur ce qui est pose est un ECHEC, pas une note de bas de page" {
  need_git_checkout
  # Le cas exact de la panne : le tampon porte un descendant, l'arbre est son ancetre.
  stub_curl "peu importe"
  mod apply
  # HEAD~1 est un ancetre de HEAD : on fait donc croire que la source est en retard d'un commit.
  local head; head="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)"
  local prev; prev="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD~1)"
  echo "$head" > "$LCARS_HELPERS_DIR/.source-revision"

  PROV_SOURCE_REV="$prev" mod check
  [ "$status" -eq 2 ]
  [[ "$output" == *"LA SOURCE EST EN RETARD"* ]]
  [[ "$output" == *"ANCÊTRE"* ]]
}

@test "apply ANNONCE le retour en arriere AVANT de l'ecrire — apres, plus rien ne le dira" {
  need_git_checkout
  stub_curl "peu importe"
  mod apply
  local head; head="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)"
  local prev; prev="$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD~1)"
  echo "$head" > "$LCARS_HELPERS_DIR/.source-revision"

  rm -f "$LCARS_HELPERS_DIR/console.sh"
  PROV_SOURCE_REV="$prev" mod apply
  [[ "$output" == *"RETOUR EN ARRIÈRE"* ]]
  # Il ne REFUSE pas : un retour en arriere delibere est un geste legitime, il ne peut simplement
  # plus etre silencieux. La preuve qu'il a continue, c'est que la pose a EU LIEU — le code de
  # sortie, lui, appartient au client de terminal, que la doublure de `curl` fait toujours echouer.
  [ -x "$LCARS_HELPERS_DIR/console.sh" ]
}

@test "une parente INDETERMINABLE se dit — elle ne se lit ni comme a jour ni comme en retard" {
  stub_curl "peu importe"
  mod apply
  echo "deadbeef" > "$LCARS_HELPERS_DIR/.source-revision"
  mod check
  [[ "$output" == *"parenté indéterminable"* ]]
}

