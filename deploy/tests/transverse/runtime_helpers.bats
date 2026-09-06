#!/usr/bin/env bats
# SOURCE: deploy/tests/transverse/runtime_helpers.bats
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

# ⚠ SC2016 : CE TEMOIN LIT DU CODE. Ses motifs `grep`/`sed` portent des `${VAR:-defaut}` qui
# doivent atteindre l'outil TELS QUELS — les developper chercherait la valeur dans CE shell au lieu
# du texte audite. Les quotes simples sont l'instrument, pas un oubli.
# shellcheck disable=SC2016

load ../refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  MOD="$BATS_TEST_DIRNAME/../../modules.d/62-runtime-helpers.sh"
  DOCKERFILE="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  SRC_DIR="$BATS_TEST_DIRNAME/../../../runtime/services"
  BIN_SRC_DIR="$BATS_TEST_DIRNAME/../../../runtime/bin"
  [ -f "$MOD" ] && [ -f "$DOCKERFILE" ]

  export PROVISION_LIB="$BATS_TEST_DIRNAME/../../lib/provision-lib.sh"
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
  # Meme couture, meme raison : le reglage de shell va sous /etc/lcars, ou aucun temoin n ecrit.
  export LCARS_BASHRC_FILE="$BATS_TEST_TMPDIR/etc/lcars/lcars.bashrc"
  export LCARS_HELPERS_OWNER
  LCARS_HELPERS_OWNER="$(id -un):$(id -gn)"
  export PROV_SUBSTRATE=linux
  export PROV_HUMAN
  PROV_HUMAN="$(id -un)"
  export PROV_FLEET_GROUP
  PROV_FLEET_GROUP="$(id -gn)"
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
  # Le CANAL est a nous : absent = « aucun », donc le rail pose comme aujourd'hui. Sans cette
  # ligne, un poste installe par paquet (/etc/lcars/channel = deb) verrait tous ces temoins
  # mesurer sa machine — l'apply ne poserait plus rien, et rien ici ne dirait pourquoi.
  export LCARS_CHANNEL_FILE="$BATS_TEST_TMPDIR/etc/lcars/channel"
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
  # Le convergeur appelle `/opt/lcars/deploy/provision`, et `repo_root()` de la lib remonte
  # trois crans depuis `deploy/lib/` : la forme de l'arbre EST le contrat.
  stub_curl "peu importe"
  mod apply
  [ -x "$LCARS_HELPERS_DIR/deploy/provision" ]
  [ -d "$LCARS_HELPERS_DIR/deploy/modules.d" ]
  [ -d "$LCARS_HELPERS_DIR/etc" ]
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
    grep -q "COPY runtime/services/$n */opt/lcars/$n" "$DOCKERFILE"
  done < <(helpers)

  # ⚠ LE SENS INVERSE A DEMENAGE, IL N'A PAS DISPARU. Il vivait ici avec deux exemptions nommees, et
  # il ne regardait qu'une destination — `/opt/lcars/X`. Le temoin « TOUTE destination » plus bas le
  # remplace : il lit les `COPY` QUELLE QUE SOIT leur cible, et accepte les trois poseurs du module
  # (executables, donnees, binaires nommes). Le garder ici en double aurait fait deux regles pour un
  # fait, dont une plus etroite — et c'est toujours la plus etroite qu'on croit avoir lue.
  refute grep -qE '^\s+entrypoint\.sh$' "$MOD"
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
# services, et rien ne les demarre. Ils vivent sous `runtime/bin/` avec leur nom definitif, comme
# `lcars` et `fleet`.
# Ce filet RESTE : il attrape le jour ou quelqu'un pose un fichier de `services/` par un `install`
# nu au lieu d'une table. Il rend vide aujourd'hui, et c'est le bon etat.
sources_citees() { grep -oE '\$SRC_DIR/[A-Za-z0-9_.-]+' "$MOD" | sed 's|.*/||' | sort -u; }

@test "TOUTE destination de l'image a un poseur sur le rail poste — pas seulement /opt/lcars" {
  # ⚠ LE MUR PRECEDENT NE VOYAIT QU'UN MOTIF : `COPY runtime/services/X /opt/lcars/X`. Ce que le
  # Dockerfile pose AILLEURS lui echappait par CONSTRUCTION — pas par exemption, par angle mort.
  # Un fichier y vivait deja : `COPY runtime/services/skel.bashrc /etc/skel/.bashrc`, pose par l'image
  # et par RIEN sur le rail poste. Le convergeur cree les humains avec `useradd -m`, qui recopie
  # `/etc/skel` : en conteneur un humain recevait le prompt LCARS et ses alias, sur un poste le
  # `.bashrc` de la distribution. Deux environnements pour un meme role, silencieux des deux cotes.
  #
  # Ce temoin lit TOUTES les lignes `COPY runtime/services/...` quelle que soit leur destination, et
  # exige que chaque source soit posee par le module — en executable (`HELPERS`) ou en donnee
  # (`DATA`). L'exemption se reduit a `entrypoint.sh`, qui n'a aucun sens hors conteneur.
  # ⚠ IL Y A UNE TROISIEME VOIE, ET ELLE N'EST PAS UNE EXEMPTION. `HELPERS` et `DATA` existent parce
  # que l'image pose ces fichiers AILLEURS que la ou la copie embarquee les met — `console.sh` va en
  # `/opt/lcars/console.sh`, pas en `/opt/lcars/services/console.sh` — donc le module doit les
  # y poser explicitement. Une source dont le `COPY` vise EXACTEMENT la destination de la boucle
  # `EMBEDDED` n'a, elle, rien a poser en plus : `EMBEDDED` copie `runtime/services` EN ENTIER, donc
  # elle y est deja. C'est le cas de la recette de la charte forge depuis qu'elle a quitte
  # `deploy/deps` — un repertoire, pas un fichier, qu'aucune des deux tables ne peut nommer.
  #
  # ⚠ LA CONDITION EST DOUBLE, ET LA SECONDE MOITIE EST CE QUI EMPECHE LE TROU : la destination doit
  # coincider ET `services` doit reellement figurer dans `EMBEDDED`. Le retirer de cette liste — le
  # defaut deja vu deux fois, sur `services` puis sur `bin` — rouvrirait ce temoin au lieu de le
  # laisser vert sur une couverture qui n'existe plus.
  local n dest vus=0
  while read -r n dest; do
    case "$n" in entrypoint.sh) continue ;; esac
    vus=$((vus + 1))
    helpers        | grep -qx "$n" && continue
    data_srcs      | grep -qx "$n" && continue
    sources_citees | grep -qx "$n" && continue
    if [ "$dest" = "/opt/lcars/services/$n" ] \
       && grep -qE '^EMBEDDED=\(.*\bservices\b' "$MOD"; then continue; fi
    echo "POSE PAR L'IMAGE, PAR PERSONNE SUR LE POSTE : runtime/services/$n (destination $dest)"
    return 1
  done < <(sed -n 's|^COPY runtime/services/\([^ ]*\) \{1,\}\([^ ]*\).*|\1 \2|p' "$DOCKERFILE")

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

  [ -f "$LCARS_BASHRC_FILE" ]
  cmp -s "$SRC_DIR/lcars.bashrc" "$LCARS_BASHRC_FILE"
  [ "$(stat -c %a "$LCARS_BASHRC_FILE")" = "644" ]

  # ⚠ ET PAS EXECUTABLES. C est toute la raison de la seconde table : `HELPERS` pose en 0755, et
  # un fichier de reglage executable est un fichier que quelqu un finira par lancer au lieu de le
  # sourcer.
  [[ "$(stat -c %A "$LCARS_BASHRC_FILE")" != *x* ]]
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
  # `repo_root()` remonte trois crans depuis `<...>/deploy/lib` : pour la copie, la racine est
  # $HELPERS_DIR, pas $HELPERS_DIR/fleet. Un tampon un cran plus bas ne serait lu par personne.
  stub_curl "peu importe"
  mod apply
  # ⚠ ON EPINGLE LA RELATION, PAS LE CHEMIN. Le tampon doit se poser LA OU `repo_root()` de la copie
  # ira le chercher — trois crans au-dessus de `<copie>/deploy/lib`. Aujourd'hui ca tombe sur
  # `$LCARS_HELPERS_DIR`, mais par COINCIDENCE arithmetique : deplacer la copie d'un cran
  # (`libexec/fleet`) ferait diverger les deux, le tampon serait pose a cote, lu par personne — et un
  # temoin qui epingle le chemin litteral resterait VERT.
  # ⚠ ON DEMANDE LA REMONTEE A LA LIB, ON NE LA RECOPIE PAS. Cette ligne portait `readlink -f
  # ../../..` — le decompte de crans de `repo_root()`, duplique ici. Il a rougi le jour ou
  # l'installeur est sorti de `fleet/` et ou la remontee est passee a DEUX crans : un temoin qui se
  # dit « immunise au chemin » l'etait au chemin, pas a l'arithmetique. Sourcer la lib de la COPIE
  # et l'interroger supprime la seconde copie.
  local lu
  lu="$(PROVISION_LIB="$LCARS_HELPERS_DIR/deploy/lib/provision-lib.sh" \
        bash -c '. "$PROVISION_LIB" >/dev/null 2>&1; repo_root')"
  [ -n "$lu" ] || { echo "la lib de la copie ne rend aucune racine"; return 1; }
  [ -s "$lu/.helpers-revision" ]
  [ -s "$LCARS_HELPERS_DIR/.helpers-revision" ]
  [ "$(cat "$LCARS_HELPERS_DIR/.helpers-revision")" = "$(cd "$BATS_TEST_DIRNAME" && git rev-parse --short=8 HEAD)$(cd "$BATS_TEST_DIRNAME" && git diff --quiet HEAD -- || echo '+local')" ]
}

# ─── LE TAMPON N EST PLUS LE DISCRIMINANT DE LIVRAISON — ILS PORTAIENT LE MEME NOM ──────────────
#
# ⚠ CE FICHIER EPINGLAIT LA CAUSE. Le temoin ci-dessus exigeait que le tampon tombe exactement sur
# le `repo_root()` de la copie — ce qui est juste — mais ce tampon s appelait `.source-revision`,
# c est-a-dire le nom que `prov_delivery` cherche a la racine d un arbre pour dire BINAIRE ou
# SOURCE. Rejouer `/opt/lcars/deploy/provision` (la copie posee, sur un poste sans checkout) faisait donc
# lire le tampon des auxiliaires comme « ce repertoire est un paquet » : un poste installe depuis un
# clone se declarait BINAIRE, `15-toolchain` rendait « toolchain non requise » sans jamais evaluer
# son plancher OTP, et `16-node` ne mesurait plus rien.
@test "le tampon des auxiliaires n est PAS le discriminant de livraison" {
  need_git_checkout
  stub_curl "peu importe"
  mod apply
  # La source de ce decor est un clone : la copie doit donc se declarer SOURCE, donc ne porter
  # AUCUN `.source-revision` — alors qu elle porte bien son tampon d auxiliaires.
  [ -s "$LCARS_HELPERS_DIR/.helpers-revision" ]
  [ ! -e "$LCARS_HELPERS_DIR/.source-revision" ] \
    || { echo "la copie porte un discriminant de livraison que rien ne justifie"; return 1; }
}

# ⚠ LE DECOR POSSEDE SA PROPRE RACINE, ET IL LE DOIT. `prov_delivery` lit son discriminant a la
# racine de la SOURCE, c est-a-dire au `repo_root()` de la lib qui tourne. Faire passer l arbre de
# travail pour un paquet reviendrait a ECRIRE dans le depot — un temoin interrompu y laisserait un
# `.source-revision` que `pack.sh` refuserait et que `prov_delivery` lirait ensuite comme vrai.
#
# `readlink -f` canonicalise AVANT de remonter les `..` : un `deploy/lib` en lien symbolique
# ferait donc retomber `repo_root()` sur le vrai depot. Les deux repertoires que la remontee
# traverse sont COPIES (116 Ko + 316 Ko) ; tout le reste est lie — `runtime/deps` seul pese 74 Mo et
# `assets/` 180 Mo, un decor qui les copierait ne serait pas un decor.
racine_paquet() { # racine_paquet -> chemin d une racine de SOURCE qui se declare « paquet »
  local src="$BATS_TEST_TMPDIR/paquet"
  # ⚠ LES DEUX ARBRES SE CREENT SEPAREMENT DEPUIS LA SEPARATION. `mkdir -p "$src/fleet/deploy"`
  # faisait les deux d'un coup quand l'installeur vivait sous le runtime ; `$src/deploy` seul laisse
  # `$src/fleet` inexistant, et les trois `ln -s` ci-dessous meurent sur « No such file or
  # directory » — un decor qui ne se construit pas, donc des temoins rouges sur leur harnais et non
  # sur leur sujet.
  mkdir -p "$src/deploy" "$src/runtime"
  cp -a "$BATS_TEST_DIRNAME/../../lib"       "$src/deploy/lib"
  cp -a "$BATS_TEST_DIRNAME/../../modules.d" "$src/deploy/modules.d"
  ln -s "$BATS_TEST_DIRNAME/../../../runtime/etc"      "$src/runtime/etc"
  ln -s "$BATS_TEST_DIRNAME/../../../runtime/services" "$src/runtime/services"
  ln -s "$BATS_TEST_DIRNAME/../../../runtime/bin"      "$src/runtime/bin"
  ln -s "$BATS_TEST_DIRNAME/../../../assets"     "$src/assets"
  ln -s "$BATS_TEST_DIRNAME/../../../catalogues" "$src/catalogues"
  echo "cafe1234" > "$src/.source-revision"
  printf '%s\n' "$src"
}

@test "la copie d une livraison BINAIRE porte le discriminant — sinon le rejeu reclame un toolchain" {
  # Le defaut symetrique, et il serait pire : sans propagation, un apply rejoue depuis la copie
  # d une machine installee PAR PAQUET se declarerait SOURCE et exigerait des compilateurs sur un
  # conteneur dont c est justement le contraire qui a ete decide.
  stub_curl "peu importe"
  local src; src="$(racine_paquet)"
  run env PROVISION_LIB="$src/deploy/lib/provision-lib.sh" \
    bash "$src/deploy/modules.d/62-runtime-helpers.sh" apply
  [ -s "$LCARS_HELPERS_DIR/.source-revision" ] \
    || { echo "la forme BINAIRE n a pas ete propagee dans la copie"; echo "$output"; return 1; }
  [ "$(cat "$LCARS_HELPERS_DIR/.source-revision")" = "cafe1234" ]
  # et le tampon des auxiliaires reste un objet SEPARE, il ne devient pas le discriminant
  [ -s "$LCARS_HELPERS_DIR/.helpers-revision" ]
}

@test "TEMOIN DU TEMOIN : la racine du decor est bien vue comme un PAQUET, pas comme le depot" {
  # Sans cette mesure, le temoin precedent serait vert sur un decor qui aurait silencieusement
  # retrouve le vrai depot — et il mesurerait alors la livraison de la machine qui le joue.
  local src; src="$(racine_paquet)"
  run env PROVISION_LIB="$src/deploy/lib/provision-lib.sh" bash -c '
    . "$PROVISION_LIB"; printf "%s %s\n" "$(repo_root)" "$(prov_delivery)"'
  [[ "$output" == "$src binary" ]] \
    || { echo "le decor ne tient pas sa propre racine : $output"; return 1; }
}

# ─── CE QUE LA COPIE EMPORTAIT, ET QUE `git` NE VOIT MEME PAS ───────────────────────────────────
#
# ⚠ 73 Mo SUR 76, ET AUCUN N'EST VERSIONNE. Mesure du 2026-09-02 sur l'arbre de travail :
# `deploy` pese 2,4 Mo dans git et 76 Mo sur disque. L'ecart ENTIER est le cache de providers
# tofu (`deps/.terraform` + `deps/instance/.terraform`), que la boucle `EMBEDDED` recopiait sous
# `/opt/lcars` a chaque apply. C'est le meme defaut que les 176 Mo de `npm ci` — deja corrige pour
# la boucle de la RACINE (`--exclude=node_modules`, et son commentaire dit « un artefact local que
# `cp -a` aurait recopie »), jamais applique a celle-ci.
#
# ⚠ ET LE `.tfstate` EST LE CAS GRAVE, PAS LE CAS DE FIGURE. `forge-gestures.sh` l'ecrit noir sur
# blanc : « `cmd_apply` joue la recette DANS `$RECIPE_DIR`, donc y laisse un `terraform.tfstate` ».
# Sur un poste ou l'operateur a joue la recette depuis son checkout, ce fichier EXISTE, il porte les
# jetons de la forge, et `cp -a` le posait sous un prefix lisible par tout le groupe `fleet`.
#
# ⚠ LE DECOR PORTE AUSSI UN FICHIER QUI DOIT ARRIVER (`charte.tf`). Sans lui, ces temoins seraient
# verts sur un module qui ne copie plus RIEN — le seul echec qu'une liste d'exclusions puisse
# produire en silence.
#
# ⚠ ET LE DECOR DOIT POSSEDER L ARBRE OU IL ECRIT. `racine_paquet` LIE `runtime/services` au vrai
# depot (il ne COPIE que `lib/` et `modules.d/`, les deux repertoires que la remontee de
# `repo_root()` traverse). Ce temoin-ci, lui, ECRIT dans l arbre qu il vise : sans la substitution
# ci-dessous, le `mkdir` traverserait le lien et poserait un `.terraform`, un `terraform.tfstate` et
# un `secrets.tfvars` DANS `runtime/services/forge-recipe/` — c est-a-dire dans le depot, sous des noms
# que le `.gitignore` de la recette rend invisibles a `git status`. Un temoin qui salit son sujet
# est pire qu un temoin absent : le suivant mesure la salissure.
#
# La copie coute 476 Ko, et elle est le prix de l ecriture. Les temoins qui ne font que LIRE
# gardent le lien.
racine_avec_artefacts() { # racine_avec_artefacts -> decor + les artefacts locaux de la recette tofu
  local src; src="$(racine_paquet)"
  rm -f "$src/runtime/services"
  cp -a "$BATS_TEST_DIRNAME/../../../runtime/services" "$src/runtime/services" \
    || { echo "decor : services non copiable"; return 1; }
  # ⚠ ET ON VERIFIE QUE CE N EST PLUS UN LIEN. Si la ligne du dessus changeait de forme, l ecriture
  # repartirait en silence vers le depot — le defaut exact que cette garde existe pour rendre
  # impossible.
  [ ! -L "$src/runtime/services" ] || { echo "decor : services est encore un LIEN vers le depot"; return 1; }
  mkdir -p "$src/runtime/services/forge-recipe/.terraform/providers"
  head -c 4096 /dev/zero > "$src/runtime/services/forge-recipe/.terraform/providers/gros.bin"
  printf '{"outputs":{"admin_token":{"value":"JETON-DE-FORGE"}}}\n' \
    > "$src/runtime/services/forge-recipe/terraform.tfstate"
  printf 'admin_token = "JETON-DE-FORGE"\n' > "$src/runtime/services/forge-recipe/secrets.tfvars"
  printf 'resource "gitea_org" "x" {}\n'    > "$src/runtime/services/forge-recipe/charte.tf"
  printf '%s\n' "$src"
}

@test "EMBEDDED : le cache de providers tofu n'est JAMAIS recopie sous le prefix" {
  stub_curl "peu importe"
  local src; src="$(racine_avec_artefacts)"
  run env PROVISION_LIB="$src/deploy/lib/provision-lib.sh" \
    bash "$src/deploy/modules.d/62-runtime-helpers.sh" apply
  local pose="$LCARS_HELPERS_DIR/services/forge-recipe"
  # LE TEMOIN DU TEMOIN D'ABORD : la recette elle-meme est bien arrivee. Sans cette ligne, un module
  # qui ne copie plus rien passerait les trois assertions suivantes.
  [ -s "$pose/charte.tf" ] \
    || { echo "la recette n'est pas arrivee — l'exclusion mord ce qu'elle ne doit pas"; echo "$output"; return 1; }
  [ ! -e "$pose/.terraform" ] \
    || { echo "le cache de providers a ete recopie sous le prefix ($pose/.terraform)"; return 1; }
}

@test "EMBEDDED : l'etat tofu et ses variables — les JETONS ne voyagent pas sous /opt/lcars" {
  stub_curl "peu importe"
  local src; src="$(racine_avec_artefacts)"
  run env PROVISION_LIB="$src/deploy/lib/provision-lib.sh" \
    bash "$src/deploy/modules.d/62-runtime-helpers.sh" apply
  local pose="$LCARS_HELPERS_DIR/services/forge-recipe"
  [ -s "$pose/charte.tf" ] || { echo "decor casse : la recette n'est pas arrivee"; echo "$output"; return 1; }
  [ ! -e "$pose/terraform.tfstate" ] \
    || { echo "l'etat tofu — donc les jetons — a ete pose sous le prefix"; return 1; }
  [ ! -e "$pose/secrets.tfvars" ] \
    || { echo "les variables tofu ont ete posees sous le prefix"; return 1; }
  # ⚠ ET ON CHERCHE LE JETON LUI-MEME, pas seulement les noms de fichiers : c'est la consequence
  # qu'on refuse, pas la forme. Un futur artefact d'un autre nom porterait la meme fuite.
  ! grep -rq 'JETON-DE-FORGE' "$LCARS_HELPERS_DIR" 2>/dev/null \
    || { echo "un jeton de forge est lisible sous $LCARS_HELPERS_DIR"; return 1; }
}

@test "EMBEDDED et EMBEDDED_ROOT partagent UNE liste d'exclusions — deux copies derivent" {
  # Le defaut d'origine EST une seconde liste : la boucle de la racine excluait `node_modules`, la
  # boucle de `fleet/` n'excluait rien, et le commentaire qui justifiait l'exclusion vivait a cote
  # de celle qui l'appliquait. Une seule declaration, deux copieurs — et, depuis le lot 15, le
  # check qui relit les arbres : ce que la copie n'emporte pas, il ne le juge pas. Ce temoin
  # comptait « exactement deux » usages de la liste, un inventaire relu comme une regle.
  [ "$(grep -c -- 'tar -cf - "${EMBEDDED_EXCLUDE\[@\]}"' "$MOD")" -eq 2 ] \
    || { echo "les deux boucles ne partagent pas la meme liste d'exclusions"; return 1; }
  grep -q 'for x in "${EMBEDDED_EXCLUDE\[@\]}"' "$MOD" \
    || { echo "le check ne relit pas la liste d'exclusions : il jugerait ce que la copie n'emporte pas"; return 1; }
  grep -qE '^\s*--exclude=\.terraform$' "$MOD"
  grep -qE '^\s*--exclude=node_modules$' "$MOD"
  # ⚠ ET PLUS AUCUN `cp -a` DANS LA POSE : c'est lui qui ne pouvait pas exclure a la source.
  ! grep -q 'cp -a "$(product_tree)/\$n"' "$MOD" \
    || { echo "la boucle EMBEDDED copie encore par cp -a, qui n'exclut rien"; return 1; }
}

@test "MIGRATION : un discriminant PERIME est retire, il ne survit pas a sa cause" {
  # Le fichier herite d avant ce correctif — un tampon d auxiliaires ecrit sous le nom du
  # discriminant. Un apply en livraison source doit le RETIRER, sinon la machine continue de se
  # declarer binaire pour toujours.
  need_git_checkout
  stub_curl "peu importe"
  mkdir -p "$LCARS_HELPERS_DIR"
  echo "vieux1234" > "$LCARS_HELPERS_DIR/.source-revision"
  mod apply
  [ ! -e "$LCARS_HELPERS_DIR/.source-revision" ] \
    || { echo "le discriminant perime a survecu a l apply"; return 1; }
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
  echo "$head" > "$LCARS_HELPERS_DIR/.helpers-revision"

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
  echo "$head" > "$LCARS_HELPERS_DIR/.helpers-revision"

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
  echo "deadbeef" > "$LCARS_HELPERS_DIR/.helpers-revision"
  mod check
  [[ "$output" == *"parenté indéterminable"* ]]
}


# ─── LE SQUELETTE DE LA DISTRIBUTION SURVIT — C EST CE QUE LE RACCORD ACHETE ────────────────────
#
# ⚠ JUSQU AU 2026-09-02, LE RAIL ECRASAIT `/etc/skel/.bashrc` PAR UNE COPIE DE 117 LIGNES dont trois
# etaient a nous. L original n etait sauvegarde nulle part, et le manifeste l ECRIVAIT :
# « restaurer l original demanderait de l avoir sauvegarde, ce qu on ne fait pas ». Une machine
# desinstallee gardait notre squelette a la place du sien, pour toujours.
#
# `ensure_managed_block` existait depuis le debut, garde par cinq temoins de la lib, et n avait
# AUCUN appelant. Le depot portait la forme juste pendant qu on ecrasait.
@test "SKEL : le .bashrc preexistant est PRESERVE octet pour octet — on ajoute, on ne remplace pas" {
  stub_curl "peu importe"
  mkdir -p "$(dirname "$LCARS_SKEL_FILE")"
  # Un squelette de distribution, avec une ligne que personne d autre ne doit toucher.
  printf '# .bashrc de la distribution\nexport MARQUEUR_DISTRIBUTION=intact\nalias ll="ls -alF"\n' \
    > "$LCARS_SKEL_FILE"
  local avant; avant="$(cat "$LCARS_SKEL_FILE")"

  mod apply

  # tout ce qui etait la y est encore, dans l ordre
  [ "$(head -3 "$LCARS_SKEL_FILE")" = "$avant" ] \
    || { echo "le squelette preexistant a ete modifie :"; diff <(printf '%s\n' "$avant") <(head -3 "$LCARS_SKEL_FILE") || true; return 1; }
  grep -q 'MARQUEUR_DISTRIBUTION=intact' "$LCARS_SKEL_FILE"
}

@test "SKEL : le raccord TESTE avant de sourcer — reste inerte si l install est retiree" {
  # ⚠ C EST CE QUI REND LE GESTE HONNETE. Le bloc survit a la desinstallation dans un fichier qui
  # n est pas a nous ; `/etc/lcars` part avec l install. Sans le test de presence, chaque nouveau
  # compte de la machine heriterait d un `.bashrc` qui source un fichier absent.
  stub_curl "peu importe"
  mkdir -p "$(dirname "$LCARS_SKEL_FILE")"; : > "$LCARS_SKEL_FILE"
  mod apply
  # ⚠ `if`, ET SURTOUT PAS `[ -r … ] && . …` : la liste `&&` rend 1 quand le fichier manque, et sous
  # `set -e` elle TUE le shell qui source. C est le MUR I3 de ce corpus. La premiere version de ce
  # raccord refaisait exactement cette faute, et c est le SECOND bloc de ce temoin qui l a attrapee
  # — pas une relecture.
  grep -qF "if [ -r $LCARS_BASHRC_FILE ]; then . $LCARS_BASHRC_FILE; fi" "$LCARS_SKEL_FILE" \
    || { echo "le raccord ne teste pas la presence avant de sourcer :"; cat "$LCARS_SKEL_FILE"; return 1; }

  # et on le PROUVE : le fichier retire, le squelette se joue sans erreur et sans rien definir
  rm -f "$LCARS_BASHRC_FILE"
  run bash -c "set -e; . '$LCARS_SKEL_FILE'; echo OK-INERTE"
  [ "$status" -eq 0 ] || { echo "le squelette casse une fois l install retiree : $output"; return 1; }
  [[ "$output" == *"OK-INERTE"* ]]
}

@test "SKEL : le rail ne pose plus AUCUN fichier complet sur le squelette" {
  # La forme interdite est le remplacement. `skel.bashrc` a disparu de l arbre ; ce temoin garde que
  # personne ne le ressuscite sous un autre nom.
  local corps; corps="$(grep -vE '^\s*#' "$MOD")"
  refute grep -qE 'write_atomic +"?\$SKEL_FILE' <<<"$corps"
  grep -q 'ensure_managed_block "$SKEL_FILE"' <<<"$corps"
  [ ! -e "$SRC_DIR/skel.bashrc" ] \
    || { echo "runtime/services/skel.bashrc est revenu — la copie de 117 lignes avec lui"; return 1; }
}

# ─── MIGRATION : l'ancien arbre embarque (`fleet/`) se dit et se retire ────────────────────────
# Le runtime s'appelait `fleet/` et l'arbre embarque vivait sous `$HELPERS_DIR/fleet/` ; il vit a
# plat. Un poste deja pose garde l'ancien arbre : une seconde copie que personne ne lit, sauf un
# vieux defaut qui y retomberait.
@test "MIGRATION : un ancien arbre embarque sous fleet/ est un DRIFT au check et se RETIRE a l'apply" {
  need_git_checkout
  stub_curl "peu importe"
  mkdir -p "$LCARS_HELPERS_DIR/fleet/services/lib"; echo x > "$LCARS_HELPERS_DIR/fleet/services/lib/human-protocol.sh"
  mod check
  [[ "$output" == *"ancien arbre embarqué présent"* ]]
  mod apply   # le rc porte aussi les telechargements (xterm) que ce decor ne sert pas : on lit la ligne
  [[ "$output" == *"ancien arbre embarqué retiré"* ]] || { echo "$output"; return 1; }
  [ ! -e "$LCARS_HELPERS_DIR/fleet" ]
  [ -d "$LCARS_HELPERS_DIR/services" ]
  mod check
  [[ "$output" != *"ancien arbre"* ]]
}

# ─── la copie appartient a HELPERS_OWNER, sans setgid ni ecriture groupe (relecture 2026-09-04) ──
# `tar -xf` en root restaure proprietaire et mode de la SOURCE (le clone de l'humain, 2775) ; root
# executerait ensuite un arbre que l'humain peut modifier. Le decor n'est pas root : on mesure les
# MODES, que le module pose quel que soit l'appelant.
@test "EMBEDDED : aucun fichier ni repertoire pose n'est setgid ni inscriptible par le groupe/autres" {
  need_git_checkout
  stub_curl "peu importe"
  mkdir -p "$LCARS_HELPERS_DIR"
  local sgid="$BATS_TEST_TMPDIR/src-sgid"; mkdir -p "$sgid"
  mod apply
  [ -d "$LCARS_HELPERS_DIR/services" ]
  [ "$(find "$LCARS_HELPERS_DIR/services" "$LCARS_HELPERS_DIR/deploy" -perm /2022 2>/dev/null | wc -l)" -eq 0 ]
}

# ─── LOT 15 : LES MODES DE CE QUE 62 POSE SE RELISENT ───────────────────────────────────────────
#
# L'apply affirme un mode et un proprietaire sur tout ce qu'il pose (`install -m 0755 -o -g`,
# `write_atomic 0644`, `chown -R` + `chmod -R g-s,go-w` sur les arbres) ; le check ne relisait que
# `-x` et `-d`. Au build de l'image, verify est la seule mesure — et un COPY garde les modes du
# contexte (2775/664 sous umask 002). Ces temoins jouent le doctor pour de vrai, dans le decor ;
# `apply` y rend 1 (le client de terminal du stub ne passe pas son pin), ce qui n'est pas le sujet.

@test "MODES : un auxiliaire executable mais g+w est un DRIFT NOMME au check, et l'apply le ramene a 0755 sans le re-poser" {
  stub_curl "peu importe"
  mod apply
  local me; me="$(id -un):$(id -gn)"
  chmod 0775 "$LCARS_HELPERS_DIR/console.sh"
  mod check
  [[ "$output" == *"$LCARS_HELPERS_DIR/console.sh : 775 $me ≠ 755 $me"* ]] || { echo "$output"; return 1; }
  refute grep -q 'console.sh présent mais PAS exécutable' <<<"$output"
  local before; before="$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")"
  mod apply
  [ "$(stat -c '%a' "$LCARS_HELPERS_DIR/console.sh")" = "755" ]
  [ "$(stat -c %Y "$LCARS_HELPERS_DIR/console.sh")" = "$before" ]   # converge par ensure_mode, pas par install
  mod check
  refute grep -qF "$LCARS_HELPERS_DIR/console.sh : " <<<"$output"
  [[ "$output" == *"modes et propriétaires relus"* ]]
}

@test "MODES : une donnee (console.tmux.conf) en 0664 est un DRIFT NOMME, et l'apply la ramene" {
  stub_curl "peu importe"
  mod apply
  local me; me="$(id -un):$(id -gn)"
  chmod 0664 "$LCARS_HELPERS_DIR/console.tmux.conf"
  mod check
  [[ "$output" == *"$LCARS_HELPERS_DIR/console.tmux.conf : 664 $me ≠ 644 $me"* ]] || { echo "$output"; return 1; }
  mod apply
  [ "$(stat -c '%a' "$LCARS_HELPERS_DIR/console.tmux.conf")" = "644" ]
}

@test "MODES : un arbre embarque portant un objet g+w, setgid ou d'un autre proprietaire est un DRIFT NOMME (compte, premier coupable), et l'apply repose l'arbre" {
  need_git_checkout
  stub_curl "peu importe"
  mkdir -p "$LCARS_HELPERS_DIR"
  mod apply
  [ -d "$LCARS_HELPERS_DIR/services" ]
  chmod g+w "$LCARS_HELPERS_DIR/services/console.sh"
  mod check
  [[ "$output" == *"$LCARS_HELPERS_DIR/services : 1 objet(s) hors contrat (premier : $LCARS_HELPERS_DIR/services/console.sh, "* ]] \
    || { echo "$output"; return 1; }
  mod apply
  mod check
  refute grep -qF "$LCARS_HELPERS_DIR/services : " <<<"$output"
  # le compte est un compte, et un setgid sur un repertoire compte aussi
  chmod g+s "$LCARS_HELPERS_DIR/services/human.d"; chmod o+w "$LCARS_HELPERS_DIR/services/console.sh"
  mod check
  [[ "$output" == *"$LCARS_HELPERS_DIR/services : 2 objet(s) hors contrat"* ]] || { echo "$output"; return 1; }
  # et ce que la copie n'emporte pas n'est pas juge : un `.terraform` de lien, un `node_modules` g+w
  mkdir -p "$LCARS_HELPERS_DIR/deploy/.terraform" "$LCARS_HELPERS_DIR/assets/node_modules"
  ln -s /nulle/part "$LCARS_HELPERS_DIR/deploy/.terraform/lien"; chmod 0777 "$LCARS_HELPERS_DIR/assets/node_modules"
  mod check
  refute grep -qF "$LCARS_HELPERS_DIR/deploy : " <<<"$output"
  refute grep -qF "$LCARS_HELPERS_DIR/assets : " <<<"$output"
}

# ─── LE CANAL : SOUS `deb`, CE MODULE NE POSE RIEN — dpkg possede ses arbres (lot 2, 2026-09-05) ──
#
# Le decor possede le canal (`LCARS_CHANNEL_FILE`, pose dans setup) et `dpkg` (une doublure du PATH
# qui dit ce qu'on lui dit). `curl` est une doublure a MARQUEUR : sous `deb`, `fetch_verify` ne doit
# jamais etre atteint.

canal_deb() { mkdir -p "$(dirname "$LCARS_CHANNEL_FILE")"; printf 'deb\n' > "$LCARS_CHANNEL_FILE"; }
dpkg_double() { # dpkg_double <lignes de dpkg -V…> — le paquet est installe, et -V rend ces lignes
  local d="$BATS_TEST_TMPDIR/dpkgbin"; mkdir -p "$d"
  { echo '#!/usr/bin/env bash'
    echo 'case "$1" in -s) echo "Status: install ok installed"; exit 0 ;; -V) : ;; *) exit 2 ;; esac'
    local l; for l in "$@"; do printf "printf '%%s\\\\n' '%s'\n" "$l"; done
    echo 'exit 0'
  } > "$d/dpkg"; chmod 0755 "$d/dpkg"
  export PATH="$d:$PATH"
}
curl_marqueur() { printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$BATS_TEST_TMPDIR/CURL-APPELE" > "$BINDIR/curl"; chmod 0755 "$BINDIR/curl"; }

@test "CANAL deb : apply ne pose RIEN — ni auxiliaire, ni binaire du PATH, ni arbre — il MESURE, et dit ce que dpkg dit" {
  canal_deb; dpkg_double; curl_marqueur
  mod apply
  [ "$status" -eq 1 ]                                   # le verdict de CHECK (drift), pas celui d'apply
  [ ! -e "$LCARS_HELPERS_DIR/console.sh" ]
  [ ! -e "$LCARS_TOOLCHAIN_CONVERGE_BIN" ]
  [ ! -e "$LCARS_AUTHORITY_ASK_BIN" ]
  [ ! -d "$LCARS_HELPERS_DIR/services" ] && [ ! -d "$LCARS_HELPERS_DIR/deploy" ]
  [ ! -e "$LCARS_SKEL_FILE" ]
  [ ! -e "$BATS_TEST_TMPDIR/CURL-APPELE" ] || { echo "fetch_verify a ete ATTEINT sous deb"; return 1; }
  [[ "$output" == *"console.sh absent"* ]]
  [[ "$output" == *"dpkg -V lcars : rien à redire parmi ce que ce module relit sous $LCARS_HELPERS_DIR"* ]]
  refute_out 'POSÉ' <<<"$output"
  [ "$(cat "$LCARS_CHANNEL_FILE")" = "deb" ]
}

@test "CANAL deb : dpkg -V parle sur SES racines — « réinstalle le paquet » — et la release (territoire de 60) n'est pas comptee ici" {
  canal_deb
  dpkg_double "missing   $LCARS_HELPERS_DIR/services/console.sh" \
              "??5??????   $LCARS_TOOLCHAIN_CONVERGE_BIN" \
              "missing   $LCARS_HELPERS_DIR/runtime/bin/lcars" \
              "??5?????? c $LCARS_HELPERS_DIR/deck-static/xterm.js"
  mod check
  [ "$status" -ne 0 ]
  [[ "$output" == *"DRIFT"*"dpkg -V lcars : 3 fichier(s) altéré(s) ou manquant(s) parmi ce que ce module relit"*"(premier : $LCARS_HELPERS_DIR/services/console.sh)"* ]]
  [[ "$output" == *"apt install --reinstall lcars"* ]]
  refute_out 'runtime/bin/lcars' <<<"$output"
  # sous source (canal absent), dpkg n'est pas consulte
  rm -f "$LCARS_CHANNEL_FILE"
  mod check
  refute_out 'dpkg' <<<"$output"
}

@test "CANAL : les racines que 62 donne a dpkg sont DERIVEES des tableaux de check_perms — pas une seconde liste" {
  local m="$BATS_TEST_TMPDIR/62.sh"
  sed '/^case "${1:?usage/,$d' "$MOD" > "$m"
  run bash -c "set -euo pipefail; . '$m' >/dev/null 2>&1; dpkg_roots"
  [ "$status" -eq 0 ]
  local n; while read -r n; do grep -qx "$LCARS_HELPERS_DIR/$n" <<<"$output"; done < <(helpers)   # chaque auxiliaire
  grep -qx "$LCARS_TOOLCHAIN_CONVERGE_BIN" <<<"$output"
  grep -qx "$LCARS_AUTHORITY_ASK_BIN" <<<"$output"
  grep -qx "$LCARS_BASHRC_FILE" <<<"$output"                                        # une DONNEE
  grep -qx "$LCARS_HELPERS_DIR/services" <<<"$output"                               # EMBEDDED
  grep -qx "$LCARS_HELPERS_DIR/deploy" <<<"$output"                                 # EMBEDDED_ROOT
  grep -qx "$LCARS_HELPERS_DIR/deck-static" <<<"$output"
  refute_out '/runtime' <<<"$output"                                                # jamais la release
  # et la fonction lit les MEMES noms que check_perms — aucun chemin en dur
  local corps; corps="$(sed -n '/^dpkg_roots()/,/^}/p' "$MOD")"
  local v; for v in 'HELPERS\[@\]' 'DATA\[@\]' TOOLCHAIN_BIN AUTHORITY_ASK_BIN helpers_stamp copie_delivery_stamp deck_static_dir 'EMBEDDED\[@\]' 'EMBEDDED_ROOT\[@\]'; do
    grep -qE "$v" <<<"$corps" || { echo "dpkg_roots ne lit pas $v"; return 1; }
  done
  grep -vE '^\s*#' <<<"$corps" | refute_out '/opt/lcars|/usr/local'
}
