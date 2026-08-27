#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/box_project.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-07
# STATUS: bats tests for fleet/deploy/box — a project NAME is not proof you are talking about the same box
#
# WHY THIS EXISTS. The box rail targeted the compose project `lcars` as a hardcoded constant. Compose
# will happily apply a file to a project it never created: it computes the desired state from THAT
# file and recreates, republishes ports, drops what is absent — with no error, because from its own
# point of view nothing is wrong. The name is enough to address the project; it is not enough to
# prove both parties mean the same object.
#
# Measured on this workstation on 2026-08-07: `lcars` was a 47-hour-old working box created from
# `fleet/provisioning_v2/docker/docker-compose.install.yml` — a path DELETED by the 2026-08-04 move.
# `box down` stopped it, `box reset` took its /home volume, and neither said a word.
# That is the dominant defect family here: a defect that breaks gets killed by whoever meets it; a
# defect that returns GREEN survives indefinitely.
#
# WHAT IS PINNED. The guard reads the container's own `com.docker.compose.project.config_files`
# label — the list of files that actually created it — instead of trusting the name. What matters is
# both directions: it must REFUSE a foreign project, and it must NOT refuse an empty one (there is
# nothing to confuse, and `up` is entitled to create it).
#
# The last test has nothing to do with projects and everything to do with the same family: the help
# text used to be extracted by line numbers (`sed -n '6,35p'`), so inserting one header line
# truncated it silently. An amputated help never reports itself either.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SRC="$REPO/fleet/deploy/box"
  CF="$REPO/fleet/deploy/docker/docker-compose.yml"

  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"

  # A docker daemon seen through a keyhole. Two env knobs drive it:
  #   STUB_IDS           what `ps -aq --filter label=…project=<p>` returns ("" = project has no
  #                      container at all, which is the case the guard must let through)
  #   STUB_CONFIG_FILES  what `inspect --format` prints, i.e. the comma-separated list of compose
  #                      files that created those containers
  cat > "$BINDIR/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1 \$2" in
  "compose version") exit 0 ;;
  "ps -aq")          printf '%s' "\${STUB_IDS:-}"; [[ -n "\${STUB_IDS:-}" ]] && echo; exit 0 ;;
  "inspect \${STUB_IDS:-__none__}") echo "\${STUB_CONFIG_FILES:-}"; exit 0 ;;
esac
# Le verdict de provisionnement, lu par 'up' DANS la boite. STUB_PROV_RC vide = le fichier n'est
# pas encore la, ce qui est l'etat normal pendant tout le provisionnement.
# ⚠ PAS D'ACCENTS GRAVES ICI : ce heredoc n'est PAS quote, donc bash y fait de la SUBSTITUTION DE
# COMMANDE — un mot entre accents graves est EXECUTE a l'ecriture du fichier, meme dans un
# commentaire. Ces deux-la imprimaient « up: command not found » et « STUB_PROV_RC: command not
# found » a chaque setup, un bruit que personne ne lisait parce que les tests passaient. Meme
# cicatrice que 042f351d6, dans un autre fichier.
if [[ "\$*" == *"cat /run/lcars-provision.rc"* ]]; then
  [[ -n "\${STUB_PROV_RC:-}" ]] || exit 1
  printf '%s\n' "\${STUB_PROV_RC}"
  exit 0
fi
exit 0
EOF
  chmod 0755 "$BINDIR/docker"

  export PATH="$BINDIR:$PATH"
  unset LCARS_PROJECT STUB_IDS STUB_CONFIG_FILES STUB_PROV_RC

  # ⚠ SANS CETTE LIGNE, CES SEIZE TEMOINS DEPENDENT D'UNE SOCKET SUR LA MACHINE QUI LES JOUE.
  # Le delegue sonde desormais un ENDPOINT QUI REPOND, pas un binaire : sans `DOCKER_HOST`, la
  # sonde parcourt /var/run/docker.sock, /run/docker-fleet.sock et la socket du montage WSL. Ici
  # elle en trouvait une VRAIE et passait — donc verts sur ce poste, et rouges d'un bloc sur une
  # machine sans daemon, pour une raison qui n'a rien a voir avec ce qu'ils mesurent. En la posant,
  # la sonde prend la branche « DOCKER_HOST est pose » et interroge LA DOUBLURE, qui repond 0.
  export DOCKER_HOST="unix:///dev/null"
  # ⚠ ET LA DOUBLURE SE DÉCLARE, elle ne se glisse plus dans le PATH en espérant être prise. Sur
  # WSL la sonde préfère DÉLIBÉRÉMENT la CLI du montage Docker Desktop : il n'y a pas de « binaire
  # docker » dans une distro, seulement un montage, et un `docker` trouvé dans un PATH y est une
  # copie que quelqu'un a posée. Un test qui compte sur l'ordre du PATH mesurait donc la machine.
  # `PROV_DOCKER_BIN` est le choix de l'appelant, et il l'emporte sur tout — c'est la couture.
  export PROV_DOCKER_BIN="$BINDIR/docker"
}

# A project holding one container, created from the files given as arguments.
seed_project() {
  export STUB_IDS="c0ffee"
  export STUB_CONFIG_FILES="$1"
}

@test "an EMPTY project is not refused — up is entitled to create it" {
  # STUB_IDS unset: `ps -aq` returns nothing, so there is no container whose provenance to read.
  run bash "$SRC" -p lcars-jamais-cree down

  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUS"* ]]
  # It really went through to compose rather than short-circuiting.
  grep -q -- "-p lcars-jamais-cree down" "$CALLS"
}

@test "a project created by THIS compose file passes the guard" {
  seed_project "$CF"

  run bash "$SRC" down

  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUS"* ]]
  grep -q -- "-p lcars down" "$CALLS"
}

@test "a project created by ANOTHER compose file is refused, and the refusal names both" {
  # The real case: the box predating the move, whose creating file no longer exists on disk.
  seed_project "/home/projects/LCARS/fleet/provisioning_v2/docker/docker-compose.install.yml"

  run bash "$SRC" down

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  # A refusal that does not say WHAT it saw cannot be acted on.
  [[ "$output" == *"provisioning_v2"* ]]
  [[ "$output" == *"$CF"* ]]
  [[ "$output" == *"docker compose ls"* ]]
  # Nothing reached compose: the guard is upstream, not a post-mortem.
  ! grep -q "down" "$CALLS"
}

@test "the file must match a WHOLE list element, never a prefix of one" {
  # `<file>` is a strict prefix of `<file>.bak`. Substring matching would call this project ours
  # and hand a live box to `down`.
  seed_project "$CF.bak"

  run bash "$SRC" down

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
}

@test "one match inside a multi-file list is enough" {
  seed_project "/somewhere/base.yml,$CF,/somewhere/override.yml"

  run bash "$SRC" down

  [ "$status" -eq 0 ]
  [[ "$output" != *"REFUS"* ]]
}

@test "reset refuses BEFORE asking for confirmation" {
  # Order is the contract. A confirmation prompt shown first teaches the operator to type `yes` at
  # a question about the wrong box, and destruction follows their own answer.
  seed_project "/elsewhere/docker-compose.install.yml"

  run bash "$SRC" -p lcars-valid reset

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  [[ "$output" != *"RESET du projet"* ]]
  ! grep -q "volume rm" "$CALLS"
}

@test "reset NAMES the project it is about to destroy" {
  # `setsid` detaches from the controlling terminal, so opening /dev/tty FAILS and the confirmation
  # read yields nothing. Without it this test HANGS whenever the suite runs from a terminal — the
  # prompt would wait for a human who is not there. Skipping loudly beats a test that blocks a gate.
  command -v setsid >/dev/null || skip "setsid absent: cannot detach the tty without risking a hang"
  seed_project "$CF"

  # The empty answer takes the abort path. What is pinned is the QUESTION — a destruction prompt
  # that does not say which box is not a question, it is a reflex to type `yes` into.
  run setsid --wait bash "$SRC" -p lcars-a-moi reset

  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-a-moi"* ]]
  [[ "$output" == *"lcars-a-moi_lcars-home"* ]]
  [[ "$output" == *"annulé"* ]]
}

@test "LCARS_PROJECT is read, and -p overrides it" {
  seed_project "$CF"

  LCARS_PROJECT=depuis-env run bash "$SRC" down
  [ "$status" -eq 0 ]
  grep -q -- "-p depuis-env down" "$CALLS"

  : > "$CALLS"
  LCARS_PROJECT=depuis-env run bash "$SRC" -p depuis-flag down
  [ "$status" -eq 0 ]
  grep -q -- "-p depuis-flag down" "$CALLS"
  ! grep -q -- "-p depuis-env " "$CALLS"
}

@test "-p without a value is refused rather than swallowing the command" {
  # `box -p down` must not silently target a project named "down" and run no command.
  run bash "$SRC" -p

  [ "$status" -eq 1 ]
  [[ "$output" == *"-p attend un nom de projet"* ]]
}

@test "help works with NO docker at all, and is not truncated" {
  # Help is the one command that must survive a machine without docker — it is what you read to
  # find out what is missing.
  run env PATH=/usr/bin:/bin timeout 15 bash "$SRC" help

  [ "$status" -eq 0 ]
  # First line of the block and last line of the block: the extraction is anchored on content, so
  # inserting a header line can no longer amputate the tail.
  [[ "$output" == *"LCARS fleet v2 en conteneur"* ]]
  [[ "$output" == *"EXIT :"* ]]
  # And the -p contract is documented where an operator looks for it.
  [[ "$output" == *"LCARS_PROJECT"* ]]
}

# ─── `up` REND LE VERDICT DE PROVISIONNEMENT ────────────────────────────────────────────────────
#
# ⚠ CES TEMOINS EXISTENT PARCE QUE `up` RENDAIT LA MAIN AVANT DE SAVOIR. `compose up -d` sort des
# que le conteneur demarre ; le provisionnement tourne DANS l'entrypoint et dure. Une boite qui n'a
# rien pu provisionner annoncait « fleet up », se declarait *healthy* (son healthcheck ne sonde que
# des ports : ssh + le deck) et ne pouvait demarrer AUCUN pod — le seul endroit ou ca se lisait etant les logs, qu'on ne va
# pas lire apres une commande qui a dit oui.
#
# Les quatre etats sont distincts PARCE QU'ILS APPELLENT QUATRE GESTES DIFFERENTS, et le quatrieme
# est celui qui compte : ne pas avoir LU le verdict n'est pas l'avoir lu mauvais. On le dit, et on
# sort 0 — sortir non nul sur une non-mesure apprendrait a ignorer le code de sortie, ce qui coute
# exactement le jour ou il est vrai.

@test "up: verdict 0 -> CONVERGE, sortie 0" {
  STUB_PROV_RC=0 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"provisionnement CONVERGÉ"* ]]
}

@test "up: verdict 2 -> DRIFT nomme, mais PAS un echec (un geste manque, rien n'est casse)" {
  STUB_PROV_RC=2 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRIFT RÉSIDUEL"* ]]
  [[ "$output" != *"EN ÉCHEC"* ]]
}

@test "up: verdict non nul -> ECHEC, sortie NON NULLE, et la consequence est nommee" {
  STUB_PROV_RC=1 run "$SRC" -p lcars up
  [ "$status" -eq 1 ]
  [[ "$output" == *"EN ÉCHEC"* ]]
  # « la boite tourne » ET « ne produira rien » : les deux moities, sinon le lecteur croit que
  # le conteneur est mort et va le relancer au lieu de diagnostiquer.
  [[ "$output" == *"la boîte tourne"* ]]
  [[ "$output" == *"ne produira RIEN"* ]]
}

@test "up: verdict ILLISIBLE -> on le DIT et on sort 0 — une non-mesure n'est pas un echec" {
  LCARS_UP_VERDICT_TIMEOUT=1 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"NON LU"* ]]
  [[ "$output" == *"n'est PAS mesuré"* ]]
  [[ "$output" != *"EN ÉCHEC"* ]]
}

# ─── `build` rend DEUX images, et la seconde ne sortait de nulle part ────────────────────────────

@test "build etiquette le jumeau lcars-build — le toolchain que le runner CI sert" {
  # LE DEFAUT MESURE (2026-08-18, install sur une Debian vierge, chemin exact du README) : forge,
  # boite, tokens, creds, admin tous verts, puis `bench-up` **exit 6** — « pas d'image lcars-build:2
  # pour le label elixir ». Aucun script du depot ne construisait ce jumeau : chaque mention en
  # etait une CONSIGNE adressee a l'operateur. Sur une machine de dev les deux existaient parce
  # qu'un jour on avait joue la consigne ; sur une machine neuve, jamais. Et ce n'est pas une
  # degradation : la carte canon declare `ci: required`, donc le banc REFUSE de monter.
  run bash "$SRC" build

  [ "$status" -eq 0 ]
  grep -q -- "compose .*build" "$CALLS"
  grep -q -- "build --target build -t lcars-build:2" "$CALLS"
}

@test "le tag du jumeau SUIT celui du runtime — c'est la regle que bench-up applique" {
  # `bench-up.sh` derive `lcars-build:<tag>` du tag de l'image de banc. Un jumeau fige a `:2`
  # pendant que le runtime part sur `:v4` rendrait un runner qui sert le toolchain d'un AUTRE build
  # — vert, et faux.
  LCARS_IMAGE=lcars-fleet:v4 run bash "$SRC" build

  [ "$status" -eq 0 ]
  grep -q -- "build --target build -t lcars-build:v4" "$CALLS"
}

# ─── LA DECOUPE ELLE-MEME ────────────────────────────────────────────────────────────────────────
# Les seize temoins ci-dessus passent par le delegue, donc ils traversent la porte sans le
# savoir. C'est voulu : le plan prevoyait de les DESCENDRE vers le delegue, et les garder ici prouve
# strictement plus — l'entree ET le relais. Ce qu'ils ne prouvent pas, ce sont les deux proprietes
# du relais lui-meme, et c'est ce que les deux temoins suivants ajoutent.

@test "la racine DELEGUE, et transmet l'argv VERBATIM" {
  # Un wrapper qui reconstruit la ligne de commande perd toujours quelque chose — le plus souvent
  # un argument a espaces, et on ne s'en apercoit que le jour ou quelqu'un en passe un.
  #
  # ARBRE FACTICE plutot qu'une couture dans le script : un `LCARS_BOX_OVERRIDE` dont le seul
  # client serait ce temoin ferait porter au code une variable qui ne sert a personne. Ici on
  # eprouve EN PLUS la resolution reelle du chemin (`SCRIPT_DIR/fleet/deploy/box`).
  local root="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$root/fleet/deploy/lib"
  mkdir -p "$root/fleet/deploy"; cp "$SRC" "$root/fleet/deploy/box"
  cp "$REPO/fleet/deploy/lib/docker-endpoint.sh" "$root/fleet/deploy/lib/"
  cat > "$root/fleet/deploy/box" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$#"; printf '[%s]' "$@"; echo
FAKE
  chmod 0755 "$root/fleet/deploy/box"

  run bash "$root/fleet/deploy/box" logs --tail "deux mots" -f
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "4" ]]
  [[ "${lines[1]}" == '[logs][--tail][deux mots][-f]' ]]
}


# ─── L'AIDE APPARTIENT A QUI PORTE LES VERBES ───────────────────────────────────────────────────
#
# ⚠ L'AIDE A VECU HORS DU FICHIER QUI PORTE LES VERBES, et ce fichier la LUI DEMANDAIT — un
# `usage()` qui `exec` ailleurs. Le porteur du contrat empruntait son contrat a un relais qui ne
# faisait que le passer. Ces temoins tiennent le sens de la fleche.

@test "l'aide vit dans le DELEGUE, et la porte ne fait que la relayer" {
  local box="$BATS_TEST_DIRNAME/../box"
  # ⚠ LES CONTROLES STATIQUES D'ABORD, ET CE N'EST PAS UN DETAIL DE STYLE. Si le delegue redemande
  # son aide a la porte pendant que la porte la lui demande, les deux `exec` s'appellent sans fond
  # de pile : rien ne compte les tours, rien ne sort. Un temoin qui LANCE avant de LIRE PEND au lieu
  # de rougir — et un temoin qui pend est un temoin que le prochain desactive.
  grep -q 'usage() { sed -n .*BASH_SOURCE\[0\]' "$box"
  ! grep -q '^usage() { exec ' "$box"

  # ⚠ `timeout` : ce temoin garde contre une BOUCLE D'EXEC. Sans borne, il ne rougit pas — il PEND,
  # bats ne rend rien du tout, et le prochain qui le voit pendre le desactive.
  run env PATH=/usr/bin:/bin timeout 15 bash "$box" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"LCARS fleet v2 en conteneur"* ]]
  [[ "$output" == *"EXIT :"* ]]
}

@test "les DEUX portes rendent le MEME texte — une aide recopiee derive" {
  local box="$BATS_TEST_DIRNAME/../box"
  run env PATH=/usr/bin:/bin timeout 15 bash "$SRC" help
  local par_la_porte="$output"
  # ⚠ `timeout` : ce temoin garde contre une BOUCLE D'EXEC. Sans borne, il ne rougit pas — il PEND,
  # bats ne rend rien du tout, et le prochain qui le voit pendre le desactive.
  run env PATH=/usr/bin:/bin timeout 15 bash "$box" help
  [[ "$par_la_porte" == "$output" ]]
}

@test "l'aide ne promet plus une forge que l'operateur devrait apporter" {
  # ⚠ « La forge est a TOI : LCARS ne la fabrique pas » etait vrai le 2026-07-05 et faux depuis
  # `--bench`, qui monte forge jetable + boite + runner CI en un geste (`install.sh:588`). C'etait
  # le SEUL texte d'aide du rail boite, et il disait d'apporter ce que le produit sait fabriquer.
  run env PATH=/usr/bin:/bin timeout 15 bash "$SRC" help
  [[ "$output" == *"--bench"* ]]
  [[ "$output" != *"LCARS ne la"$'\n'*"fabrique pas"* ]]
  [[ "$output" != *"ne la fabrique pas"* ]]
}

@test "le delegue ne redit PAS que l'aide vit ailleurs" {
  # Sa carte annoncait « l'aide de la porte, qui reste la source unique de l'aide. Elle n'est pas
  # recopiee ici ». Vrai jusqu'a ce geste, faux apres — et un commentaire perime oriente toutes les
  # sessions suivantes sans date ni signature.
  local box="$BATS_TEST_DIRNAME/../box"
  ! grep -q 'qui reste la source unique de l' "$box"
}

# ─── LE DELEGUE EST SA PROPRE PORTE ─────────────────────────────────────────────────────────────
#
# ⚠ TANT QU'IL LISAIT CE QU'UNE PORTE LUI POSAIT, `box` PORTAIT DEUX DEFAUTS :
# `${LCARS_DOCKER_BIN:-docker}` et `${LCARS_COMPOSE_CMD:-docker compose}`. Sur une socket
# appartenant a root, `PROV_DOCKER_BIN` est un SHIM qui escalade — un `docker` nu le contournerait
# EN SILENCE pour echouer plus loin sur une permission. Les deux defauts n'ont plus d'objet
# maintenant qu'il sonde lui-meme, et les garder serait garder la reponse d'une porte disparue.

@test "le delegue SONDE, il ne lit plus ce qu'une porte lui pose" {
  local box="$BATS_TEST_DIRNAME/../box"
  grep -q 'docker_endpoint || fail' "$box"
  grep -q '^DOCKER="\$PROV_DOCKER_BIN"$' "$box"
  ! grep -q 'LCARS_DOCKER_BIN:-' "$box"
  ! grep -q 'LCARS_COMPOSE_CMD:-' "$box"
}

@test "le delegue rend l'aide SANS docker — elle passe avant la sonde" {
  # ⚠ L'ORDRE EST LA PROPRIETE. Un `--help` qui exige l'outil qu'il documente est une porte fermee,
  # et c'est le seul geste du rail qui n'a aucune condition.
  local box="$BATS_TEST_DIRNAME/../box"
  local l_help l_sonde
  l_help="$(grep -n 'help|-h|--help) usage; exit 0' "$box" | head -1 | cut -d: -f1)"
  l_sonde="$(grep -n 'docker-endpoint.sh"$' "$box" | head -1 | cut -d: -f1)"
  [ -n "$l_help" ] && [ -n "$l_sonde" ]
  [ "$l_help" -lt "$l_sonde" ]
  run env PATH=/usr/bin:/bin timeout 15 bash "$box" help
  [ "$status" -eq 0 ]
}
