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
  # ⚠ LE DECOR POSSEDE L'ENVIRONNEMENT DE PROVISIONNEMENT, PAS SEULEMENT SES FICHIERS. Ces temoins
  # jugent ce que le runner fait d'un environnement DONNE ; s'ils heritent de celui de l'appelant,
  # ils jugent l'appelant.
  #
  # MESURE DU 2026-08-20, ET LE COUPABLE ETAIT LE GESTE DE REVISION LUI-MEME. `lcars-revise` lance
  # l'apply avec `LCARS_ALLOW_ANY_HOST=1 PROV_FORGE_URL=… FORGE_BASE_URL=…` — legitime, c'est ce
  # qu'un poste hors cible doit poser. Le gate tourne DANS cet apply, donc les trois variables
  # descendaient jusqu'ici : le temoin « un substrat linux est REFUSE » voyait l'echappatoire posee
  # et lisait un avertissement au lieu d'un refus, et les deux temoins de `forge.url` voyaient une
  # URL la ou ils en attendaient l'absence. Verifie dans les deux sens : les trois passent sans les
  # variables, les trois tombent avec.
  #
  # On efface donc TOUTE la famille, pas les trois noms mesures : le prochain drapeau que le geste
  # de revision aura besoin de poser ne doit pas rouvrir ce trou en silence.
  local _v
  while read -r _v; do unset "$_v" 2>/dev/null || true; done \
    < <(compgen -v | grep -E '^(LCARS_|PROV_|FORGE_)' || true)

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

  # ⚠ LE DECOR POSSEDE SON DOSSIER RUNTIME. `provision` prend un verrou avant tout apply, et
  # `prov_lock_path` le veut dans `${XDG_RUNTIME_DIR:-/run/user/$uid}/lcars` pour un appelant
  # non-root — REFUS si le parent manque (6-130 : pas de repli dans un dossier partage). Un compte
  # de service n'a PAS de session logind : mesure du 2026-08-20, `/run/user/1001` n'existe par
  # aucune voie sur le poste natif. Sans cette ligne ces temoins ne mesurent pas la selection des
  # modules, ils mesurent la session de qui les lance — et ils rougissent tous ensemble sur
  # « verrou: emplacement sur indisponible ».
  export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$XDG_RUNTIME_DIR"
  chmod 0700 "$XDG_RUNTIME_DIR"
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

# ─── LE SECOND PASSAGE : L'ETAT PER-HUMAIN DE L'HUMAIN DE FLEET ─────────────────────────────────
# `--human` designe l'OPERATEUR (SUDO_USER), qui sur un poste est presque toujours l'uid 1000 que
# GUARD B reserve au siege. `22-fleet-human` cree l'humain de fleet ; sans ce passage, son
# `~/.lcars`, son `~/pods` et son `fleet_v2.env` n'existeraient jamais, et `fleet_v2 start`
# echouerait sous lui pour une raison sans rapport avec ce qu'on vient d'installer.

@test "second passage: les modules per-humain sont REJOUES pour l'humain de fleet" {
  lib_module 50-perhuman 'echo "human=$PROV_HUMAN" >> "$RUN_LOG"; p_ok "converge"'
  # Le siege est ecarte de l'uid courant pour que `is_fleet_human` accepte le compte qui joue les
  # tests — sinon ce temoin mesurerait la composition de la machine au lieu du mecanisme.
  run env LCARS_SYSADMIN_UID=0 PROV_FLEET_HUMAN="$(id -un)" \
    "$SANDBOX/provision" apply --substrate linux --human root

  [ "$status" -eq 0 ]
  run grep -c "^human=" "$RUN_LOG"
  [ "$output" = "2" ]
  grep -qx "human=root" "$RUN_LOG"
  grep -qx "human=$(id -un)" "$RUN_LOG"
}

@test "second passage: l'humain de fleet EGAL a l'operateur ne rejoue rien" {
  # Sans ce pendant, un correctif qui rejouerait TOUJOURS passerait le temoin ci-dessus, et chaque
  # apply de boite doublerait ses modules per-humain — deux fois le travail, et un bilan qui compte
  # deux fois les memes modules.
  lib_module 50-perhuman 'echo "human=$PROV_HUMAN" >> "$RUN_LOG"; p_ok "converge"'
  run env LCARS_SYSADMIN_UID=0 PROV_FLEET_HUMAN=root \
    "$SANDBOX/provision" apply --substrate linux --human root

  [ "$status" -eq 0 ]
  run grep -c "^human=" "$RUN_LOG"
  [ "$output" = "1" ]
}

@test "second passage: JAMAIS sur docker — c'est le convergeur qui y possede les humains" {
  # Dans la boite, `human-converger.sh` materialise N humains depuis la team `humans` de la forge et
  # rejoue leurs modules. Un second passage ici doublerait son travail et poserait l'etat d'un
  # humain que la forge n'a peut-etre pas declare.
  lib_module 50-perhuman 'echo "human=$PROV_HUMAN" >> "$RUN_LOG"; p_ok "converge"'
  run env LCARS_SYSADMIN_UID=0 PROV_FLEET_HUMAN="$(id -un)" \
    "$SANDBOX/provision" apply --substrate docker --human root

  [ "$status" -eq 0 ]
  run grep -c "^human=" "$RUN_LOG"
  [ "$output" = "1" ]
}

@test "second passage: un humain de fleet INEXISTANT ne declenche rien, et ne casse rien" {
  # `22-fleet-human` derive quand `useradd` echoue : l'apply continue, et ce passage doit alors etre
  # inerte plutot que de jouer des modules pour un compte qui n'existe pas.
  lib_module 50-perhuman 'echo "human=$PROV_HUMAN" >> "$RUN_LOG"; p_ok "converge"'
  run env LCARS_SYSADMIN_UID=0 PROV_FLEET_HUMAN="n-existe-pas-$$" \
    "$SANDBOX/provision" apply --substrate linux --human root

  [ "$status" -eq 0 ]
  run grep -c "^human=" "$RUN_LOG"
  [ "$output" = "1" ]
}

@test "le RESUME ne dit jamais « rien n'est cassé » quand quelque chose est casse" {
  # LE CODE DE RETOUR ETAIT DEJA JUSTE, ET C'EST CE QUI REND LA FAUTE CHERE : rien n'echouait,
  # aucun temoin ne rougissait, et seul un humain qui lit la FIN se faisait une idee fausse de
  # l'etat de sa machine. La phrase rassurante sortait des qu'il y avait du drift, echecs compris.
  #
  # Mesure du 2026-08-21, install a froid sur machine dediee : « conformes/convergés: 8 · drift: 4
  # · échecs: 3 » suivi de « APPLIQUÉ, MAIS L'ÉTAT-CIBLE N'EST PAS TENU … Rien n'est cassé ». La
  # derniere ligne lue est celle qui reste.
  lib_module 40-failstub  'p_fail "quelque chose est casse"'
  lib_module 50-driftstub 'p_drift "et un geste manque"'
  run "$SANDBOX/provision" apply --substrate docker

  [ "$status" -eq 1 ]
  [[ "$output" == *"échecs: 1"* ]]
  [[ "$output" == *"drift: 1"* ]]
  [[ "$output" == *"EN ÉCHEC"* ]]
  [[ "$output" != *"Rien n'est cassé"* ]]
}

@test "TEMOIN — sans echec, la phrase rassurante revient : c'est bien le drift qu'elle decrit" {
  # Sans ce pendant, un correctif qui supprimerait la phrase en toutes circonstances passerait le
  # temoin ci-dessus (P-40), et un drift pur perdrait le seul message qui dit ce qu'il faut faire.
  lib_module 50-driftstub 'p_drift "un geste manque"'
  run "$SANDBOX/provision" apply --substrate docker

  [ "$status" -eq 2 ]
  [[ "$output" == *"Rien n'est cassé"* ]]
  [[ "$output" != *"EN ÉCHEC"* ]]
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

# ─── UN VERDICT SANS SON ORIGINE NE SE COMPARE A RIEN ───────────────────────────────────────────
#
# ⚖ USER 2026-08-21 : « le rail natif se met a jour depuis un clone git, et rien ne dit a quel commit
# ce clone est. Un provision apply sur un checkout en retard reinstalle silencieusement l'etat
# d'avant. Aucun verdict ne le voit. »
#
# Chaque module converge vers ce que dit SA source : « conforme » ne signifie donc jamais plus que
# « conforme a l'arbre que j'ai sous la main ». La seule chose qui manquait etait de DIRE lequel.

@test "le recap NOMME la revision de la source" {
  stub_module 20-anystub any any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  [[ "$output" == *"source "* ]]
}

@test "hors checkout git, la revision se lit dans le TAMPON — c'est ce qui rend une COPIE nommable" {
  # `/opt/lcars/fleet` est un `cp -a` : git n'y repond rien. Sans ce repli, un `provision` lance
  # depuis la copie — le cas du convergeur — ne pourrait pas nommer sa propre origine.
  # Le tampon se pose la ou `repo_root()` le cherchera : trois crans au-dessus de `lib/`, ce qui,
  # pour ce decor, tombe au-dessus du tmpdir du test. On calcule le chemin comme la lib le fait,
  # plutot que de le supposer — c'est justement l'ecart qui rendrait le repli muet en production.
  local root; root="$(readlink -f "$SANDBOX/lib/../../..")"
  echo "abcd1234" > "$root/.source-revision"
  stub_module 20-anystub any any human
  run "$SANDBOX/provision" doctor --substrate docker
  rm -f "$root/.source-revision"
  [ "$status" -eq 0 ]
  [[ "$output" == *"source abcd1234"* ]]
}

@test "ni git ni tampon : la revision est « inconnue », jamais devinee" {
  stub_module 20-anystub any any human
  run "$SANDBOX/provision" doctor --substrate docker
  [ "$status" -eq 0 ]
  [[ "$output" == *"source inconnue"* ]]
}
