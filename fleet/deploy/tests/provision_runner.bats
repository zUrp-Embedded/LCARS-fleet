#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/provision_runner.bats
# AUTHOR: consultant
# STARDATE: 2026-07-30
# STATUS: bats tests for the runner's D6 substrate model (APPLY-ON / CHECK-ON)
#
# D6 (ADR install/compile/release §7) splits two axes the old single `# SUBSTRATE:` header
# conflated: WHERE mutations run (APPLY-ON) vs WHERE the target state must hold (CHECK-ON).
# Consequence under test: on docker, a module built by the image (APPLY-ON: wsl linux,
# CHECK-ON: any) is CHECKED by doctor AND by apply — and its drift is an apply FAILURE
# (nothing on this substrate can converge it), never a silent skip.
#
# Harness: the runner resolves its module dir from its own path, so each test builds a
# sandbox tree (provision + lib + stub modules) in BATS_TEST_TMPDIR and runs the real
# runner as a real process. Stubs log "<name>:<mode>" to RUN_LOG and exit STUB_RC.

setup() {
  SRC="$BATS_TEST_DIRNAME/.."
  SANDBOX="$BATS_TEST_TMPDIR/prov"
  mkdir -p "$SANDBOX/lib" "$SANDBOX/modules.d"
  cp "$SRC/provision" "$SANDBOX/provision"
  # ⚠ `provision-lib.sh` SOURCE `docker-endpoint.sh` : le decor doit porter les DEUX, sinon
  # toute la suite tombe sur un « No such file » dont la cause est cette ligne de setup.
  cp "$SRC/lib/provision-lib.sh" "$SANDBOX/lib/provision-lib.sh"
  cp "$SRC/lib/docker-endpoint.sh" "$SANDBOX/lib/docker-endpoint.sh"
  export RUN_LOG="$BATS_TEST_TMPDIR/run.log"
  : > "$RUN_LOG"
}

# stub <NN-name> <apply-on> <check-on> <needs> [rc-var-name]
stub_module() {
  local name="$1" apply_on="$2" check_on="$3" needs="$4" rcvar="${5:-STUB_RC_UNSET}"
  cat > "$SANDBOX/modules.d/$name.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: $apply_on
# CHECK-ON: $check_on
# NEEDS: $needs
set -euo pipefail
echo "$name:\$1" >> "\$RUN_LOG"
exit "\${$rcvar:-0}"
EOF
}

@test "D6: doctor on docker CHECKS an image-built module (APPLY-ON wsl linux, CHECK-ON any)" {
  stub_module 10-pkgstub "wsl linux" any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  grep -q "10-pkgstub:check" "$RUN_LOG"
}

@test "D6: apply on docker runs CHECK (not apply) for an image-built module" {
  stub_module 60-deploystub "wsl linux" any human
  run "$SANDBOX/provision" apply --substrate docker
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:check" "$RUN_LOG"
  ! grep -q "60-deploystub:apply" "$RUN_LOG"
  [[ "$output" == *"APPLY-ON=wsl linux"* ]]
}

@test "D6: image-built module DRIFT during apply is a FAILURE, not a silent skip" {
  stub_module 60-deploystub "wsl linux" any human STUB_RC_DRIFT
  export STUB_RC_DRIFT=1
  run "$SANDBOX/provision" apply --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"inapplicable"* ]]
  [[ "$output" == *"rebuild"* ]]
}

@test "D6: apply on a matching substrate runs the real apply" {
  stub_module 60-deploystub "wsl linux" any human
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 0 ]
  grep -q "60-deploystub:apply" "$RUN_LOG"
}

@test "D6: module outside CHECK-ON is not selected at all" {
  stub_module 15-toolstub "wsl linux" "wsl linux" human
  stub_module 20-anystub any any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  ! grep -q "15-toolstub" "$RUN_LOG"
  grep -q "20-anystub:check" "$RUN_LOG"
}

@test "D6: missing CHECK-ON header is a build error (fail-loud)" {
  cat > "$SANDBOX/modules.d/10-broken.sh" <<'EOF'
#!/usr/bin/env bash
# APPLY-ON: any
# NEEDS: human
exit 0
EOF
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"CHECK-ON"* ]]
}

@test "D6: APPLY-ON substrate outside CHECK-ON is incoherent (fail-loud)" {
  stub_module 10-incoherent "docker" "wsl" human
  run "$SANDBOX/provision" doctor --substrate wsl
  [ "$status" -eq 1 ]
  [[ "$output" == *"hors de CHECK-ON"* ]]
}

@test "D6: non-root apply is allowed when every NEEDS:root module is check-only here" {
  [ "$(id -u)" -ne 0 ] || skip "must run unprivileged"
  stub_module 60-rootstub "wsl linux" any root
  run "$SANDBOX/provision" apply --substrate docker
  [ "$status" -eq 0 ]
  grep -q "60-rootstub:check" "$RUN_LOG"
}

@test "D6: non-root apply still dies when a NEEDS:root module would really apply" {
  [ "$(id -u)" -ne 0 ] || skip "must run unprivileged"
  stub_module 60-rootstub "wsl linux" any root
  run "$SANDBOX/provision" apply --substrate wsl
  [ "$status" -eq 1 ]
  [[ "$output" == *"exige root"* ]]
}

@test "doctor --porcelain stays machine-readable across the D6 model" {
  stub_module 10-okstub any any human
  stub_module 60-driftstub "wsl linux" any human STUB_RC_DRIFT
  export STUB_RC_DRIFT=1
  run "$SANDBOX/provision" doctor --substrate docker --porcelain
  [ "$status" -eq 1 ]
  [[ "$output" == *"10-okstub=OK"* ]]
  [[ "$output" == *"60-driftstub=DRIFT"* ]]
}

@test "list shows both axes" {
  stub_module 10-pkgstub "wsl linux" any root
  run "$SANDBOX/provision" list --substrate docker
  [ "$status" -eq 0 ]
  [[ "$output" == *"APPLY-ON=wsl linux"* ]]
  [[ "$output" == *"CHECK-ON=any"* ]]
}

# 6-101 — LE COMPTEUR DE DRIFT N'ETAIT PAS LU, ET LE RESUME MENTAIT DEUX FOIS. Un module dont
# l'`apply` constate une non-convergence (`p_drift`) puis rend son verdict sortait **0** : le runner
# le comptait « convergé », et sa ligne de bilan affichait « drift: 0 » alors qu'une ligne DRIFT
# venait d'etre imprimee.
#
# ⚠ CE N'EST PAS LE SITE QUE LA FICHE NOMME. `00-preflight` termine par `verdict_check`, qui sort 1
# sur drift, et le runner mappe tout non-zero d'un `apply:apply` en echec — ce chemin etait deja
# juste, MESURE. Le defaut vit un cran a cote : dans les modules qui rendent un verdict d'APPLY,
# c'est-a-dire `50-forge` et `55-deck-oidc`.

# Un module qui utilise la VRAIE lib (p_drift/p_ok + les verdicts), pas un `exit` code en dur :
# c'est la chaine module→lib→runner qui est sous test, pas une constante.
#
# ⚠ CHAQUE VERBE REND SON PROPRE VERDICT, et la premiere version de cette fixture appelait
# `verdict_apply` dans les deux — ce qu'aucun module reel ne fait. Le temoin doctor rougissait alors
# pour une raison de MISE EN SCENE : il mesurait une fixture, pas le runner.
lib_module() {
  local name="$1" body="$2"
  cat > "$SANDBOX/modules.d/$name.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
set -euo pipefail
. "\${PROVISION_LIB:?}"
probe() { $body; }
echo "$name:\$1" >> "\$RUN_LOG"
case "\$1" in
  check) probe; verdict_check ;;
  apply) probe; verdict_apply ;;
esac
EOF
}

@test "6-101: un DRIFT dans l'apply rend 2 — plus jamais « tout convergé »" {
  lib_module 50-forgestub 'p_drift "adhesion org non convergee"'
  run "$SANDBOX/provision" apply --substrate docker

  [ "$status" -eq 2 ]
  [[ "$output" == *"drift: 1"* ]]
  [[ "$output" == *"ÉTAT-CIBLE N'EST PAS TENU"* ]]
}

@test "6-101: le bilan CESSE de compter ce module comme convergé" {
  # La moitie la plus traitre : le code retour etait faux ET la ligne de bilan aussi. Un operateur
  # qui lisait « conformes/convergés: 1 · drift: 0 » n'avait aucune raison d'aller chercher la ligne
  # DRIFT au-dessus.
  lib_module 50-forgestub 'p_drift "adhesion org non convergee"'
  run "$SANDBOX/provision" apply --substrate docker

  [[ "$output" == *"conformes/convergés: 0"* ]]
  [[ "$output" != *"drift: 0"* ]]
}

@test "6-101: le drift residuel N'EST PAS un echec — 2 et 1 sont deux mots" {
  # Confondre les deux serait l'autre facon de mentir : « j'ai casse » et « je n'ai pas pu
  # converger » demandent des gestes opposes de l'operateur.
  lib_module 50-forgestub 'p_drift "forge injoignable"'
  run "$SANDBOX/provision" apply --substrate docker

  [ "$status" -ne 1 ]
  [[ "$output" == *"échecs: 0"* ]]
}

@test "6-101: un p_fail rend toujours 1, le drift ne l'ecrase pas" {
  lib_module 50-forgestub 'p_fail "chown refuse"; p_drift "et un drift par-dessus"'
  run "$SANDBOX/provision" apply --substrate docker

  [ "$status" -eq 1 ]
  [[ "$output" == *"échecs: 1"* ]]
}

@test "6-101: TEMOIN — un apply reellement convergé rend toujours 0" {
  # Sans lui, un runner qui rendrait 2 en toutes circonstances passerait les tests ci-dessus, et
  # chaque boot de conteneur annoncerait un drift qui n'existe pas.
  lib_module 20-okstub 'p_ok "converge"'
  run "$SANDBOX/provision" apply --substrate docker

  [ "$status" -eq 0 ]
  [[ "$output" == *"conformes/convergés: 1"* ]]
  [[ "$output" == *"drift: 0"* ]]
}

@test "6-101: TEMOIN — le doctor garde ses codes (0 conforme, 1 drift)" {
  # Le verbe doctor n'est pas touche : son 1 signifie drift depuis toujours et des lecteurs en
  # dependent. Le nouveau code ne vit que dans apply.
  lib_module 20-okstub 'p_ok "conforme"'
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]

  rm -f "$SANDBOX/modules.d"/*.sh
  lib_module 50-forgestub 'p_drift "pas conforme"'
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 1 ]
}

# ─── UN ECHEC COMPTE DOIT ETRE UN ECHEC NOMME ───────────────────────────────────────────────────
#
# Mesure du 2026-08-18, banc lcars-l8 : `provision doctor` rendait « modules: 11 · drift: 4 ·
# échecs: 1 » sans une seule ligne pour dire QUEL module. Le coupable etait `70-human`, tue par
# `pipefail` sur un `sed` d'un `fleet_v2.env` absent — donc mort AVANT `verdict_check`, sans rien
# imprimer. Cote apply c'etait pire : `set -e` rendait 2, et 2 y signifie « appliqué, drift
# résiduel » — le bilan disait « rien n'est cassé » d'un module qui n'avait pas fini de tourner.
#
# DEUX FILETS, ET ILS NE SE RECOUVRENT PAS. Le module qui a source la lib porte une garde de sortie
# et rend 3, un code qui n'appartient qu'a ce cas. Celui qui meurt AVANT d'avoir source la lib n'a
# pas de garde : c'est le runner qui le nomme, sur son rc brut.

mort_module() { # mort_module <NN-nom> <source-la-lib: 0|1>
  { echo '#!/usr/bin/env bash'
    echo '# APPLY-ON: any'
    echo '# CHECK-ON: any'
    echo '# NEEDS: human'
    echo 'set -euo pipefail'
    [[ "$2" -eq 1 ]] && echo '. "${PROVISION_LIB:?}"'
    # meurt exactement comme 70-human : pipeline en echec sous pipefail, aucune sortie
    echo 'x="$(sed -n '"'"'s/^X=//p'"'"' /inexistant-par-construction 2>/dev/null | tail -n1)"'
    echo 'echo "jamais atteint: $x"'
  } > "$SANDBOX/modules.d/$1.sh"
}

@test "doctor : un module qui MEURT sans verdict est NOMME, pas seulement compte" {
  mort_module 90-mort 1
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERREUR 90-mort"* ]]
  [[ "$output" == *"MORT avant de rendre son verdict"* ]]
}

@test "apply : un module mort n'est PAS un drift residuel — le message rassurant serait faux" {
  mort_module 91-mort 1
  run "$SANDBOX/provision" apply --substrate docker
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERREUR 91-mort"* ]]
  [[ "$output" != *"Rien n'est cassé"* ]]
}

@test "mort AVANT de sourcer la lib : sans garde, c'est le RUNNER qui nomme" {
  mort_module 93-tot 0
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 2 ]
  [[ "$output" == *"ERREUR 93-tot"* ]]
}

@test "TEMOIN : un module SAIN ne declenche aucune ligne ERREUR" {
  stub_module 92-sain any any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  [[ "$output" != *"ERREUR"* ]]
}

@test "la garde de sortie ne DESCEND pas : un petit-fils qui source la lib n'est pas un module" {
  # ⚠ LE DEFAUT QUE CE TEMOIN GARDE EST CELUI QU'A CREE LA GARDE ELLE-MEME. `PROVISION_RUN` arrive
  # par l'ENVIRONNEMENT, donc il descendait a tout ce que le module lance. `bench-up.sh` source
  # cette lib et ne rend aucun verdict : il sortait 3 avec un « MORT avant de rendre son verdict »
  # mensonger, apres un `exit 0` parfaitement propre.
  #
  # Mesure du 2026-08-18 : 12 temoins de bench_up_verdict.bats rouges pendant `mix gate`, verts
  # joues a la main, et toute la difference tenait a ce mot dans l'environnement. Un garde pose
  # pour rendre les echecs bruyants fabriquait des echecs a partir de succes, un etage plus bas.
  cat > "$SANDBOX/modules.d/94-petitfils.sh" <<EOF
#!/usr/bin/env bash
# APPLY-ON: any
# CHECK-ON: any
# NEEDS: human
set -euo pipefail
. "\$PROVISION_LIB"
rc=0
bash -c '. "\$PROVISION_LIB"; echo PETIT-FILS-OK; exit 0' || rc=\$?
echo "PETIT-FILS-RC=\$rc"
p_ok "le module, lui, rend bien son verdict"
verdict_apply
EOF
  run "$SANDBOX/provision" apply --substrate docker
  [ "$status" -eq 0 ]
  [[ "$output" == *"PETIT-FILS-OK"* ]]
  [[ "$output" == *"PETIT-FILS-RC=0"* ]]
  [[ "$output" != *"MORT avant de rendre son verdict"* ]]
}

# ─── LA CIBLE EST WSL2 + DOCKER, ET LE REFUS EST UNE GARDE, PAS UN GOUT ─────────────────────────
#
# ⚖ ARBITRAGE USER 2026-08-18 : « jamais on s'installe sur le poste de l'user directement » et
# « tu fais le script pour installer sur WSL, avec docker dispo, et tu arretes de vouloir gerer
# toutes les configs de la terre ». Ce provisionnement possede /etc/wsl.conf, cree un groupe
# systeme, pose /local et /home/private — et n'a aucun desinstalleur.

@test "cible : un substrat linux est REFUSE, et le refus nomme la cible et l'echappatoire" {
  run env PROV_SUBSTRATE=linux PROVISION_MODULE=00-preflight \
      PROVISION_LIB="$SANDBOX/lib/provision-lib.sh" \
      bash "$BATS_TEST_DIRNAME/../modules.d/00-preflight.sh" check
  [[ "$output" == *"HORS CIBLE"* ]]
  [[ "$output" == *"WSL2"* ]]
  [[ "$output" == *"LCARS_ALLOW_ANY_HOST"* ]]
}

@test "cible : l'echappatoire est REELLE — nommee, elle degrade en avertissement" {
  run env PROV_SUBSTRATE=linux LCARS_ALLOW_ANY_HOST=1 PROVISION_MODULE=00-preflight \
      PROVISION_LIB="$SANDBOX/lib/provision-lib.sh" \
      bash "$BATS_TEST_DIRNAME/../modules.d/00-preflight.sh" check
  [[ "$output" != *"HORS CIBLE"* ]]
  [[ "$output" == *"hors cible"* ]]
}

@test "cible : sous WSL, docker qui ne repond pas est un REFUS — pas une derive" {
  # ⚖ ARBITRAGE USER 2026-08-18 : « ça, on refuse. docker-desktop c'est un clic. »
  # Une DERIVE dit « pas tenu, et ce rail peut le tenir ». Ici il ne peut pas : la forge est un
  # conteneur, il n'en existe aucune autre forme, donc 50-forge et 55-deck-oidc ne convergeront
  # JAMAIS. Installer un runtime qui ne peut pas travailler, c'est livrer un objet qui a l'air pose.
  #
  # ⚠ CE TEMOIN EPINGLAIT LE MOT « docker absent », ET CE MOT ETAIT LE DEFAUT. La sonde testait
  # `command -v docker` : sa presence ne prouve pas que le daemon repond (Docker Desktop eteint),
  # et son ABSENCE ne prouve pas qu'il manque — sur WSL la CLI et les sockets vivent dans le
  # montage `/mnt/wsl/docker-desktop`, present pour toute distro. Mesure du 2026-08-19 : aucun
  # binaire dans le PATH, et le daemon repond. Le temoin epingle donc ce qui est CONTRACTUEL — un
  # refus, et la consequence nommee — jamais le vocabulaire d'une cause supposee.
  #
  # DOCKER_HOST vise une socket qui n'existe pas : c'est le seul moyen de fabriquer « rien ne
  # repond » sur une machine qui, elle, a docker. Vider le PATH ne suffit plus, et c'est le sujet.
  # ⚠ LE TEMOIN FOURNIT LA CLI QU'IL MESURE, IL NE L'HERITE PAS DE LA MACHINE. Sans elle, la sonde
  # rend « aucune CLI docker » — un refus JUSTE, mais un autre que celui qu'on epingle ici. Mesure :
  # ce temoin passait sur trois machines et tombait dans le conteneur de CI, qui n'a pas de docker.
  # Un test qui herite de son environnement mesure l'environnement.
  local cli="$BATS_TEST_TMPDIR/bin"; mkdir -p "$cli"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$cli/docker"; chmod 0755 "$cli/docker"
  run env PATH="$cli:/usr/bin:/bin" DOCKER_HOST="unix://$BATS_TEST_TMPDIR/absent.sock" \
      PROV_SUBSTRATE=wsl PROVISION_MODULE=00-preflight \
      PROVISION_LIB="$SANDBOX/lib/provision-lib.sh" \
      bash "$BATS_TEST_DIRNAME/../modules.d/00-preflight.sh" check
  # rc 2 = erreur de sonde (p_fail), pas 1 = derive
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL"* ]]
  # ⚠ FRAGMENT SANS ACCENT, DELIBEREMENT : la sortie de ce rail est du francais accentue
  # (« aucun daemon ne repond » s'y ecrit avec un e accent aigu), et un temoin qui recopie
  # l'accent epingle l'encodage en plus du contrat. « aucun daemon » couvre les deux branches de
  # `docker_endpoint` — DOCKER_HOST pose et mort, et aucune socket qui reponde.
  [[ "$output" == *"aucun daemon"* ]]
  [[ "$output" == *"JAMAIS"* ]]
  [[ "$output" != *"DRIFT 00-preflight: docker"* ]]
}

@test "cible : le refus ne dit JAMAIS « installe docker » — le montage prouverait le contraire" {
  # Le message d'un refus enseigne le geste. « docker absent, installe-le » envoyait installer ce
  # qui etait deja la : sur WSL le donne est un montage, pas un binaire. Un refus qui dicte le
  # mauvais geste coute une enquete a celui qui le suit.
  run env PATH="/usr/bin:/bin" DOCKER_HOST="unix://$BATS_TEST_TMPDIR/absent.sock" \
      PROV_SUBSTRATE=wsl PROVISION_MODULE=00-preflight \
      PROVISION_LIB="$SANDBOX/lib/provision-lib.sh" \
      bash "$BATS_TEST_DIRNAME/../modules.d/00-preflight.sh" check
  [[ "$output" != *"installe docker"* ]]
  [[ "$output" != *"Installe Docker"* ]]
  [[ "$output" != *"intégration WSL activée"* ]]
}

@test "48-forge-host : sans daemon, un REFUS — le meme mot que le preflight" {
  # ⚖ USER : « ça, on refuse ». Deux modules qui parlent du meme manque doivent le nommer pareil ;
  # une derive ici et un refus la-bas, et le lecteur ne sait plus lequel des deux dit vrai. Les
  # deux passent maintenant par `docker_endpoint`, donc la phrase VIENT du meme endroit — ce n'est
  # plus une convention entre deux auteurs, c'est un seul texte a un seul site.
  # Meme raison qu'au temoin precedent : la CLI est FOURNIE, pas heritee.
  local cli="$BATS_TEST_TMPDIR/bin"; mkdir -p "$cli"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$cli/docker"; chmod 0755 "$cli/docker"
  run env PATH="$cli:/usr/bin:/bin" DOCKER_HOST="unix://$BATS_TEST_TMPDIR/absent.sock" \
      PROV_SUBSTRATE=wsl PROVISION_MODULE=48-forge-host \
      PROVISION_LIB="$SANDBOX/lib/provision-lib.sh" \
      bash "$BATS_TEST_DIRNAME/../modules.d/48-forge-host.sh" check
  [ "$status" -eq 2 ]
  [[ "$output" == *"FAIL"* ]]
  # ⚠ FRAGMENT SANS ACCENT, DELIBEREMENT : la sortie de ce rail est du francais accentue
  # (« aucun daemon ne repond » s'y ecrit avec un e accent aigu), et un temoin qui recopie
  # l'accent epingle l'encodage en plus du contrat. « aucun daemon » couvre les deux branches de
  # `docker_endpoint` — DOCKER_HOST pose et mort, et aucune socket qui reponde.
  [[ "$output" == *"aucun daemon"* ]]
  [[ "$output" == *"aucune autre forme"* ]]
}

@test "48-forge-host : il tourne AVANT 50-forge — l'ordre est le prefixe, et il porte le sens" {
  # 50-forge SONDE une forge et minte contre elle ; 48 la fait exister. L'inverse rendrait la
  # premiere passe systematiquement en derive sur une machine neuve.
  ls "$BATS_TEST_DIRNAME/../modules.d/" | grep -E "^(48-forge-host|50-forge)\.sh$" | sort > "$BATS_TEST_TMPDIR/ordre"
  [ "$(head -n1 "$BATS_TEST_TMPDIR/ordre")" = "48-forge-host.sh" ]
}

@test "48-forge-host : la structure passe par un run TRANSITOIRE, jamais par une boite vivante" {
  # ⚖ « reconstruire et relancer un LCARS en conteneur pour tester celui qu'on vient d'installer
  # nativement » — c'est precisement ce que ce module evite. Il monte la forge et joue la recette
  # par `docker run --rm`, possible parce que le tfstate est jetable par construction.
  MOD="$BATS_TEST_DIRNAME/../modules.d/48-forge-host.sh"
  grep -q -- "forge-apply" "$MOD"
  ! grep -q -- "compose .*create lcars\|exec .*lcars-1" "$MOD"
  # et la porte existe cote image
  grep -q '"forge-apply"' "$BATS_TEST_DIRNAME/../docker/entrypoint.sh"
}

@test "48-forge-host : AUCUN bind d'un chemin d'hote — le daemon peut vivre ailleurs" {
  # ⚠ MESURE DU 2026-08-18, Docker Desktop : `-v /home/private:/home/private` a donne au conteneur
  # un dossier VIDE, et le geste a repondu « la boite ne detient pas ce qu'il faut » en nommant des
  # fichiers qui existaient a trente centimetres. Le daemon vit dans une autre VM : un chemin de
  # cette distro lui est invisible, et il cree un repertoire vide a la place, EN SILENCE.
  # `bench-runner.sh` porte deja cet avertissement — d'ou ce temoin, pour qu'il ne se reperde pas.
  MOD="$BATS_TEST_DIRNAME/../modules.d/48-forge-host.sh"
  # aucun `-v <chemin absolu d'hote>:` : seuls les volumes NOMMES traversent
  ! grep -qE '\-v "\$PROV_TOKENS_DIR|\-v "?/[a-z]' "$MOD"
  # la forme qui traverse : create -> cp -> start
  grep -q -- "d create --network" "$MOD"
  grep -q -- "d cp " "$MOD"
  grep -q -- "d start -a" "$MOD"
  grep -q -- "LCARS_PRIVATE_DIR=/authority" "$MOD"
}

@test "48-forge-host : la forge ANNONCE son adresse — les modules sont des processus" {
  # Mesure du 2026-08-18 : une install qui venait de monter une forge parfaitement vivante rendait
  # « FORGE_BASE_URL/PROV_FORGE_URL non pose » sur 50-forge ET 55-deck-oidc. `48` ne peut rien
  # exporter vers `50` : ce sont deux shells. Il ecrit donc l'adresse, et la lib la relit.
  MOD="$BATS_TEST_DIRNAME/../modules.d/48-forge-host.sh"
  LIB="$BATS_TEST_DIRNAME/../lib/provision-lib.sh"
  grep -q 'write_atomic "\$PROV_TOKENS_DIR/forge.url"' "$MOD"
  grep -q 'PROV_TOKENS_DIR/forge.url' "$LIB"
  # 0644 : c'est une adresse, pas un secret
  grep -q 'forge.url" 0644' "$MOD"
}

@test "la lecture de forge.url est un REPLI — l'environnement garde la priorite" {
  # En conteneur le fichier n'existe pas et l'environnement du compose gagne. Et s'il existe, il ne
  # doit jamais ecraser un FORGE_BASE_URL pose explicitement.
  d="$BATS_TEST_TMPDIR/tok"; mkdir -p "$d"; echo "http://depuis-le-fichier:3000" > "$d/forge.url"
  run bash -c "set -euo pipefail; export PROV_TOKENS_DIR='$d' FORGE_BASE_URL=http://depuis-l-env:9999
    source '$BATS_TEST_DIRNAME/../lib/provision-lib.sh'; echo \"\$PROV_FORGE_URL\""
  [ "$output" = "http://depuis-l-env:9999" ]
  run bash -c "set -euo pipefail; export PROV_TOKENS_DIR='$d'
    source '$BATS_TEST_DIRNAME/../lib/provision-lib.sh'; echo \"\$PROV_FORGE_URL\""
  [ "$output" = "http://depuis-le-fichier:3000" ]
}

@test "forge.url : une chaine VIDE explicite n'est pas « non pose » — le piege de \`:=\`" {
  # ⚠ MESURE DU 2026-08-18. `48-forge-host` a ouvert une SECONDE porte vers `PROV_FORGE_URL` : le
  # fichier. L'idiome `:=` de la lib traite une chaine vide comme « non pose », donc un appelant qui
  # dit « pas de forge » par `PROV_FORGE_URL=""` se voyait rendre celle de la machine. Un temoin est
  # passe au rouge sur un poste ou la forge venait d'etre montee, vert partout ailleurs, et toute la
  # difference tenait a l'existence d'un fichier.
  #
  # Ce temoin ne corrige pas `:=` — il l'EPINGLE, pour que le prochain qui ajoute une source sache
  # ce qu'elle ecrase. La parade est cote appelant : poser son propre PROV_TOKENS_DIR.
  d="$BATS_TEST_TMPDIR/tk"; mkdir -p "$d"; echo "http://la-forge-de-la-machine:3000" > "$d/forge.url"
  run bash -c "set -euo pipefail; export PROV_TOKENS_DIR='$d' PROV_FORGE_URL=''
    source '$BATS_TEST_DIRNAME/../lib/provision-lib.sh'; echo \"[\$PROV_FORGE_URL]\""
  [ "$output" = "[http://la-forge-de-la-machine:3000]" ]
  # la parade, elle, tient : un PROV_TOKENS_DIR sans fichier rend bien le vide
  e="$BATS_TEST_TMPDIR/vide"; mkdir -p "$e"
  run bash -c "set -euo pipefail; export PROV_TOKENS_DIR='$e' PROV_FORGE_URL=''
    source '$BATS_TEST_DIRNAME/../lib/provision-lib.sh'; echo \"[\$PROV_FORGE_URL]\""
  [ "$output" = "[]" ]
}
