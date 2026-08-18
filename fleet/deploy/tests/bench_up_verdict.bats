#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/bench_up_verdict.bats
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
# `bench-runner.sh`) soient les notres : `HERE` derive de `BASH_SOURCE`, et `REPO_ROOT` de `HERE`.

setup() {
  ROOT="$BATS_TEST_TMPDIR/fake"
  BENCH="$ROOT/fleet/deploy/docker/bench"
  mkdir -p "$BENCH" "$ROOT/fleet/deploy/deps" "$ROOT/fleet/deploy/lib"
  cp "$BATS_TEST_DIRNAME/../docker/bench/bench-up.sh" "$BENCH/bench-up.sh"
  SRC="$BENCH/bench-up.sh"

  # Les composes ne sont jamais lus : docker est une doublure, et `-f <chemin>` lui est opaque.
  : > "$ROOT/fleet/deploy/deps/.keep"
  # ⚠ LA LIB EST LA VRAIE, ET PLUS UNE DOUBLURE VIDE (2026-08-18). `bench-up` la source de nouveau :
  # la derivation de l'adresse ANNONCEE (`advertise_addr`) y vit, parce qu'elle depend du substrat et
  # que la recopier ici la ferait diverger. Un stub vide rendrait `advertise_addr` introuvable et le
  # script mourrait avant son verdict — le test mesurerait alors autre chose que ce qu'il croit.
  cp "$BATS_TEST_DIRNAME/../lib/provision-lib.sh" "$ROOT/fleet/deploy/lib/provision-lib.sh"

  # L'amorçage forge : il REUSSIT, point. ⚠ IL NE POSE PLUS LE MASTER TOKEN SUR L'HOTE : depuis le
  # 2026-08-16 l'autorite vit DANS la boite (`/home/private/forge-master.token`, pose par
  # `forge-gestures.sh config-token`), et `bench-up` l'y lit. Cette doublure ecrivait dans le
  # `--tofu-dir` que le banc n'a plus.
  cat > "$BENCH/bench-forge-bootstrap.sh" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
  chmod 0755 "$BENCH/bench-forge-bootstrap.sh"

  # La doublure PARLE quand elle refuse — c'est la matiere du test « le refus remonte ». Un faux
  # sous-script muet ne pourrait pas distinguer « bench-up relaie » de « bench-up invente ».
  RUNNER_RC="$BATS_TEST_TMPDIR/runner.rc"
  echo 0 > "$RUNNER_RC"
  cat > "$BENCH/bench-runner.sh" <<FAKE
#!/usr/bin/env bash
rc="\$(cat "$RUNNER_RC")"
[[ "\$rc" -eq 0 ]] || echo "REFUS-TEMOIN: image(s) introuvable(s) sur ce daemon: alpine:3.20" >&2
exit "\$rc"
FAKE
  chmod 0755 "$BENCH/bench-runner.sh"

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
  # Le MASTER token, desormais lu dans la boite et plus sur l'hote. Nominal : present.
  MASTER_TOKEN_OUT="$BATS_TEST_TMPDIR/master_token.out"
  echo "MASTER" > "$MASTER_TOKEN_OUT"
  # ⚠ La doublure decide sur l'ARGV COMPLET, jamais sur `$1 $2` : les `exec` portent le nom de la
  # boite en second argument (`exec <box> cat …`), donc un motif sur les deux premiers mots rate
  # tous les `exec` — et le script meurt sur « token systeme absent » avant d'atteindre le verdict,
  # c'est-a-dire avant ce que ces tests mesurent.
  cat > "$BINDIR/dockerstub" <<FAKE
#!/usr/bin/env bash
argv="\$*"
# Les variables du box traversent en ENVIRONNEMENT, pas en argv : la doublure les depose quand elle
# voit le `create`, sinon aucun temoin ne peut lire ce que la boite recoit.
case "\$argv" in *" create lcars"*) printf 'LCARS_DECK_ORIGINS=%s\n' "\${LCARS_DECK_ORIGINS:-}" > "$BATS_TEST_TMPDIR/box.env" ;; esac
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
  # L'AUTORITE, LUE DANS LA BOITE. Etat nominal : elle y est. Le temoin de son absence l'efface —
  # c'est ce que le verdict « pas de master token » mesure desormais.
  *forge-master.token*)   cat "$MASTER_TOKEN_OUT" ;;
  *forge-gestures.sh\ runner-token*) echo REG-TOKEN-TEMOIN ;;
  *system.gitea_token*)   echo TOKEN-SYSTEME ;;
  *"*.gitea_token"*)      echo 9 ;;
  # Le token OPERATEUR, dans le home du worker — distinct du glob /home/private ci-dessus, qui vise
  # les tokens de ROLE. Deux fichiers homonymes, deux rails : celui-ci est la voie de la boite vers
  # la forge, et `bench-up.sh` l'EXIGE depuis 2026-08-15 (il pouvait etre saute par les deux passes).
  *"~/.gitea_token"*)     cat "$OP_TOKEN_OUT" ;;
  *credentials.json*)     echo oui ;;
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
}

@test "token operateur absent apres DEUX passes → refus, exit 6, et la CAUSE est nommee" {
  # Le geste que ce temoin garde : `bench-forge-bootstrap` ne peut pas poser `~/.gitea_token` a la
  # passe 1 — le worker vient de la FORGE et n'existe en unix qu'apres la relance que cette passe
  # demande. Il saute donc, en le disant, et la passe 2 pose. Mesure du 2026-08-15 : avant ce
  # saut, la passe 1 MOURAIT sur « unable to find user lcars » et le banc ne montait pas.
  #
  # Ce qui rend ce saut sur n'est PAS son message, c'est cette exigence : deux passes qui sautent
  # toutes les deux donneraient un banc vert dont la boite ne parle pas a la forge, sans un mot.
  # Le refus doit nommer la CAUSE (le worker manque) et pas seulement le symptome (le fichier manque).
  echo "non" > "$OP_TOKEN_OUT"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"token operateur absent"* ]]
  [[ "$output" == *"convergeur"* ]]
  [[ "$output" != *"banc PRET"* ]]
}

@test "6-133: pas d'image pour le label elixir → PAS PRET, exit 6" {
  echo 1 > "$BUILD_IMG_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRET"* ]]
}

@test "6-133: bench-runner.sh en echec → PAS PRET, exit 6" {
  echo 1 > "$RUNNER_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRET"* ]]
}

@test "6-133: runner demarre mais AUCUN vu par la forge → PAS PRET, exit 6" {
  # L'etat le plus traitre : le processus tourne, et la forge ne le connait pas.
  printf '{"runners":[]}\n' > "$RUNNERS_JSON"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"PAS PRET"* ]]
}

@test "6-133bis: la branche « pas d'image » DIT quelque chose — elle mourait en 127, muette" {
  # TROUVE EN INSTRUMENTANT, et la fiche ne le voit pas. Son message contenait `ci: required` entre
  # BACKTICKS dans une chaine a guillemets DOUBLES : bash y lisait une substitution de commande,
  # executait `ci:`, echouait, et `set -euo pipefail` tuait le script — exit 127, pour seul message
  # « ci:: command not found ». Cette branche ne remplissait donc pas RUNNER_STATE : elle mourait
  # AVANT de l'ecrire. Le test epingle le DIAGNOSTIC, pas le code : un message reecrit sans
  # echappement ramenerait la panne en silence.
  echo 1 > "$BUILD_IMG_RC"
  run_bench
  [ "$status" -ne 127 ]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" == *"lcars-build"* ]]
  [[ "$output" == *"ci: required"* ]]
}

@test "6-133bis: la branche « pas de master token » non plus" {
  # Meme defaut, meme ligne, deuxieme occurrence : la corriger a un seul endroit l'aurait laissee.
  #
  # ⚠ LA FACON DE PROVOQUER L'ABSENCE A CHANGE AVEC LA SOURCE. Ce test vidait le sous-script
  # d'amorcage, parce que c'etait LUI qui persistait le master token sur l'hote. Depuis le
  # 2026-08-16 l'autorite vit dans la boite : ce qu'il faut vider est la reponse de la doublure
  # docker, pas le sous-script. Un test qui aurait garde l'ancien geste serait passe au VERT sur un
  # banc dont le token est bien la — il aurait mesure un chemin que plus personne ne prend.
  : > "$MASTER_TOKEN_OUT"

  run_bench
  [ "$status" -ne 127 ]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" == *"master token"* ]]
}

@test "6-133: le bloc de details est imprime AVANT le refus — on repare avec, pas sans" {
  echo 1 > "$BUILD_IMG_RC"
  run_bench
  [ "$status" -eq 6 ]
  [[ "$output" == *"runner    :"* ]]
  [[ "$output" == *"destruire :"* ]]
}

# 2026-08-14 — LE SEUL ECHEC QUE CE SCRIPT NE SAVAIT PAS EXPLIQUER ETAIT CELUI QU'IL FAISAIT TAIRE.
# L'appel a `bench-runner.sh` partait en `>/dev/null 2>&1`, donc le verdict se reduisait a « en echec
# (rejouable : bench-runner.sh --help) ». Le sous-script, lui, avait dit exactement quoi reparer —
# et le rejouer a la main demande de reconstruire ses six arguments, dont un token qui vit dans un
# `mktemp` que rien ne documente. Le test epingle la PROPAGATION, pas la formulation du relais.
@test "6-14: le refus de bench-runner.sh remonte MOT POUR MOT dans le verdict" {
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
  # Les deux premieres sont invariantes : 55-deck-oidc les seme, une fois, pour toutes les boites.
  # Ce script n'a qu'un seul fait a apporter — celui qu'il est seul a connaitre.
  run env LCARS_BENCH_FAKE=1 bash "$SRC" --no-runner --no-creds --bind 0.0.0.0 --advertise 10.0.0.9
  grep -q "LCARS_DECK_ORIGINS=http://10.0.0.9:20999$" "$BATS_TEST_TMPDIR/box.env"
}

@test "un bind PRECIS rend les deux adresses egales — l'ancien comportement revient" {
  run env LCARS_BENCH_FAKE=1 bash "$SRC" --no-runner --no-creds --bind 127.0.0.5
  [[ "$output" == *"http://127.0.0.5:21000"* ]]
  [[ "$output" == *"cette machine seulement"* ]]
}

@test "ouvert sur le reseau, le banc DIT ce que ca coute" {
  # Les mots de passe de ce banc sont des defauts de test, publics dans le README. Ouvrir sans le
  # dire, c'est livrer une porte ouverte a quelqu'un qui croit avoir une boite fermee.
  run env LCARS_BENCH_FAKE=1 bash "$SRC" --no-runner --no-creds --bind 0.0.0.0 --advertise 10.0.0.9
  [[ "$output" == *"OUVERT SUR LE RESEAU"* ]]
  [[ "$output" == *"--bind 127.0.0.1"* ]]
}

@test "un port deja tenu par un AUTRE banc est refuse AVANT de creer quoi que ce soit" {
  # LE DEFAUT MESURE (2026-08-18) : sur un bind joker, docker refuse en nommant l'adresse de
  # l'AUTRE banc — « Bind for 127.0.0.6:2222 failed » sur une machine ou personne n'a tape
  # 127.0.0.6 — et le script mourait en « la boite ne demarre pas », c'est-a-dire en accusant la
  # boite d'un conflit qui ne lui appartient pas.
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
  ! grep -qE '^[[:space:]]*say .*netsh' "$SRC"
  ! grep -qE '^[[:space:]]*say .*portproxy' "$SRC"
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
