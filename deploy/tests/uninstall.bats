#!/usr/bin/env bats
# SOURCE: deploy/tests/uninstall.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-22
# STATUS: bats tests — `provision uninstall` : il lit deux tables et ne contient AUCUNE liste
#
# ─── CE QUE CE VERBE FERME ──────────────────────────────────────────────────────────────────────
#
# Le 2026-08-22, nettoyer une machine de test s'est fait A LA MAIN, avec une liste ecrite dans un
# `for p in …` improvise. Il a fallu s'y reprendre a deux fois, le groupe `fleet` est reste derriere,
# et un `.terraform` appartenant a root a bloque le `rm` du checkout de l'operateur.
#
# ⚠ ET C'EST LE MOMENT OU L'EMPREINTE SE MESURE VRAIMENT. Une install qui reussit ne prouve RIEN de
# ce qu'elle laisse : sur douze defauts trouves cette nuit-la, un seul est apparu en DESINSTALLANT —
# et il etait invisible autrement.
#
# ⚠ AUCUN TEMOIN ICI NE TOUCHE LA MACHINE. Le manifeste et le journal sont des DECORS, dans
# `BATS_TEST_TMPDIR`, et les chemins qu'ils declarent y vivent aussi. Un temoin de desinstalleur qui
# lirait le vrai manifeste retirerait le vrai systeme.

# ⚠ SC2016 AU NIVEAU DU FICHIER : ce temoin LIT DU CODE. Ses motifs `grep`/`sed` portent des
# `$o`, `$CMD`, `$EUID` qui doivent atteindre l'outil TELS QUELS — les developper ici chercherait
# la valeur de CE shell au lieu du texte du script audite. Les quotes simples sont l'instrument.
# shellcheck disable=SC2016
load refute

setup() {
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_)' || true)

  RUNNER="$BATS_TEST_DIRNAME/../provision"
  [ -f "$RUNNER" ]

  FAKE="$BATS_TEST_TMPDIR/fake"
  mkdir -p "$FAKE"/{opt/lcars/tofu/providers,etc/lcars,usr/local/bin,work,work2}
  : > "$FAKE/etc/lcars/host-consent"
  : > "$FAKE/usr/local/bin/tofu"
  ln -sf "$FAKE/opt/lcars/x" "$FAKE/usr/local/bin/lcars"
  : > "$FAKE/work/precieux.txt"

  export LCARS_SYSTEM_MANIFEST="$BATS_TEST_TMPDIR/system.manifest"
  cat > "$LCARS_SYSTEM_MANIFEST" <<EOF
# SOURCE: decor
# STATUS: data, not code
dir       $FAKE/opt/lcars                    0755  root:root  any
dir       $FAKE/opt/lcars/tofu/providers     0755  root:root  any
dir       $FAKE/etc/lcars                    0755  root:root  any
anchor    $FAKE/etc/lcars/host-consent       0644  root:root  any
anchor    $FAKE/usr/local/bin/tofu           0755  root:root  any
link      $FAKE/usr/local/bin/lcars          -     -          any
group     decor-groupe-absent                2000  -          any
human     /home/<human>/.lcars-decor         0700  <human>:-  any
preserve  $FAKE/work                         2775  root:fleet any
EOF

  export LCARS_JOURNAL_FILE="$BATS_TEST_TMPDIR/install.journal"
  # La carte du convergeur : `<forge_id>\t<uid>\t<login>`. `forge_id = 1` EST le siege.
  export PROV_UID_MAP_FILE="$BATS_TEST_TMPDIR/forge-uid.map"
}
carte() { printf '%s\n' "$@" > "$PROV_UID_MAP_FILE"; }

journal() { printf 'apt_installed %s\n' "$*" > "$LCARS_JOURNAL_FILE"; }
plan()    { run bash "$RUNNER" uninstall; }
code()    { grep -vhE '^\s*#' "$RUNNER" "$BATS_TEST_DIRNAME/../lib/provision-uninstall.sh"; }

@test "AUCUNE LISTE dans le code — il lit les tables, il ne les recopie pas" {
  # La regle de `etc/release.manifest`, etendue a la machine. Une liste en dur ici serait un SECOND
  # inventaire, et celui qui derive est toujours celui qu'on ne relit pas.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  [ -n "$body" ]
  # `/home/private` a quitte cette liste avec la racine : les jetons vivent sous `/opt/lcars`, deja
  # couvert par la premiere alternative. Une alternative qui ne peut plus rien matcher ne garde rien.
  refute grep -qE '/opt/lcars|/usr/share/lcars|/etc/lcars|/var/lib/lcars' <<<"$body"
  grep -q 'MANIFEST_FILE' <<<"$body"
  grep -q 'JOURNAL_FILE' <<<"$body"
}

@test "SANS MANIFESTE : refus net, jamais un repli" {
  # « Un desinstalleur qui devine est plus dangereux qu'un qui s'arrete. » Meme contrat que le temoin
  # de `release.manifest` : manifest absent = erreur, PAS un pass silencieux.
  LCARS_SYSTEM_MANIFEST="/nonexistent/system.manifest" plan
  [ "$status" -ne 0 ]
  [[ "$output" == *"manifeste introuvable"* ]]
}

@test "le PLAN s'imprime, et RIEN n'est retire sans --yes" {
  plan
  [ "$status" -eq 0 ]
  [[ "$output" == *"RIEN N'A ÉTÉ RETIRÉ"* ]]
  # les objets du decor sont tous encore la
  [ -f "$FAKE/etc/lcars/host-consent" ]
  [ -d "$FAKE/opt/lcars" ]
}

# ⚠ TROIS ETATS DU JOURNAL, ET UN SEUL MESSAGE LES DISAIT. Le code testait la longueur du tableau
# de paquets puis concluait sur le FICHIER. MESURE DU 2026-08-26 : un journal present, lisible,
# seize lignes, disant « ce rail n'a pose aucun paquet » etait annonce « absent ou vide ».
# L'operateur cherche un fichier manquant, le trouve, et reste bloque.
# Le troisieme etat est le SEUL ou l'uninstall a le droit d'etre serein : il SAIT qu'il n'y a rien
# a retirer. Le dire comme une ignorance transforme une certitude en alarme.

@test "JOURNAL ABSENT : aucun paquet, et l'IGNORANCE est dite" {
  rm -f "$LCARS_JOURNAL_FILE"
  plan
  [[ "$output" == *"AUCUN"* ]]
  [[ "$output" == *"illisible ou absent"* ]]
  [[ "$output" == *"impossible de distinguer"* ]]
}

@test "JOURNAL PRESENT SANS apt_installed : la CERTITUDE est dite, pas l'ignorance" {
  # Le rail a tourne et n'a pose aucun paquet — tout etait deja la. C'est un FAIT, pas un trou.
  printf 'apt_already tmux git\n' > "$LCARS_JOURNAL_FILE"
  plan
  [[ "$output" == *"le journal est là"* ]]
  [[ "$output" == *"Rien à retirer"* ]]
  refute_out 'impossible de distinguer' <<<"$output"
}

@test "AVEC journal : seuls les paquets QUE LCARS A POSES sont nommes" {
  journal socat jq
  plan
  [[ "$output" == *"socat"* ]]
  [[ "$output" == *"jq"* ]]
}

@test "apt_already n'est JAMAIS repris — c'est le fond du journal" {
  printf 'apt_installed socat\napt_already git curl\n' > "$LCARS_JOURNAL_FILE"
  plan
  [[ "$output" == *"socat"* ]]
  [[ "$output" != *"git"* ]]
  [[ "$output" != *"curl"* ]]
}

@test "preserve : nomme dans le plan, et JAMAIS dans ce qui part" {
  plan
  [[ "$output" == *"$FAKE/work"* ]]
  # il n'est compte ni dans les fichiers ni dans les dirs : 3 dirs de decor, pas 4
  [[ "$output" == *"3 répertoire(s)"* ]]
}

@test "les objets du HOME sont laisses TOUJOURS, et le plan ne promet plus l'inverse" {
  # ⚠ CE TEMOIN EXIGEAIT « LAISSÉS … --humans » — c'est-a-dire un DEFAUT plus un drapeau qui le
  # leve. Il n'y a plus de drapeau qui le leve : `/home` est hors du perimetre entier. Le mot que
  # ce temoin cherche a donc change, et c'est le geste A1 qui l'a change.
  plan
  [[ "$output" == *"JAMAIS retirés"* ]]
  [[ "$output" == *"par aucun drapeau"* ]]
}

@test "l'ORDRE est l'inverse de la pose : le plus profond d'abord" {
  # Un `groupdel` avant les fichiers que le groupe possede echoue ; un `rm` de repertoire avant son
  # contenu, non. L'ordre n'est donc pas une elegance.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  grep -q 'sort -rn' <<<"$body"
  local n_files n_dirs n_groups
  # ⚠ LE MOTIF NE COLLE PLUS AU DEBUT DE LA BOUCLE, ET C'EST VOULU. Elle itere desormais DEUX
  # sources — le depot apt du journal, puis les fichiers de la table — donc `for o in "${files[@]}"`
  # n'est plus en tete de ligne. On accroche `${files[@]}` la ou il est : ce qui est mesure ici est
  # l'ORDRE des trois boucles, pas la forme de l'une d'elles.
  n_files="$(grep -n 'for o in .*\${files\[@\]}' <<<"$body" | cut -d: -f1)"
  n_dirs="$(grep -n 'for o in "\${dirs\[@\]}"' <<<"$body" | cut -d: -f1)"
  n_groups="$(grep -n 'for o in "\${groups\[@\]}"' <<<"$body" | cut -d: -f1)"
  [ "$n_files" -lt "$n_dirs" ]
  [ "$n_dirs" -lt "$n_groups" ]
}

# ⚠ CE TEMOIN CONSACRAIT LE DEFAUT QU'IL GARDAIT, ET IL A FALLU UNE MACHINE POUR LE VOIR.
#
# Il greppait le TEXTE de `uninstall_run` pour une phrase et un compteur — donc il etait vert quoi
# que fasse `groupdel`. Sa prose citait une mesure a l'appui : « `groupdel fleet` a echoue au
# nettoyage de .63, et c'etait la BONNE reponse ». MESURE SUR BANC VIERGE le 2026-08-27, install
# complete puis `uninstall --yes` : `groupdel fleet` REUSSIT, et `/home/projects`,
# `/home/projects.ops`, `/home/projects.workshop` restent en `root:1001` — un GID orphelin que le
# prochain `groupadd` reattribuera. Le mode d'echec que la regle pretendait prevenir S'EST PRODUIT.
#
# `groupdel` ne refuse qu'un groupe PRIMAIRE d'un compte existant. Il ne regarde jamais qui possede
# des fichiers. La regle etait juste ; c'est son execution qui etait deleguee au mauvais outil.
#
# Le remplacant EXERCE la propriete au lieu de la citer : un repertoire preserve porte un groupe
# reel (celui du testeur, seul groupe qu'un test non privilegie puisse poser), et la primitive doit
# le trouver. Le controle de structure ne verifie plus une PHRASE mais un ORDRE : la consultation
# passe avant `groupdel`.

@test "REGLE 5 : la primitive TROUVE le porteur preserve — mesure, pas citation" {
  # shellcheck source=../lib/provision-lib.sh
  PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  # `provision-lib` exige d'etre lue par un module ; on ne veut que la primitive.
  eval "$(sed -n '/^prov_group_owns_preserved()/,/^}$/p' "$PROVISION_LIB")"

  local g; g="$(id -gn)"
  run prov_group_owns_preserved "$g" "$FAKE/work"
  [ "$status" -eq 0 ]
  [[ "$output" == "$FAKE/work"* ]]
}

@test "REGLE 5 : un groupe que RIEN de preserve ne porte n'est pas retenu" {
  PROVISION_LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  eval "$(sed -n '/^prov_group_owns_preserved()/,/^}$/p' "$PROVISION_LIB")"

  run prov_group_owns_preserved "decor-groupe-absent" "$FAKE/work"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "REGLE 5 : la consultation passe AVANT groupdel, jamais apres" {
  # L'ordre EST la propriete : consulter apres avoir retire ne repare rien.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local n_check n_del
  n_check="$(grep -n 'prov_group_owns_preserved' <<<"$body" | head -1 | cut -d: -f1)"
  n_del="$(grep -n 'groupdel "\$o"' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$n_check" ]
  [ -n "$n_del" ]
  [ "$n_check" -lt "$n_del" ]
}

# ─── LES QUATRE DEFAUTS MESURES SUR BANC VIERGE LE 2026-08-27 ───────────────────────────────────
# `uninstall --yes` sur une install complete a laisse 30 450 objets sur 35 136. Ces temoins
# epinglent les quatre causes que le plan pouvait deja montrer sans root.

@test "JOKER <version> : le plan nomme le chemin REEL, jamais le motif" {
  # MESURE : `/opt/elixir-1.18.4` et `/opt/node-20.20.2` survivent a `uninstall --yes` — 6 148
  # fichiers. `provision` ne substituait que `<human>` ; `dir /opt/…-<version>` arrivait LITTERAL,
  # `[[ -d ]]` rendait faux, et l'arbre restait pendant que ses symlinks partaient.
  # ⚠ LE JOKER N'A PLUS QU'UN CLIENT, ET LE TEMOIN N'EN DEPEND PAS. Elixir vient de l'apt de la
  # distro depuis que la cible sert 1.18.3 : `/opt/elixir-<version>` a quitte la table, `node` y
  # reste seul. Ce temoin monte son propre `truc-<version>` — il mesure la SUBSTITUTION, pas
  # l'inventaire, et il tiendra encore le jour ou le dernier joker de la table disparaitra.
  mkdir -p "$FAKE/opt/truc-9.9.9"
  printf 'dir       %s/opt/truc-<version>  0755 root:root any\n' "$FAKE" >> "$LCARS_SYSTEM_MANIFEST"
  plan
  [[ "$output" == *"truc-9.9.9"* ]] || {
    echo "le plan ne nomme pas le chemin resolu :" >&2; echo "$output" >&2; return 1
  }
  refute_out '<version>' <<<"$output"
}

@test "JOKER <version> : un motif que RIEN ne porte n'entre pas au plan" {
  # Resoudre ne doit pas INVENTER : sans arbre sur le disque, il n'y a rien a retirer.
  # ⚠ ON COMPTE, on ne cherche pas un nom : le plan n'imprime que des compteurs, et un `refute_out`
  # sur un nom absent est vert a vide. Meme piege que le temoin du substrat, deux tests plus bas.
  ndir() { sed -n 's/^  dirs *\([0-9]*\) répertoire.*/\1/p' <<<"$output"; }
  local avant apres
  plan; avant="$(ndir)"
  printf 'dir       %s/opt/absent-<version>  0755 root:root any\n' "$FAKE" >> "$LCARS_SYSTEM_MANIFEST"
  plan; apres="$(ndir)"
  [ "$apres" -eq "$avant" ]
  refute_out 'résolus' <<<"$output"
}

@test "SUBSTRAT : un objet declare pour un AUTRE substrat n'entre pas au plan" {
  # La colonne etait lue et jamais consultee. Sans effet tant que tout finissait en `rm -f` sur un
  # chemin absent — mais les classes a venir AGISSENT, et agir sur le mauvais substrat detruit sur
  # la mauvaise machine.
  # ⚠ ET CE TEMOIN COMPTE, IL NE CHERCHE PAS UN NOM. Premiere version : `refute_out` sur le nom de
  # l'objet — vert a vide, parce que le plan n'imprime que des COMPTEURS. Mutation jouee : neutraliser
  # le filtre ne le faisait pas rougir. Ce qui discrimine est le nombre.
  # ⚠ ET LE SUBSTRAT SE FORCE PAR `--substrate`, PAS PAR L'ENVIRONNEMENT. `PROV_SUBSTRATE` est
  # EXPORTE par le runner (`:163`), il n'est jamais LU : le poser n'a aucun effet. Premiere version
  # de ce temoin faite comme ca — elle mesurait le substrat detecte de la machine qui joue la suite.
  nfic() { sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output"; }
  local n_avant n_wsl n_linux
  run bash "$RUNNER" uninstall --substrate wsl; n_avant="$(nfic)"

  : > "$FAKE/etc/lcars/objet-linux-seulement"
  printf 'anchor    %s/etc/lcars/objet-linux-seulement  0644 root:root linux\n' "$FAKE" >> "$LCARS_SYSTEM_MANIFEST"

  run bash "$RUNNER" uninstall --substrate wsl;    n_wsl="$(nfic)"
  run bash "$RUNNER" uninstall --substrate linux;  n_linux="$(nfic)"

  [ "$n_wsl" -eq "$n_avant" ]                # `linux` ne concerne pas un poste wsl
  [ "$n_linux" -eq "$((n_avant + 1))" ]      # et il le concerne sur le substrat qui le declare
}

@test "ORDRE : les paquets partent AVANT les repertoires — le journal vit dans l'un d'eux" {
  # LA PROPRIETE EST L'ORDRE. `/etc/lcars` porte le journal et part au `rm -rf` des `dirs`.
  # Interrompu entre les deux, la regle 3 (« sans journal, aucun paquet ») gele les paquets POUR
  # TOUJOURS : le fichier qui disait lesquels retirer n'existe plus.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local n_apt n_dirs
  n_apt="$(grep -n 'apt-get remove' <<<"$body" | head -1 | cut -d: -f1)"
  n_dirs="$(grep -n 'for o in "\${dirs\[@\]}"' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$n_apt" ]
  [ -n "$n_dirs" ]
  [ "$n_apt" -lt "$n_dirs" ]
}

@test "HUMAINS : la boucle sur \`/home/*\` N'EXISTE PLUS — pas « mieux gardee », absente" {
  # ⚠ CE TEMOIN GARDAIT UN GESTE, IL INTERDIT MAINTENANT SON RETOUR. Il exigeait que la boucle
  # `for h in /home/*` filtre par `preserved` avant son `rm -rf`. C'etait un filet sur un geste qui
  # n'aurait pas du exister : `preserved` ne connait que les racines qu'on a pense a ecrire, et un
  # home ordinaire n'en est pas une. Le geste est parti ; ce qui reste a tenir est son ABSENCE.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  refute grep -q 'for h in /home/\*' <<<"$body"
}

@test "GARDE /home : aucune ligne de la table, quelle que soit sa classe, n'entre dans ce qui part" {
  # La garde est DANS LE CODE et pas dans la table, parce qu'une garde qui vit dans la table depend
  # de la vigilance de celui qui l'edite. Ici : une ligne `dir` sous /home — la faute la plus
  # naturelle, un objet operator-facing qui semble y avoir sa place — et elle est ECARTEE, pas
  # retiree, pas silencieuse.
  nrep() { sed -n 's/^  dirs *\([0-9]*\) répertoire.*/\1/p' <<<"$output"; }
  local n_avant n_apres
  plan; n_avant="$(nrep)"

  mkdir -p "$FAKE/faux-home/quelquechose"
  printf 'dir       /home/quelquechose-de-nouveau  0755 root:root any\n' >> "$LCARS_SYSTEM_MANIFEST"

  plan; n_apres="$(nrep)"
  [ "$n_apres" -eq "$n_avant" ]                     # rien de plus a detruire
  [[ "$output" == *"visent /home et sont IGNORÉES"* ]]   # et le plan le DIT
  [[ "$output" == *"/home/quelquechose-de-nouveau"* ]]
}

# ─── LA CLASSE `account`, ET LES DEUX COMPTES QUE LE BANC A VUS SURVIVRE ────────────────────────
# MESURE DU 2026-08-28, install complete puis `uninstall --yes` : `lcars-authority` et `lcars-system`
# survivent avec leurs groupes propres. Aucune classe ne les nommait — donc le plan ne les voyait
# pas, et le desinstalleur laissait derriere lui un compte systeme qui detenait les secrets de forge.

@test "ACCOUNT : un compte de service declare entre au plan et se COMPTE" {
  printf 'account   compte-de-service-decor  -  /usr/sbin/nologin  any\n' >> "$LCARS_SYSTEM_MANIFEST"
  plan
  [[ "$output" == *"compte(s) de service"* ]]
  [ "$(sed -n 's/^  comptes *\([0-9]*\) compte.*/\1/p' <<<"$output")" -eq 1 ]
}

@test "ACCOUNT : les comptes partent AVANT les groupes — \`groupdel\` l'exige" {
  # `groupdel` refuse un groupe qui est le PRIMAIRE d'un compte existant. Retirer le groupe d'abord
  # le laisserait en place, et le compte avec.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local n_acc n_grp
  n_acc="$(grep -n 'userdel' <<<"$body" | head -1 | cut -d: -f1)"
  n_grp="$(grep -n 'groupdel' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$n_acc" ] && [ -n "$n_grp" ] && [ "$n_acc" -lt "$n_grp" ]
}

@test "ACCOUNT n'est PAS person : aucun \`userdel\` ne touche un compte d'humain" {
  # ⚠ LA PROPRIETE LA PLUS CHERE DE CE VERBE. Un compte de service se retire toujours, un compte
  # d'humain jamais sans qu'on le demande. Les fondre ferait un desinstalleur qui supprime des gens.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local bloc; bloc="$(sed -n '/for o in "\${accounts\[@\]}"/,/done/p' <<<"$body")"
  [ -n "$bloc" ]
  refute_out 'humans\[' <<<"$bloc"
  refute_out 'person'    <<<"$bloc"
}

# ─── LA CLASSE `docker`, ET LE VOLUME QU'ELLE NE DOIT PAS PRENDRE ───────────────────────────────
#
# MESURE DU 2026-08-27 : apres `uninstall --yes`, TROIS conteneurs et QUATRE volumes survivent, dont
# `<projet>_data` qui porte les depots de la forge. Le verbe ne touchait aucun objet docker.
#
# ⚠ LE NOM DU PROJET NE PEUT PAS ETRE DANS LA TABLE. Il se derive de `PROV_FORGE_PROJECT`,
# surchargeable par `--forge-project` — mesure du 2026-08-28, le banc tournait sur `lcars-alice`.
# `uninstall.bats` interdit deja de recopier un nom ici. Le JOURNAL est le seul endroit qui sache ce
# que CETTE machine a monte, et c'est exactement ce qu'il existe pour dire.

@test "DOCKER : le plan lit les projets dans le JOURNAL, jamais dans la table" {
  printf 'posed_docker lcars-essai lcars-essai-runner\n' >> "$LCARS_JOURNAL_FILE"
  plan
  [[ "$output" == *"lcars-essai"* ]]
  [[ "$output" == *"lcars-essai-runner"* ]]
}

# ─── L'INVENTAIRE DU JOURNAL, ET IL N'AVAIT AUCUN LECTEUR ───────────────────────────────────────
#
# ⚠ LES PRIMITIVES JOURNALISENT DEPUIS `2c8f56b04` — `write_atomic` -> `posed_file`, `ensure_dir` ->
# `posed_dir`, `ensure_symlink` -> `posed_link`, 53 sites dans 18 modules. L'uninstall ne consommait
# QUE `apt_installed`, `posed_docker` et `posed_apt_repo` : l'inventaire le plus large du fichier
# etait ecrit a chaque passe et lu par personne.
#
# CE QU'IL RATTRAPE : la table a des angles morts PROUVES — un nom compose a l'execution, un
# repertoire exempte, un objet pose sous condition. Le journal est ecrit par le geste QUI POSE : il
# ne peut pas avoir d'angle mort de declaration. C'est le filet sous la table.

# ⚠ ON COMPTE, ON NE CHERCHE PAS LE NOM DANS LA SORTIE — ET LA PREMIERE VERSION DE CES DEUX TEMOINS
# CHERCHAIT LE NOM. Le plan porte une ligne « hors table » qui NOMME ces objets : elle reste imprimee
# meme si rien ne les fait entrer dans le plan executable. Mutation jouee le 2026-08-29 :
# `files+=(…)` et `dirs+=(…)` remplaces par `:` — les deux temoins restaient VERTS, l'annonce
# survivant a la disparition du geste. Nommer au plan n'est pas retirer, et c'est la DEUXIEME fois
# que ce piege se referme dans ce fichier (cf. le depot apt, plus bas).
@test "JOURNAL : un fichier pose et ABSENT de la table entre au plan EXECUTABLE" {
  local avant apres
  plan; avant="$(sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output")"
  [ -n "$avant" ] || { echo "extraction ratee : le compteur de fichiers du plan"; return 1; }
  printf 'posed_file /etc/hors-table-essai.conf\n' >> "$LCARS_JOURNAL_FILE"
  plan; apres="$(sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output")"
  [ "$apres" -eq "$((avant + 1))" ] \
    || { echo "le compteur de fichiers n'a pas bouge ($avant -> $apres) : l'objet est annonce, pas planifie"; echo "$output"; return 1; }
  # et il est NOMME, parce qu'il ne vient pas de la table
  [[ "$output" == *"hors-table-essai.conf"* ]]
}

@test "JOURNAL : un repertoire pose et ABSENT de la table entre au plan EXECUTABLE" {
  local avant apres
  plan; avant="$(sed -n 's/^  dirs *\([0-9]*\) répertoire.*/\1/p' <<<"$output")"
  [ -n "$avant" ] || { echo "extraction ratee : le compteur de repertoires du plan"; return 1; }
  printf 'posed_dir /etc/hors-table-dir-essai\n' >> "$LCARS_JOURNAL_FILE"
  plan; apres="$(sed -n 's/^  dirs *\([0-9]*\) répertoire.*/\1/p' <<<"$output")"
  [ "$apres" -eq "$((avant + 1))" ] \
    || { echo "le compteur de repertoires n'a pas bouge ($avant -> $apres)"; echo "$output"; return 1; }
  [[ "$output" == *"hors-table-dir-essai"* ]]
}

# ⚠ AUCUN ACCENT GRAVE DANS CE TITRE, ET CE N'EST PAS DU STYLE. bats EXECUTE la description d'un
# `@test` : la premiere version portait « `preserve` PRIME », et bats a cherche une commande nommee
# `preserve` (« command not found » dans la sortie du run). Meme faute que `e45092fb2` a balayee sur
# cinq descriptions, refaite ici quatre jours plus tard.
@test "JOURNAL : preserve PRIME sur le journal — meme si c'est nous qui l'avons pose" {
  # La seule classe de la table dont l'autorite est absolue. Un second inventaire ne doit pas
  # pouvoir la contourner par la porte de derriere.
  # ⚠ LE DECOR POSE SON PROPRE MANIFESTE, ET CE TEMOIN DOIT LUI PARLER. Premiere version : un chemin
  # sous `/home/projects`, preserve dans le VRAI `system.manifest` — donc pas dans celui du decor,
  # et le temoin mesurait une regle que la passe ne connaissait pas.
  printf 'preserve  %s/precieux  2775  root:fleet  any\n' "$FAKE" >> "$LCARS_SYSTEM_MANIFEST"
  printf 'posed_dir %s/precieux/essai-journal\n' "$FAKE" >> "$LCARS_JOURNAL_FILE"
  plan
  refute_out 'essai-journal' <<<"$output"
}

# ─── LA GARDE /home MANQUAIT DU COTE JOURNAL, ET LE JOURNAL ALIMENTE LE MEME PLAN ──────────────
#
# ⚠ MESURE DU 2026-09-01. La boucle de la TABLE portait la garde ; celle du JOURNAL n'avait que
# `preserved` pour filtre — et `preserved` ne connait que les racines qu'on a pense a ecrire. Or
# DEUX modules `NEEDS: root` posent sous /home par des primitives qui JOURNALISENT : `30-wsl`
# (`$home/.config`, plus un lien) et `45-sudoers-toolchain` (`$home/.claude/skills/system-issues`).
# Plan vierge = 0 fichier / 2 dirs ; les trois memes entrees au journal = 1 fichier / 4 dirs. Les
# chemins entraient dans le `rm -rf` pendant que le bilan imprimait « JAMAIS retires, par aucun
# drapeau » deux ecrans plus haut.
#
# ⚠ ON COMPTE, ON NE CHERCHE PAS LE NOM — meme piege que les deux temoins du dessus. Le plan NOMME
# ces objets sous « hors table » : chercher leur nom dans la sortie resterait vert alors meme
# qu'ils seraient planifies.
@test "JOURNAL : ce qui est pose sous /home est ECARTE du plan executable, et le plan le DIT" {
  local f_avant f_apres d_avant d_apres
  plan
  f_avant="$(sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output")"
  d_avant="$(sed -n 's/^  dirs *\([0-9]*\) répertoire.*/\1/p' <<<"$output")"
  [ -n "$f_avant" ] && [ -n "$d_avant" ] \
    || { echo "extraction ratee des compteurs du plan"; echo "$output"; return 1; }

  printf 'posed_dir /home/victime/.config\n'                      >> "$LCARS_JOURNAL_FILE"
  printf 'posed_dir /home/victime/.claude/skills/system-issues\n' >> "$LCARS_JOURNAL_FILE"
  printf 'posed_link /home/victime/.config/lcars-decor\n'         >> "$LCARS_JOURNAL_FILE"

  plan
  f_apres="$(sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output")"
  d_apres="$(sed -n 's/^  dirs *\([0-9]*\) répertoire.*/\1/p' <<<"$output")"
  [ "$f_apres" -eq "$f_avant" ] \
    || { echo "un objet /home du journal est entre dans les FICHIERS ($f_avant -> $f_apres)"; echo "$output"; return 1; }
  [ "$d_apres" -eq "$d_avant" ] \
    || { echo "un objet /home du journal est entre dans les DIRS ($d_avant -> $d_apres)"; echo "$output"; return 1; }

  # Ecarte SANS LE DIRE serait un demi-geste : ce sont exactement les objets que la desinstallation
  # laisse derriere elle et dont la table ne parle pas.
  [[ "$output" == *"du JOURNAL sous /home"* ]]
  [[ "$output" == *"/home/victime/.claude/skills/system-issues"* ]]
}

@test "JOURNAL : la garde /home est un predicat NOMME, partage par les trois boucles du plan" {
  # La forme, pas le comportement — et c'est le point : le defaut n'etait pas une garde fausse,
  # c'etait une garde presente a UN seul des trois endroits qui alimentent le meme plan. Un predicat
  # nomme se cherche ; son absence dans une quatrieme boucle se voit.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  grep -q 'sous_home() {' <<<"$body"
  [ "$(grep -c 'sous_home ' <<<"$body")" -ge 3 ] \
    || { echo "moins de trois sites appellent sous_home : une boucle du plan n'est pas gardee"; return 1; }
  # et la forme inline ne revient pas par la bande
  refute grep -qE '== /home/\*' <<<"$(sed '/sous_home() {/d' <<<"$body")"
}

@test "JOURNAL : un objet DEJA couvert par la table n'est pas planifie DEUX fois" {
  # `/opt/lcars/runtime` est le prefixe declare : ce qui vit dessous part avec lui. Le re-lister
  # ferait un compteur qui ment et un operateur qui relit deux fois la meme ligne.
  local avant apres
  plan; avant="$(sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output")"
  [ -n "$avant" ] || { echo "extraction ratee : le compteur de fichiers du plan"; return 1; }
  # `$FAKE/opt/lcars` est declare `dir` par le decor : ce qui vit dessous part avec lui.
  printf 'posed_file %s/opt/lcars/bin/quelque-chose\n' "$FAKE" >> "$LCARS_JOURNAL_FILE"
  plan; apres="$(sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output")"
  [ "$apres" -eq "$avant" ] \
    || { echo "un objet deja couvert par la table a ete replanifie ($avant -> $apres)"; return 1; }
}

@test "JOURNAL : ce qui vient du journal se NOMME dans le plan, il ne se compte pas" {
  # Meme regle que les chemins resolus depuis un joker : l'operateur ne peut pas les retrouver en
  # relisant la table, donc le plan les ecrit en toutes lettres avant qu'on l'execute.
  printf 'posed_file /etc/hors-table-essai.conf\n' >> "$LCARS_JOURNAL_FILE"
  plan
  [[ "$output" == *"hors table"* ]] \
    || { echo "le plan ne dit pas d'ou vient cet objet :"; echo "$output"; return 1; }
}

# ─── LE DEPOT APT POSE SOUS CONDITION, ET POURQUOI LUI AUSSI VIT DANS LE JOURNAL ────────────────
#
# ⚠ CES DEUX OBJETS AVAIENT PERDU TOUT CONTRAT DE SORTIE, ET L'ETAT ETAIT PIRE QUE L'ORIGINAL.
# `10-packages` pose `/etc/apt/sources.list.d/docker.list` et sa cle SI le substrat est `linux` et
# qu'aucun daemon docker ne repond. Ils ont ete DECLARES dans `system.manifest`, puis retires — parce
# qu'une ligne statique aurait autorise un `uninstall` a detruire le depot d'un operateur qui l'avait
# deja. Correct pour la question posee ; sauf que l'absence de declaration les a rendus
# indestructibles la ou LCARS les avait bel et bien poses.
#
# LE JOURNAL EST LA SEULE SOURCE QUI CONNAISSE LA CONDITION. Il ne dit pas ce qu'on a le DROIT de
# poser — c'est le metier de la table — mais ce que CETTE passe A pose sur CETTE machine.

@test "DEPOT APT : le plan lit la paire dans le JOURNAL, jamais dans la table" {
  printf 'posed_apt_repo /etc/apt/sources.list.d/essai.list /etc/apt/keyrings/essai.asc
' >> "$LCARS_JOURNAL_FILE"
  plan
  [[ "$output" == *"essai.list"* ]]
  [[ "$output" == *"essai.asc"* ]]
}

@test "DEPOT APT : sans journal, RIEN n'est planifie — le depot d'un tiers n'est pas a nous" {
  # ⚠ C'EST LA MOITIE QUI COMPTE. Un operateur qui avait deja le depot docker n'a aucune ligne
  # `posed_apt_repo` dans son journal : le plan ne doit rien nommer, et surtout rien retirer.
  # On COMPTE, on ne cherche pas un nom : `refute_out` sur un nom absent est vert a vide.
  local avant apres
  plan; avant="$(grep -c 'essai' <<<"$output" || true)"
  [ "$avant" -eq 0 ] || { echo "un depot est planifie sans journal :"; echo "$output"; return 1; }
  printf 'posed_apt_repo /etc/apt/sources.list.d/essai.list\n' >> "$LCARS_JOURNAL_FILE"
  plan; apres="$(grep -c 'essai' <<<"$output" || true)"
  [ "$apres" -gt 0 ] || { echo "le journal revendique la paire et le plan l'ignore"; return 1; }
}

@test "DEPOT APT : aucun chemin de depot n'est ecrit dans le code" {
  # Meme regle que pour docker : recopier `/etc/apt/sources.list.d/docker.list` ici ferait un second
  # inventaire, et celui qui derive est toujours celui qu'on ne relit pas.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  refute grep -qE 'sources\.list\.d|apt/keyrings' <<<"$body"
  grep -q 'posed_apt_repo' <<<"$body"

  # ⚠ NOMMER AU PLAN N'EST PAS RETIRER, ET LA PREMIERE VERSION DE CES TEMOINS S'ARRETAIT LA.
  # Mutation jouee le 2026-08-29 : la boucle de retrait ramenee a `for o in "${files[@]}"` — le plan
  # continuait de nommer la paire, les trois temoins restaient VERTS, et plus rien ne la retirait.
  # Un plan qui annonce ce qu'il ne fait pas est pire qu'un plan muet : il atteste.
  # Le retrait lui-meme exige root et `--yes` ; ce qui se mesure ici est que la boucle ITERE bien
  # les deux sources.
  grep -qE 'for o in .*apt_repo_files\[@\].*\$\{files\[@\]\}' <<<"$body" \
    || { echo "la boucle de retrait n'itere plus le depot du journal — il serait annonce au plan et laisse sur la machine"; return 1; }
}

@test "DOCKER : aucun nom de projet n'est ecrit dans le code" {
  # La regression exacte : recopier `lcars-forge` ici ferait un second inventaire, et celui qui
  # derive est toujours celui qu'on ne relit pas.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  refute grep -qE 'lcars-forge|lcars-alice' <<<"$body"
  grep -q 'posed_docker' <<<"$body"
}

@test "DOCKER : les VOLUMES ne sont jamais retires — ils portent le travail" {
  # ⚠ LE TEMOIN LE PLUS CHER DE CE VERBE. `<projet>_data` porte les depots de la forge. Ils
  # survivent aujourd'hui par ACCIDENT — rien ne touchait docker ; les retirer maintenant
  # transformerait cet accident en destruction. La cible (`/home/forge` en bind, classe `preserve`)
  # est la phase B. D'ici la : on retire ce qui se reconstruit, on NOMME ce qu'on laisse.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local bloc; bloc="$(sed -n '/for proj in /,/^  done/p' <<<"$body")"
  [ -n "$bloc" ]
  grep -q 'docker rm -f'      <<<"$bloc"
  grep -q 'docker network rm' <<<"$bloc"
  # ⚠ HORS LIGNES D'AFFICHAGE : le message SUGGERE la commande a l'operateur (« docker volume rm
  # <vol> si tu en es sur »). Un refute qui lit la prose interdirait de nommer le geste qu'on epargne
  # — meme piege que le temoin anti-litteral de `box`, deux commits plus tot.
  refute grep -qE '^[^e]*docker (volume rm|volume prune)' <<<"$(grep -v 'echo ' <<<"$bloc")"
  # et il DIT ce qu'il epargne
  grep -q 'GARDÉ' <<<"$bloc"
}

# ─── LA CLASSE `person` — LA SEULE DU VERBE QUI PUISSE SUPPRIMER QUELQU'UN ──────────────────────
#
# MESURE DU 2026-08-27 : `/home/lcars` porte 32 objets apres `uninstall --yes`, et le compte `lcars`
# survit. Aucune classe ne le nommait.
#
# ⚠ SA SOURCE VIT DANS CE QUE LE VERBE DETRUIT. La carte du convergeur est sous `/home/private` —
# meme defaut d'ordre que le journal et les paquets : la seule source qui sache quels comptes LCARS
# a materialises est effacee par la passe qui en a besoin. Elle se lit EN TETE.

@test "PERSON : les comptes se lisent dans la carte, et le SIEGE en est ecarte" {
  # `forge_id = 1` est l'operateur qui a lance l'install. Ce n'est PAS un compte que LCARS a cree :
  # le retirer supprimerait la personne qui desinstalle.
  # ⚠ `capitaine`, ET PAS UN LOGIN REEL : le plan imprime le chemin du depot, donc un siege de decor
  # nomme comme l'operateur qui joue le test rougit sur son propre $HOME (banc du 2026-08-30).
  carte "1	1000	capitaine" "2	1001	lcars" "3	1002	zoe"
  plan
  [[ "$output" == *"lcars"* ]]
  [[ "$output" == *"zoe"* ]]
  refute_out 'capitaine' <<<"$output"
}

@test "PERSON : LAISSES par defaut, et le plan dit que le HOME reste dans les deux cas" {
  carte "1	1000	capitaine" "2	1001	lcars"
  plan
  [[ "$output" == *"LAISSÉS"* ]]
  # ⚠ IL EXIGEAIT « EUX ET LEUR HOME ». C'est la phrase qu'A1 rend fausse : `--humans` retire le
  # COMPTE, le home ne part dans aucun cas. Un plan qui annonce une destruction qu'il ne fera pas
  # est aussi trompeur qu'un plan qui en tait une.
  [[ "$output" == *"les homes restent dans tous les cas"* ]]
}

@test "PERSON : sans carte, aucun compte n'est planifie — on n'invente personne" {
  rm -f "$PROV_UID_MAP_FILE"
  plan
  refute_out 'comptes h\.' <<<"$output"
}

@test "PERSON : le retrait est sous \`--humans\`, et il passe par \`preserved\`" {
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local bloc; bloc="$(sed -n '/for per in /,/^    done/p' <<<"$body")"
  [ -n "$bloc" ]
  # ⚠ `userdel` NU, ET L'INTERDICTION DE `-r` EST LE POINT. Ce temoin EXIGEAIT `userdel -r` : il
  # verrouillait donc, avec le serieux d'un mur, le seul geste de ce bloc qui detruit un home. `-r`
  # est un `rm -rf` sous /home par un autre binaire, et la regle ne porte pas sur le nom de l'outil.
  grep -qE 'userdel "\$per"' <<<"$bloc"
  refute grep -q 'userdel -r' <<<"$bloc"
  grep -q 'preserved "$home"' <<<"$bloc"
  # ⚠ ET LE GARDE EST CELUI DE CE BLOC, PAS « un garde quelque part avant ». Premiere version :
  # `tail -1` sur toutes les occurrences de `UNINSTALL_HUMANS` puis comparaison de rangs — elle
  # trouvait le garde de la boucle VOISINE et restait verte quand celui-ci sautait. Mesure par
  # mutation. Ce qui est vrai : les lignes qui precedent IMMEDIATEMENT le bloc le gardent.
  local avant
  avant="$(grep -B6 'for per in ' <<<"$body")"
  grep -q 'UNINSTALL_HUMANS" -eq 1 \]\]; then' <<<"$avant"
}

# ─── LES UNITES S'ARRETENT AVANT DE PARTIR ──────────────────────────────────────────────────────
#
# MESURE DU 2026-08-28, banc vierge, apres `uninstall --yes` : les quatre unites sont SUPPRIMEES et
# les quatre services TOURNENT encore — `lcars-catalogue` sous `lcars-authority`, `lcars-landing`
# sous `lcars-system`, mesures a `is-active` et au `ps`. Retirer un fichier d'unite n'arrete rien.
#
# CONSEQUENCE EN CHAINE, ET C'EST CE QUI REND L'ORDRE OBLIGATOIRE : `userdel` refuse un compte dont
# un process vit. La classe `account` ne retirait donc RIEN, et le message de refus de ce verbe
# — « process encore vivant ? » — avait predit exactement ce que la machine a montre.

@test "UNITES : elles sont ARRETEES avant que quoi que ce soit ne parte" {
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local n_stop n_rm n_userdel
  n_stop="$(grep -n 'systemctl disable --now' <<<"$body" | head -1 | cut -d: -f1)"
  n_rm="$(grep -n 'for o in .*\${files\[@\]}' <<<"$body" | head -1 | cut -d: -f1)"
  n_userdel="$(grep -n 'userdel "\$o"' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$n_stop" ]
  [ "$n_stop" -lt "$n_rm" ]        # avant le retrait des fichiers
  [ "$n_stop" -lt "$n_userdel" ]   # et avant les comptes, qui sinon sont refuses
}

@test "UNITES : seules les \`.service\` declarees sont arretees — pas un glob sur le systeme" {
  # Un `systemctl stop lcars-*` toucherait ce que ce rail n'a pas pose. La liste vient de `files`,
  # c'est-a-dire de la table, et le filtre nomme le repertoire qu'il vise.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local bloc; bloc="$(sed -n '/for _unit in /,/^  done/p' <<<"$body")"
  [ -n "$bloc" ]
  grep -q 'systemd/system/\*\.service' <<<"$bloc"
  refute grep -qE 'lcars-\*|systemctl stop \*' <<<"$bloc"
}

@test "root n'est exige que pour RETIRER, jamais pour LIRE le plan" {
  # Refuser la lecture sans root obligerait l'operateur a escalader pour SAVOIR ce qui va
  # disparaitre — c'est-a-dire a decider apres avoir escalade.
  plan
  [ "$status" -eq 0 ]
  code | grep -q 'UNINSTALL_YES" -ne 1 || "\$EUID" -eq 0'
}

@test "TRAIT : un suffixe ne change pas la classe — \`anchor:cond\` reste une ancre" {
  # Le mode de defaillance d'un suffixe optionnel est MUET : une classe non decoupee ne matche aucun
  # bras du `case`, la ligne sort du plan, et rien ne le dit. Ce temoin compte, comme celui du
  # substrat : c'est le nombre qui discrimine, pas un nom que le plan n'imprime pas.
  nfic() { sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output"; }
  local n_avant n_apres
  plan; n_avant="$(nfic)"

  : > "$FAKE/etc/lcars/ancre-conditionnelle"
  printf 'anchor:cond  %s/etc/lcars/ancre-conditionnelle  0644 root:root any\n' "$FAKE" >> "$LCARS_SYSTEM_MANIFEST"

  plan; n_apres="$(nfic)"
  [ "$n_apres" -eq "$((n_avant + 1))" ]
}

@test "TRAIT merge : un fichier qu'on MODIFIE n'entre JAMAIS dans ce qui part" {
  # `merge` dit que le fichier est a quelqu'un d'autre et qu'on y a pose une cle. Le retirer
  # detruirait la configuration de son proprietaire pour desinstaller la notre — la meme faute que
  # `rm -rf` sur un home, par un chemin plus discret.
  nfic() { sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output"; }
  local n_avant n_apres
  plan; n_avant="$(nfic)"

  : > "$FAKE/etc/lcars/config-de-lautre"
  printf 'anchor:merge  %s/etc/lcars/config-de-lautre  0644 root:root any\n' "$FAKE" >> "$LCARS_SYSTEM_MANIFEST"

  plan; n_apres="$(nfic)"
  [ "$n_apres" -eq "$n_avant" ]
}

@test "RUNTIME : la classe range des REPERTOIRES, et la boucle des fichiers le sait" {
  # ⚠ LA TABLE A UNE CLASSE QUE L'EXECUTEUR DOIT SAVOIR EXECUTER. `anchor|link|runtime` tombent tous
  # les trois dans `files`, dont le nom promet des fichiers — mais cinq objets `runtime` sont des
  # REPERTOIRES (`/run/lcars`, `/run/lcars/console`, `/run/lcars/toolchain`, `.../authority`,
  # `.../privileged`), et ils en portent d'autres. Un `rm -f` nu sur eux imprimait « non retiré » a
  # chaque passage : un uninstall qui echoue en boucle sur les memes cinq lignes, sans jamais le
  # dire autrement que par une ligne d'erreur qu'on finit par lire comme du decor.
  #
  # ⚠ ET `! -L` PORTE : un LIEN vers un repertoire satisfait `-d`. Sans ce garde, un `rm -rf` sur le
  # lien suivrait la cible — c'est-a-dire detruirait ce que le lien designe, qui n'est pas a nous.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local bloc; bloc="$(sed -n '/for o in .*apt_repo_files/,/^  done$/p' <<<"$body")"
  [ -n "$bloc" ]
  grep -q '\-d "$o" && ! -L "$o"' <<<"$bloc"
  grep -q 'rm -rf "$o"'           <<<"$bloc"
  grep -q 'rm -f "$o"'            <<<"$bloc"
}

@test "RUNTIME : un repertoire declare \`runtime\` entre au plan comme les autres" {
  # Le pendant vivant du temoin ci-dessus : la classe n'est pas seulement executable, elle est
  # EXECUTEE — un `runtime` qui est un repertoire compte parmi les objets du plan.
  nfic() { sed -n 's/^  fichiers *\([0-9]*\) objet.*/\1/p' <<<"$output"; }
  local n_avant n_apres
  plan; n_avant="$(nfic)"

  mkdir -p "$FAKE/run/lcars-decor/dedans"
  printf 'runtime   %s/run/lcars-decor  0755 root:root any\n' "$FAKE" >> "$LCARS_SYSTEM_MANIFEST"

  plan; n_apres="$(nfic)"
  [ "$n_apres" -eq "$((n_avant + 1))" ]
}

@test "BILAN DE SORTIE : il NOMME ce qui reste, et il ne se deduit pas du plan d'entree" {
  # Le plan d'entree dit ce qui VA partir ; le bilan dit ce qui EST reste. Entre les deux il y a les
  # refus (« session ouverte »), les gardes, et ce que le perimetre ne couvre pas — donc l'un ne se
  # calcule pas depuis l'autre. Ce temoin lit le CODE : `--yes` exige root, et une suite qui
  # desinstallerait pour de vrai desinstallerait la machine qui la joue.
  local corps; corps="$(code | sed -n '/CE QUI RESTE SUR CETTE MACHINE/,/^  return 0$/p')"
  [ -n "$corps" ]
  grep -q 'travail préservé' <<<"$corps"
  grep -q 'sous /home'       <<<"$corps"
  grep -q 'paquets apt'      <<<"$corps"
  grep -q 'reliquat'         <<<"$corps"
  grep -q 'refus'            <<<"$corps"
  # ⚠ IL NOMME, IL NE COMPTE PAS. « 12 objets gardes » n'est pas quelque chose sur quoi un operateur
  # peut agir ; un chemin l'est. Le bilan porte donc `preserve_roots`, pas seulement sa taille.
  grep -q 'preserve_roots\[\*\]' <<<"$corps"
}

@test "BILAN DE SORTIE : il est APRES le point de non-retour, jamais dans le plan" {
  # S'il s'imprimait avant `--yes`, il annoncerait « ce qui reste » d'une machine ou rien n'a bouge.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local n_yes n_bilan
  n_yes="$(grep -n 'RIEN N.A ÉTÉ RETIRÉ' <<<"$body" | head -1 | cut -d: -f1)"
  n_bilan="$(grep -n 'CE QUI RESTE SUR CETTE MACHINE' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$n_yes" ] && [ -n "$n_bilan" ]
  [ "$n_yes" -lt "$n_bilan" ]
}

@test "USAGE : \`uninstall\` est documente, et le mode « lister sans detruire » y est nomme" {
  # Il manquait a la liste des verbes — le SEUL qui detruit. Un operateur qui lit l'en-tete ne
  # pouvait ni savoir qu'il existe, ni savoir que sans `--yes` il n'execute rien.
  local entete; entete="$(sed -n '/^# USAGE :/,/^$/p' "$RUNNER")"
  grep -q 'provision uninstall' <<<"$entete"
  grep -q -- '--yes'            <<<"$entete"
  grep -q -- '--humans'         <<<"$entete"
}

@test "le verbe est DECLARE dans le dispatch, sinon il n'existe pas" {
  # ⚠ LA LISTE EXACTE, ET C'EST VOULU : ajouter un verbe doit etre un geste VISIBLE, pas un effet
  # de bord. Ce temoin a rougi le jour ou `audit` est arrive — c'est exactement son metier.
  code | grep -qE 'case "\$CMD" in apply\|doctor\|update\|list\|uninstall\|audit\)'
}

@test "BILAN DE SORTIE : le journal se lit AVANT d'etre emporte, pas apres" {
  # ⚠ MESURE DU 2026-09-01, BANC 2001. Le bilan testait `-r "$JOURNAL_FILE"` a la toute fin — or le
  # journal vit sous la racine d'install, que la boucle `dirs` vient d'emporter au `rm -rf`. Il
  # testait donc l'absence que le script venait lui-meme de creer, et tombait toujours dans la
  # branche « la machine portait deja ». Meme cicatrice d'ordre que « les paquets d'abord » : ce
  # fichier meurt en cours de route, donc tout ce qu'on veut en dire se lit AVANT.
  local body; body="$(code | sed -n '/^uninstall_run()/,/^}$/p')"
  local n_capture n_usage
  n_capture="$(grep -n '_journal_lisible=1' <<<"$body" | head -1 | cut -d: -f1)"
  n_usage="$(grep -n 'journal_lisible" -eq 1' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$n_capture" ] && [ -n "$n_usage" ]
  [ "$n_capture" -lt "$n_usage" ]
  # et le bilan ne re-teste PLUS le fichier lui-meme
  local bilan; bilan="$(sed -n '/CE QUI RESTE SUR CETTE MACHINE/,/^  return 0$/p' <<<"$body")"
  refute grep -q 'r "$JOURNAL_FILE"' <<<"$bilan"
}


# ─── LES ANNEXES DOCKER : GARDEES PAR DEFAUT ────────────────────────────────────────────────────
#
# ⚠ LE DEFAUT S EST INVERSE, ET C EST LA MEME REGLE QUE POUR `/home`. Ces projets sont la forge et
# le runner CI — les ANNEXES du § 13. La forge est le PET du corpus : elle porte les depots et le
# backlog, et sur WSL elle vit SOUS le substrat (§ 10), donc elle survit meme a un
# `wsl --unregister`. Un `uninstall` qui la detruisait rendait la DESINSTALLATION DU RAIL plus
# destructrice que la destruction de la machine. Le § 11 le disait deja : nuke (banc) ≠
# desinstallation (deploiement) ≠ reconstruction — un banc se jette par `bench-down.sh`.
#
# ⚠ ET LA DECISION SE PREND A LA LECTURE, PAS A L EXECUTION. C est ce qui rend ces temoins HONNETES.
# Premiere version : la garde vivait apres le point de non-retour, donc au-dela de ce qu une suite
# sans root peut jouer — trois temoins sur quatre lisaient l ANNONCE du plan, et neutraliser la
# garde ne les faisait pas rougir. Deplacee la ou est celle de `/home` (A1), elle vide la liste
# AVANT le plan : le plan COMPTE juste, et un temoin qui compte mord.

@test "ANNEXES : gardees par defaut — elles n entrent PAS dans ce qui part" {
  printf 'posed_docker lcars-forge lcars-runner\n' > "$LCARS_JOURNAL_FILE"
  plan
  # la ligne « docker » du plan n existe QUE pour ce qui va etre detruit
  printf '%s\n' "$output" | refute_out '^  docker '
  [[ "$output" == *"lcars-forge lcars-runner GARDÉES (défaut)"* ]]
  [[ "$output" == *"continuent de tourner"* ]]
}

@test "ANNEXES : avec --annexes elles entrent, et le plan le DIT" {
  # Le sens qui manque au precedent : sans lui, un code qui n aurait plus AUCUNE branche de
  # destruction passerait le premier en ayant cesse de savoir detruire.
  printf 'posed_docker lcars-forge\n' > "$LCARS_JOURNAL_FILE"
  run bash "$RUNNER" uninstall --annexes
  [[ "$output" == *"docker"*"lcars-forge"*"DÉTRUITS (--annexes)"* ]]
  [[ "$output" == *"volumes restent"* ]]        # les trois natures gardent leurs trois destins (A7)
  printf '%s\n' "$output" | refute_out 'GARDÉES'
}

@test "ANNEXES : la garde vide la liste AVANT le plan — pas apres le point de non-retour" {
  # ⚠ CE QUI REND LES DEUX TEMOINS CI-DESSUS MESURABLES. `--yes` exige root, donc aucune suite ne
  # peut jouer l execution : une garde qui n agirait que la ne serait verifiable que par lecture du
  # code, et le plan pourrait annoncer une destruction qui n aura pas lieu.
  local body; body="$(code | sed -n '/^uninstall_run()/,$p')"
  local n_garde n_plan n_yes
  n_garde="$(grep -n 'annexes_gardees=(' <<<"$body" | head -1 | cut -d: -f1)"
  n_plan="$(grep -n 'annexes.*GARDÉES' <<<"$body" | head -1 | cut -d: -f1)"
  n_yes="$(grep -n 'RIEN N.A ÉTÉ RETIRÉ' <<<"$body" | head -1 | cut -d: -f1)"
  [ -n "$n_garde" ] && [ -n "$n_plan" ] && [ -n "$n_yes" ]
  [ "$n_garde" -lt "$n_plan" ]     # elle agit avant qu on annonce
  [ "$n_plan" -lt "$n_yes" ]       # et l annonce est dans le PLAN, pas dans l execution
}

@test "ANNEXES : le drapeau est DECLARE et documente, sinon il n existe pas" {
  # Meme regle que pour les verbes du dispatch : un drapeau accepte en silence est pire qu un
  # drapeau refuse — c est ce que `--bench` avale sur le poste a coute au rang C.
  code | grep -qE '\-\-annexes\)\s+UNINSTALL_ANNEXES=1'
  sed -n '/^# USAGE :/,/^$/p' "$RUNNER" | grep -q -- '--annexes'
}
