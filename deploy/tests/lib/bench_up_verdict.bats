#!/usr/bin/env bats
# SOURCE: deploy/tests/lib/bench_up_verdict.bats
# AUTHOR: drdree
# STARDATE: 2026-08-14
# STATUS: bats tests for bench-up.sh — 6-133, le verdict final et son code de retour
#
# CE QUE FAISAIT CE SCRIPT. Il construisait un `RUNNER_STATE` riche — « ABSENT », « BLOCAGE, pas
# degradation », « enregistrement rate » — puis imprimait `banc PRET` et rendait 0. Le DIAGNOSTIC
# etait deja juste ; le VERDICT disait le contraire, et c'est le verdict qu'on lit. Une automatisation
# acceptait donc un banc incapable de jouer le moindre workflow CI, et un test d'integration restait
# `pending` au lieu de reveler que son harnais etait incomplet.
#
# ⚠ POURQUOI CE HARNAIS EST PLUS LOURD QUE SON VOISIN. `bench_up_seed.bats` laisse volontairement le
# script mourir dans l'amorçage forge : ce qu'il mesure (l'ordre create→cp→start) est atteint avant.
# Le verdict, lui, est la DERNIERE ligne — il faut donc traverser tout le script. On copie
# `bench-up.sh` dans un faux arbre pour que ses voisins appeles par chemin (`bench-forge-bootstrap.sh`,
# `forge-runner.sh`) soient les notres : `HERE` derive de `BASH_SOURCE`, et `REPO_ROOT` de `HERE`.

load ../refute

setup() {
  ROOT="$BATS_TEST_TMPDIR/fake"
  BENCH="$ROOT/deploy/docker/bench"
  # ⚠ LE DECOR RANGE UNE DOUBLURE LA OU LE CODE LA CHERCHE, jamais la ou il est commode de la poser.
  # `forge-runner.sh` vit dans `docker/`, pas dans `bench/` — et ce decor le posait dans `bench/`,
  # donc il VALIDAIT le chemin faux : les temoins etaient verts pendant que le rail conteneur mourait
  # sur « Aucun fichier ou dossier de ce nom » (mesure .63, 2026-08-30). Un decor qui recopie le
  # defaut le rend indetectable, et c'est la seule espece de test qui coute plus qu'elle ne rapporte.
  DOCKER_D="$ROOT/deploy/docker"
  mkdir -p "$BENCH" "$ROOT/runtime/services/forge-recipe" "$ROOT/deploy/lib"
  cp "$BATS_TEST_DIRNAME/../../docker/bench/bench-up.sh" "$BENCH/bench-up.sh"
  SRC="$BENCH/bench-up.sh"

  # Les composes ne sont jamais lus : docker est une doublure, et `-f <chemin>` lui est opaque.
  : > "$ROOT/runtime/services/forge-recipe/.keep"
  # ⚠ LA LIB EST LA VRAIE, ET PLUS UNE DOUBLURE VIDE (2026-08-18). `bench-up` la source de nouveau :
  # la derivation de l'adresse ANNONCEE (`advertise_addr`) y vit, parce qu'elle depend du substrat et
  # que la recopier ici la ferait diverger. Un stub vide rendrait `advertise_addr` introuvable et le
  # script mourrait avant son verdict — le test mesurerait alors autre chose que ce qu'il croit.
  # ⚠ `provision-lib.sh` SOURCE `docker-endpoint.sh` : le decor doit porter les DEUX, sinon
  # toute la suite tombe sur un « No such file » dont la cause est cette ligne de setup.
  cp "$BATS_TEST_DIRNAME/../../lib/provision-lib.sh" "$ROOT/deploy/lib/provision-lib.sh"
  cp "$BATS_TEST_DIRNAME/../../lib/docker-endpoint.sh" "$ROOT/deploy/lib/docker-endpoint.sh"
  # ⚠ CE DECOR PORTE CE QUE LE SCRIPT SOURCE, ET RIEN DE PLUS — donc toute dependance nouvelle doit
  # y entrer, sinon les 12 temoins de ce fichier tombent d'un coup sur un `No such file`. C'est ce
  # qui est arrive en ajoutant `store.sh` : le decor est un contrat implicite, et il ne se signale
  # que par un echec de masse dont la cause est une ligne de setup.
  cp "$BATS_TEST_DIRNAME/../../lib/store.sh" "$ROOT/deploy/lib/store.sh"

  # L'amorçage forge : il REUSSIT, point. ⚠ IL NE POSE PLUS LE MASTER TOKEN SUR L'HOTE : depuis le
  # 2026-08-16 l'autorite vit DANS le conteneur (`/opt/lcars/var/tokens/forge-master.token`, pose par
  # `forge-gestures.sh config-token`), et `bench-up` l'y lit. Cette doublure ecrivait dans le
  # `--tofu-dir` que le banc n'a plus.
  # ⚠ LA DOUBLURE REFUSE CE QU'ELLE NE COMPREND PAS, comme le vrai script. Elle etait `exit 0` nu :
  # elle avalait donc n'importe quel argv, y compris malforme — et c'est exactement ce qui a masque
  # un defaut pendant des semaines. `--no-human-admin` vidait son tableau par substitution de motif
  # (`("${A[@]/x/}")`), ce qui remplace l'element par une CHAINE VIDE au lieu de le retirer : le vrai
  # bootstrap tombait dans son `*)` — « option inconnue: » — et le banc mourait en exit 4. Le stub,
  # lui, disait oui. Une doublure plus permissive que l'original ne teste pas l'original.
  cat > "$BENCH/bench-forge-bootstrap.sh" <<'FAKE'
#!/usr/bin/env bash
for a in "$@"; do
  case "$a" in
    --forge|--forge-url|--container|--human|--human-admin|--no-human-admin|--tofu-dir|--seed|--*=*) ;;
    -*) ;;                       # les options a valeur passent, leur valeur suit
    "") echo "stub bootstrap: argument VIDE recu — argv malforme" >&2; exit 1 ;;
  esac
done
exit 0
FAKE
  chmod 0755 "$BENCH/bench-forge-bootstrap.sh"

  # La doublure PARLE quand elle refuse — c'est la matiere du test « le refus remonte ». Un faux
  # sous-script muet ne pourrait pas distinguer « bench-up relaie » de « bench-up invente ».
  RUNNER_RC="$BATS_TEST_TMPDIR/runner.rc"
  echo 0 > "$RUNNER_RC"
  # ⚠ LA DOUBLURE ENREGISTRE SON ARGV, et pas seulement son code de retour. Les labels sont derives
  # par `bench-up` puis TRANSMIS ici : sans trace, un label qui disparait de la derivation ne se voit
  # nulle part — le banc monte, le runner s'enregistre, et la forge garde en attente les jobs du
  # label manquant jusqu'a l'escalade, 45 min plus tard, sans qu'une ligne le dise.
  RUNNER_ARGV="$BATS_TEST_TMPDIR/runner.argv"
  export RUNNER_ARGV
  cat > "$DOCKER_D/forge-runner.sh" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$RUNNER_ARGV"
rc="\$(cat "$RUNNER_RC")"
[[ "\$rc" -eq 0 ]] || echo "REFUS-TEMOIN: image(s) introuvable(s) sur ce daemon: alpine:3.20" >&2
exit "\$rc"
FAKE
  chmod 0755 "$DOCKER_D/forge-runner.sh"

  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"

  # ⚠ SEULE L'IMAGE DE BUILD VARIE. Le script fait DEUX `image inspect` : l'image RUNTIME, tres tot
  # (il meurt si elle manque), et `lcars-build:<tag>` qui decide du label elixir. Une doublure qui
  # les traite pareil fait mourir le script bien AVANT le verdict — et le test mesure alors une
  # autre panne, avec un autre code, en croyant mesurer la sienne.
  BUILD_IMG_RC="$BATS_TEST_TMPDIR/build_img.rc"
  echo 0 > "$BUILD_IMG_RC"
  # La REVISION que l'image porte dans son label OCI. L'etat nominal est une image estampillee ; les
  # tests qui mesurent l'absence l'effacent. Sert la forme `image inspect -f <fmt> <image>`, qu'il
  # faut distinguer du `image inspect <image>` d'existence — meme deux premiers mots, autre question.
  IMAGE_REV_OUT="$BATS_TEST_TMPDIR/image_rev.out"
  echo "deadbeef1" > "$IMAGE_REV_OUT"
  # Le token OPERATEUR (`~/.gitea_token` du worker), exige par le verdict depuis 2026-08-15 : il peut
  # etre saute par les DEUX passes d'amorcage sans que rien ne le dise, donc le verdict le mesure.
  # Etat nominal « oui » ; le temoin de son absence l'ecrase.
  OP_TOKEN_OUT="$BATS_TEST_TMPDIR/op_token.out"
  echo "oui" > "$OP_TOKEN_OUT"
  # Le MASTER token, desormais lu dans le conteneur et plus sur l'hote. Nominal : present.
  MASTER_TOKEN_OUT="$BATS_TEST_TMPDIR/master_token.out"
  echo "MASTER" > "$MASTER_TOKEN_OUT"
  # LE VERDICT QUE LE CONTENEUR PUBLIE SUR LUI-MEME (`/run/lcars-provision.rc`, pose par l'entrypoint a
  # chaque boot). Nominal : 0, convergee. Un temoin l'ecrase pour mesurer le refus.
  # ⚠ CE FICHIER DOIT AVOIR UNE VALEUR NOMINALE, et pas rester absent « puisque ca passe quand meme ».
  # Absent, le script conclut « NON MESUREE » — ce qui n'est PAS un echec, donc les 24 temoins
  # resteraient verts en mesurant l'etat non-mesure au lieu de l'etat convergé. Un decor qui laisse
  # tout passer ne teste rien : il faut que le nominal soit le NOMINAL.
  CONTAINER_PROV_RC_OUT="$BATS_TEST_TMPDIR/container_prov_rc.out"
  echo "0" > "$CONTAINER_PROV_RC_OUT"
  # ⚠ La doublure decide sur l'ARGV COMPLET, jamais sur `$1 $2` : les `exec` portent le nom du
  # conteneur en second argument (`exec <container> cat …`), donc un motif sur les deux premiers mots rate
  # tous les `exec` — et le script meurt sur « token systeme absent » avant d'atteindre le verdict,
  # c'est-a-dire avant ce que ces tests mesurent.
  cat > "$BINDIR/dockerstub" <<FAKE
#!/usr/bin/env bash
argv="\$*"
# Les variables du container traversent en ENVIRONNEMENT, pas en argv : la doublure les depose quand elle
# voit le 'create', sinon aucun temoin ne peut lire ce que le conteneur recoit.
# (guillemets simples et pas d'accents graves : ce heredoc n'est PAS quote, donc bash y fait de la
#  SUBSTITUTION DE COMMANDE — un mot entre accents graves y est EXECUTE, meme dans un commentaire.)
case "\$argv" in *" create lcars"*) printf 'LCARS_DECK_ORIGINS=%s\n' "\${LCARS_DECK_ORIGINS:-}" > "$BATS_TEST_TMPDIR/container.env" ;; esac
case "\$argv" in
  *"ps --filter publish="*) [[ -f "$BATS_TEST_TMPDIR/port_holder" ]] && cat "$BATS_TEST_TMPDIR/port_holder"; exit 0 ;;
esac
case "\$1 \$2" in
  "run --rm")      echo flux-ok; exit 0 ;;
  "ps -a")         exit 0 ;;
  "inspect -f")    echo healthy; exit 0 ;;
  "image inspect")
     case "\$3" in
       -f)            cat "$IMAGE_REV_OUT"; exit 0 ;;
       lcars-build:*) exit "\$(cat "$BUILD_IMG_RC")" ;;
       *)             exit 0 ;;
     esac ;;
esac
case "\$argv" in
  # L'AUTORITE, LUE DANS LE CONTENEUR. Etat nominal : elle y est. Le temoin de son absence l'efface —
  # c'est ce que le verdict « pas de master token » mesure desormais.
  *forge-master.token*)   cat "$MASTER_TOKEN_OUT" ;;
  *forge-gestures.sh\ runner-token*) echo REG-TOKEN-TEMOIN ;;
  # LE JETON SYSTEME PORTE LE NOM DE SON COMPTE, comme les neuf autres. Il s'appelait
  # \`system.gitea_token\` pour un compte nomme \`lcars-system\` — un nom derive de rien, qu'une table
  # devait porter. Cette doublure epinglait l'ancien nom : au renommage, \`bench-up\` cherchait le
  # bon fichier et la doublure servait l'ancien, donc le banc se declarait « token systeme absent
  # apres deux passes » sur un banc parfaitement sain. Le motif suit desormais le COMPTE.
  *system_starfleet.gitea_token*) echo TOKEN-SYSTEME ;;
  *"*.gitea_token"*)      echo 9 ;;
  # Le token OPERATEUR, dans le home du worker — distinct du glob /opt/lcars/var/tokens ci-dessus, qui vise
  # les tokens de ROLE. Deux fichiers homonymes, deux rails : celui-ci est la voie du conteneur vers
  # la forge, et 'bench-up.sh' l'EXIGE depuis 2026-08-15 (saute par les deux passes, sinon).
  *"~/.gitea_token"*)     cat "$OP_TOKEN_OUT" ;;
  *credentials.json*)     echo oui ;;
  *lcars-provision.rc*)   cat "$CONTAINER_PROV_RC_OUT" ;;
esac
exit 0
FAKE
  chmod 0755 "$BINDIR/dockerstub"

  # La forge repond, et l'endpoint des runners rend une liste NON VIDE : l'etat nominal.
  RUNNERS_JSON="$BATS_TEST_TMPDIR/runners.json"
  printf '{"runners":[{"id":1}]}\n' > "$RUNNERS_JSON"
  cat > "$BINDIR/curl" <<FAKE
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *actions/runners) cat "$RUNNERS_JSON"; exit 0 ;;
    *api/v1/user)     printf '{"is_admin":true}\n'; exit 0 ;;
  esac
done
exit 0
FAKE
  chmod 0755 "$BINDIR/curl"

  export PATH="$BINDIR:$PATH"
  export DOCKER_BIN=dockerstub
  export DOCKER_HOST=unix:///dev/null
}

run_bench() {
  run bash "$SRC" --project bt --no-creds --no-human-admin --image lcars-fleet:9 "$@"
}

@test "TEMOIN 6-133: runner demande ET servi → « banc PRET », exit 0" {
  # Sans ce temoin, un correctif qui refuserait TOUJOURS passerait les tests d'echec (P-40).
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc PRET"* ]]
  [[ "$output" != *"PAS PRET"* ]]
  # Le conteneur a publie 0 : le verdict le DIT, il ne se contente pas de ne pas refuser.
  [[ "$output" == *"converge  : convergee"* ]]
}

# ─── LE CONTENEUR PUBLIE SON PROPRE VERDICT, ET IL COMPTE ────────────────────────────────────────────
# MEME FAUTE QUE 6-133, AU SITE D'A COTE. L'entrypoint mesure la convergence du conteneur et l'ecrit
# dans `/run/lcars-provision.rc` — precisement parce qu'un echec de convergence NE TUE PAS le
# conteneur : le conteneur doit rester joignable pour etre repare. Il survit donc a son propre echec,
# se declare *healthy* (son healthcheck ne sonde que des ports : ssh + le deck), et `bench-up` ne lisait pas le fichier.
# Un banc dont le conteneur ne peut demarrer AUCUN pod sortait « banc PRET » et rendait 0.
#
# Le geste operateur (`deploy/container`, `await_provision_verdict`) le lisait deja. Deux chemins qui
# lisent le meme fichier doivent en tirer le MEME verdict, sinon le fichier ne veut plus rien dire.

@test "le conteneur publie un ECHEC de convergence → PAS PRET, exit 6, meme si tout le reste est vert" {
  echo "1" > "$CONTAINER_PROV_RC_OUT"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRET"* ]]
  [[ "$output" == *"CONTENEUR"* ]]
  [[ "$output" == *"rc=1"* ]]
  # Le refus nomme le geste de diagnostic, pas seulement l'echec : on repare avec, pas sans.
  [[ "$output" == *"provision doctor"* ]]
}

@test "un ECHEC du conteneur prime sur un runner parfaitement servi — l'ordre est celui de la gravite" {
  # Un runner qui sert impeccablement un conteneur qui ne produit rien est un banc qui ne produit rien.
  # Ce temoin garde l'ORDRE des branches : intervertir ferait annoncer « banc PRET » a un conteneur
  # morte, exactement l'etat que ce correctif ferme.
  echo "3" > "$CONTAINER_PROV_RC_OUT"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"le CONTENEUR s'est declare en echec"* ]]
  [[ "$output" != *"le runner etait DEMANDE"* ]]
}

@test "DRIFT RESIDUEL (rc=2) n'est PAS un echec — le banc reste PRET, et le drift se DIT" {
  # 2 = applique, etat-cible non tenu : un geste manque (forge, credentials, reseau), rien n'est
  # casse. Le confondre avec un echec rendrait rouge la moitie des bancs pour un etat que
  # l'entrypoint ET le geste operateur qualifient tous deux de non-fatal.
  echo "2" > "$CONTAINER_PROV_RC_OUT"
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc PRET"* ]]
  [[ "$output" == *"DRIFT RESIDUEL"* ]]
}

@test "un verdict de conteneur ILLISIBLE est une NON-MESURE, pas un echec — et il se dit" {
  # Ne pas avoir lu le verdict n'est pas l'avoir lu mauvais. Sortir non nul sur une non-mesure
  # apprend a ignorer le code de sortie, ce qui coute exactement le jour ou il est vrai. Meme
  # arbitrage que `deploy/container` sur l'expiration de son attente.
  #
  # ⚠ ET LE CAS EST REEL, pas theorique : ce fichier vit sur un tmpfs et n'existe qu'apres que
  # l'entrypoint a fini son apply. Un conteneur qui vient de repartir n'en a pas encore.
  printf 'cat: /run/lcars-provision.rc: No such file or directory\n' > "$CONTAINER_PROV_RC_OUT"
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"banc PRET"* ]]
  [[ "$output" == *"NON MESUREE"* ]]
}

@test "token operateur absent apres DEUX passes → refus, exit 6, et la CAUSE est nommee" {
  # Le geste que ce temoin garde : `bench-forge-bootstrap` ne peut pas poser `~/.gitea_token` a la
  # passe 1 — le worker vient de la FORGE et n'existe en unix qu'apres la relance que cette passe
  # demande. Il saute donc, en le disant, et la passe 2 pose. Mesure du 2026-08-15 : avant ce
  # saut, la passe 1 MOURAIT sur « unable to find user lcars » et le banc ne montait pas.
  #
  # Ce qui rend ce saut sur n'est PAS son message, c'est cette exigence : deux passes qui sautent
  # toutes les deux donneraient un banc vert dont le conteneur ne parle pas a la forge, sans un mot.
  # Le refus doit nommer la CAUSE (le worker manque) et pas seulement le symptome (le fichier manque).
  echo "non" > "$OP_TOKEN_OUT"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"token operateur absent"* ]]
  [[ "$output" == *"convergeur"* ]]
  [[ "$output" != *"banc PRET"* ]]
}

@test "les labels derives portent les TROIS, dont « ubuntu-latest » — et plus le label elixir" {
  # ⚖ USER 2026-08-21. `ubuntu-latest` est le `runs-on` par DEFAUT de l'ecosysteme : tout workflow
  # importe, tout exemple copie d'ailleurs, toute action tierce le nomme. Sans lui le banc refuse ces
  # jobs EN SILENCE — la forge les garde en attente d'un runner qui ne viendra pas, 45 min, puis
  # escalade, et rien ne dit que c'est le LABEL qui manque.
  #
  # Ce temoin garde la DERIVATION, pas une chaine : il lit ce que `bench-up` a reellement transmis a
  # `forge-runner.sh`. Un label retire du defaut n'a alors nulle part ou se cacher.
  run_bench
  [ "$status" -eq 0 ]
  run cat "$RUNNER_ARGV"
  [[ "$output" == *"shell:docker://alpine:3.20"* ]]
  [[ "$output" != *"elixir:"* ]]
  [[ "$output" == *"dood:docker://docker:cli"* ]]
  [[ "$output" == *"ubuntu-latest:docker://catthehacker/ubuntu:act-latest"* ]]
}

@test "6-133: forge-runner.sh en echec → PAS PRET, exit 6" {
  echo 1 > "$RUNNER_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRET"* ]]
}

@test "FUITE: un banc REUSSI ne laisse aucun log de sous-script derriere lui" {
  # ⚠ ELLE FUYAIT SURTOUT QUAND TOUT ALLAIT BIEN, ce qui est le pire cas : `mktemp` posait le log a
  # chaque passage, le chemin de SUCCES ne le lit jamais (la sortie du sous-script est muette au
  # succes, par contrat) et rien ne l'effacait. Mesure du 2026-08-20 : 1561 fichiers
  # `forge-runner-bt.*` dans /tmp — `bt` est le projet de CETTE suite, donc c'est elle qui les a
  # poses, un par execution, pour zero lecteur. 1189 faisaient ZERO octet.
  local T="$BATS_TEST_TMPDIR/tmpdir"; mkdir -p "$T"
  TMPDIR="$T" run_bench
  [ "$status" -eq 0 ]
  [ "$(find "$T" -name 'forge-runner-*' | wc -l)" -eq 0 ]
}

@test "FUITE: un banc EN ECHEC garde son log, et le verdict le NOMME" {
  # Le pendant, et c'est lui qui empeche de « corriger » la fuite en effacant tout : le verdict ne
  # cite que les 12 dernieres lignes du refus. Pour un refus plus long, ce fichier est la seule copie
  # du reste — le supprimer rendrait le diagnostic tronque sans que personne le sache. Garde ET
  # nomme : un fichier auquel le verdict renvoie, pas un dechet anonyme de plus.
  local T="$BATS_TEST_TMPDIR/tmpdir"; mkdir -p "$T"
  echo 1 > "$RUNNER_RC"
  TMPDIR="$T" run_bench
  [ "$status" -eq 6 ]
  [ "$(find "$T" -name 'forge-runner-*' | wc -l)" -eq 1 ]
  [[ "$output" == *"sortie COMPLETE conservee"* ]]
  [[ "$output" == *"$T/forge-runner-"* ]]
}

@test "6-133: runner demarre mais AUCUN vu par la forge → PAS PRET, exit 6" {
  # L'etat le plus traitre : le processus tourne, et la forge ne le connait pas.
  printf '{"runners":[]}\n' > "$RUNNERS_JSON"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRET"* ]]
}

@test "6-133bis: la branche « pas de master token » non plus" {
  # Meme defaut, meme ligne, deuxieme occurrence : la corriger a un seul endroit l'aurait laissee.
  #
  # ⚠ LA FACON DE PROVOQUER L'ABSENCE A CHANGE AVEC LA SOURCE. Ce test vidait le sous-script
  # d'amorcage, parce que c'etait LUI qui persistait le master token sur l'hote. Depuis le
  # 2026-08-16 l'autorite vit dans le conteneur : ce qu'il faut vider est la reponse de la doublure
  # docker, pas le sous-script. Un test qui aurait garde l'ancien geste serait passe au VERT sur un
  # banc dont le token est bien la — il aurait mesure un chemin que plus personne ne prend.
  : > "$MASTER_TOKEN_OUT"

  run_bench
  [ "$status" -ne 127 ]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" == *"master token"* ]]
}

@test "6-133: le bloc de details est imprime AVANT le refus — on repare avec, pas sans" {
  echo 1 > "$RUNNER_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"runner    :"* ]]
  [[ "$output" == *"destruire :"* ]]
}

# 2026-08-14 — LE SEUL ECHEC QUE CE SCRIPT NE SAVAIT PAS EXPLIQUER ETAIT CELUI QU'IL FAISAIT TAIRE.
# L'appel a `forge-runner.sh` partait en `>/dev/null 2>&1`, donc le verdict se reduisait a « en echec
# (rejouable : forge-runner.sh --help) ». Le sous-script, lui, avait dit exactement quoi reparer —
# et le rejouer a la main demande de reconstruire ses six arguments, dont un token qui vit dans un
# `mktemp` que rien ne documente. Le test epingle la PROPAGATION, pas la formulation du relais.
@test "6-14: le refus de forge-runner.sh remonte MOT POUR MOT dans le verdict" {
  echo 1 > "$RUNNER_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"REFUS-TEMOIN"* ]]
  [[ "$output" == *"alpine:3.20"* ]]
}

@test "6-14: TEMOIN — un runner qui REUSSIT ne deverse pas le journal du sous-script" {
  # Sans ce temoin, un correctif qui imprimerait la sortie dans TOUS les cas passerait le test
  # ci-dessus. Le silence au succes est la moitie du contrat : un banc vert n'a rien a raconter.
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUS-TEMOIN"* ]]
}

# 2026-08-14 — LE BANC DEPLOYAIT UNE IMAGE MUETTE SUR SON PROPRE CODE, ET NE LE VOYAIT PAS. Mesure :
# une image batie a la main (docker build sans --build-arg GIT_SHA) a produit un banc entierement
# vert dont `/api/version` rendait `sha: "unknown"`. Aucun verdict rendu par ce banc n'etait donc
# attribuable a un commit — la seule chose qu'on lui demande. Le TAG ne prouve rien : c'est un nom,
# il s'ecrit a la main, et c'est precisement ce que j'avais fait.
@test "6-14: une image sans revision est ANNONCEE inconnue dans le bloc de verdict" {
  : > "$IMAGE_REV_OUT"
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"revision"* ]]
  [[ "$output" == *"INCONNUE"* ]]
}

@test "6-14: le litteral « unknown » du Dockerfile compte comme absence, pas comme revision" {
  # `ARG GIT_SHA=unknown` : une image non estampillee porte le mot, pas le vide. Un test qui ne
  # verifierait que la chaine vide laisserait passer le cas REEL, qui est celui-la.
  echo "unknown" > "$IMAGE_REV_OUT"
  run_bench
  [[ "$output" == *"INCONNUE"* ]]
}

@test "6-14: TEMOIN — une image estampillee montre SA revision, pas un avertissement" {
  run_bench
  [ "$status" -eq 0 ]
  [[ "$output" == *"deadbeef1"* ]]
  [[ "$output" != *"INCONNUE"* ]]
}

@test "6-133: --no-runner porte son PROPRE verdict, jamais celui du banc complet" {
  # Un mode degrade CHOISI et un mode degrade SUBI ne se disent pas du meme mot : celui qui lit un
  # journal doit distinguer « je n'ai pas voulu de CI » de « la CI n'a pas pu se poser ».
  echo 1 > "$BUILD_IMG_RC"
  run_bench --no-runner
  [ "$status" -eq 0 ]
  [[ "$output" == *"PRET_SANS_CI"* ]]
  [[ "$output" != *"PAS PRET"* ]]
}

# ─── ecoute vs annonce : `0.0.0.0` n'est l'adresse de personne ────────────────────────────────────
#
# ⚖ ARBITRAGE USER 2026-08-18 : le banc s'ouvre sur le LAN (20999 deck, 21000 forge). Le bind passe
# donc a `0.0.0.0` — un JOKER D'ECOUTE. Mis dans une URL il casse trois choses d'un coup : le
# `ROOT_URL` de Gitea (chaque lien qu'il fabrique pointe nulle part), le `redirect_uri` OAuth2 du
# deck (le retour de login tombe dans le vide) et la ligne de recap (une adresse qu'on ne peut pas
# taper). Ces temoins tiennent la separation.

@test "l'adresse ANNONCEE n'est jamais le joker d'ecoute" {
  run env LCARS_BENCH_FAKE=1 bash "$SRC" --no-runner --no-creds --bind 0.0.0.0 --advertise 10.0.0.9
  [[ "$output" != *"http://0.0.0.0:"* ]]
  [[ "$output" == *"http://10.0.0.9:21000"* ]]
  [[ "$output" == *"http://10.0.0.9:20999"* ]]
}

@test "le banc ne declare que l'entree qu'il ANNONCE — les loopbacks sont semees par le module" {
  # Le deck derive son `redirect_uri` du `Host` de la requete et OAuth2 compare EXACTEMENT. Il y a
  # donc au moins TROIS entrees vraies : `127.0.0.1`, `localhost` (deux ORIGINES distinctes pour un
  # meme point d'ecoute — et c'est `localhost` que tape un humain) et l'adresse annoncee.
  # Les deux premieres sont invariantes : 66-deck-oidc les seme, une fois, pour tous les conteneurs.
  # Ce script n'a qu'un seul fait a apporter — celui qu'il est seul a connaitre.
  run env LCARS_BENCH_FAKE=1 bash "$SRC" --no-runner --no-creds --bind 0.0.0.0 --advertise 10.0.0.9
  grep -q "LCARS_DECK_ORIGINS=http://10.0.0.9:20999$" "$BATS_TEST_TMPDIR/container.env"
}

@test "un bind PRECIS rend les deux adresses egales — l'ancien comportement revient" {
  run env LCARS_BENCH_FAKE=1 bash "$SRC" --no-runner --no-creds --bind 127.0.0.5
  [[ "$output" == *"http://127.0.0.5:21000"* ]]
  [[ "$output" == *"cette machine seulement"* ]]
}

@test "ouvert sur le reseau, le banc DIT ce que ca coute" {
  # Les mots de passe de ce banc sont des defauts de test, publics dans le README. Ouvrir sans le
  # dire, c'est livrer une porte ouverte a quelqu'un qui croit avoir un conteneur ferme.
  run env LCARS_BENCH_FAKE=1 bash "$SRC" --no-runner --no-creds --bind 0.0.0.0 --advertise 10.0.0.9
  [[ "$output" == *"OUVERT SUR LE RESEAU"* ]]
  [[ "$output" == *"--bind 127.0.0.1"* ]]
}

@test "un port deja tenu par un AUTRE banc est refuse AVANT de creer quoi que ce soit" {
  # LE DEFAUT MESURE (2026-08-18) : sur un bind joker, docker refuse en nommant l'adresse de
  # l'AUTRE banc — « Bind for 127.0.0.6:2222 failed » sur une machine ou personne n'a tape
  # 127.0.0.6 — et le script mourait en « le conteneur ne demarre pas », c'est-a-dire en accusant le
  # conteneur d'un conflit qui ne lui appartient pas.
  echo "un-autre-banc" > "$BATS_TEST_TMPDIR/port_holder"
  run env LCARS_BENCH_FAKE=1 bash "$SRC" --no-runner --no-creds

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  [[ "$output" == *"un-autre-banc"* ]]
  # Les deux sorties sont nommees, sinon le refus ne se distingue pas d'une panne.
  [[ "$output" == *"bench-down.sh"* ]]
  [[ "$output" == *"--forge-port"* ]]
}

@test "sous WSL, le recap DIT host-only et ne dicte aucune reconfiguration reseau" {
  # ⚖ ARBITRAGE USER 2026-08-18. Ce bloc imprimait deux `netsh portproxy` prets a coller. Une
  # recette est une invitation, et celle-ci invitait a reconfigurer la pile Hyper-V du poste pour un
  # banc de dev. Le NAT est le defaut de WSL et de Docker Desktop : host-only EST la cible sur ce
  # substrat, et la cible LAN c'est le Linux natif.
  #
  # TEMOIN STRUCTUREL, et il l'est par necessite : la ligne ne s'imprime que sur un substrat WSL en
  # NAT. Un temoin qui l'executerait mesurerait la machine qui joue les tests, pas le script.
  refute grep -qE '^[[:space:]]*say .*netsh' "$SRC"
  refute grep -qE '^[[:space:]]*say .*portproxy' "$SRC"
  grep -q "n'est joignable que depuis CETTE machine" "$SRC"
}

@test "les TROIS ports du banc ont leur option — sinon deux bancs ne cohabitent pas" {
  # Le pre-vol refuse un port deja tenu (temoin plus haut). `--forge-port` et `--deck-port`
  # existaient, `--ssh-port` non : un second banc sur la meme machine se refusait donc sur 2222,
  # sans qu'aucune option ne permette de le deplacer. Deux bancs par machine — un jetable qu'on
  # casse, un complet ou on travaille — est le cas ordinaire ici.
  run env LCARS_BENCH_FAKE=1 bash "$SRC" --no-runner --no-creds --bind 127.0.0.5 \
      --forge-port 21001 --deck-port 20998 --ssh-port 2223
  [[ "$output" == *"ssh 127.0.0.5:2223"* ]]
  [[ "$output" == *"http://127.0.0.5:21001"* ]]
  [[ "$output" == *"http://127.0.0.5:20998"* ]]
}


@test "REGRESSION --no-human-admin : le drapeau ne transmet AUCUN argument, pas un argument VIDE" {
  # ⚠ CE DEFAUT A VECU MASQUE PAR SON PROPRE HARNAIS. `("${A[@]/motif/}")` ne RETIRE pas l'element :
  # il le remplace par une chaine vide, et le tableau garde sa taille. Mesure :
  #   A=(--human-admin); A=("${A[@]/--human-admin/}"); echo ${#A[@]}   ->  1
  # L'argument vide partait au bootstrap, tombait dans son `*)`, et le banc mourait en exit 4 sur
  # « amorcage passe 1 en echec » — pour un drapeau qui devait juste ne rien ajouter.
  #
  # On epingle le CONTRAT (zero argument transmis), pas la forme du code : une autre facon de vider
  # le tableau resterait juste.
  local decl
  decl="$(grep -n -- '--no-human-admin)' "$SRC" | head -1)"
  [[ "$decl" != *'[@]/'* ]]
  # Et le comportement, joue pour de vrai : la doublure refuse desormais un argv malforme.
  RUNNER_RC_VAL=0 run_bench
  [[ "$output" != *"argument VIDE"* ]]
}
