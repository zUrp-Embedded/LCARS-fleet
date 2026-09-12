#!/usr/bin/env bats
# bats file_tags=integration
# SOURCE: deploy/tests/container_project.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-07
# STATUS: bats tests for deploy/container — a project NAME is not proof you are talking about the same container
#
# WHY THIS EXISTS. The container rail targeted the compose project `lcars` as a hardcoded constant. Compose
# will happily apply a file to a project it never created: it computes the desired state from THAT
# file and recreates, republishes ports, drops what is absent — with no error, because from its own
# point of view nothing is wrong. The name is enough to address the project; it is not enough to
# prove both parties mean the same object.
#
# Measured on this workstation on 2026-08-07: `lcars` was a 47-hour-old working container created from
# `fleet/provisioning_v2/docker/docker-compose.install.yml` — a path DELETED by the 2026-08-04 move.
# `container down` stopped it, `container reset` took its /home volume, and neither said a word.
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

load refute

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SRC="$REPO/deploy/container"
  CF="$REPO/deploy/docker/docker-compose.yml"

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
if [[ "\$*" == *"config --format json"* ]]; then printf '{"volumes":{"lcars-home":{"name":"%s"}}}\n' "\${STUB_COMPOSE_HOME:-}"; exit 0; fi
if [[ "\$*" == *".Mounts"* ]]; then echo "\${STUB_HOME_VOLUME:-}"; exit 0; fi
if [[ "\$1 \$2" == "image inspect" && -n "\${STUB_NO_IMAGE:-}" ]]; then exit 1; fi
case "\$1 \$2" in
  "compose version") exit 0 ;;
  "ps -aq")          printf '%s' "\${STUB_IDS:-}"; [[ -n "\${STUB_IDS:-}" ]] && echo; exit 0 ;;
  "volume ls")       printf '%s' "\${STUB_VOLUMES:-}"; [[ -n "\${STUB_VOLUMES:-}" ]] && echo; exit 0 ;;
  "inspect \${STUB_IDS:-__none__}") echo "\${STUB_CONFIG_FILES:-}"; exit 0 ;;
esac
# Le verdict de provisionnement, lu par 'up' DANS le conteneur. STUB_PROV_RC vide = le fichier n'est
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
  unset LCARS_PROJECT STUB_IDS STUB_CONFIG_FILES STUB_PROV_RC STUB_VOLUMES STUB_HOME_VOLUME STUB_COMPOSE_HOME

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
  # la conf par projet vit sous $HOME : un temoin ne touche pas le vrai
  export LCARS_CONTAINER_CONF_DIR="$BATS_TEST_TMPDIR/conf"
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
  [[ "$output" != *"refus"* ]]
  # It really went through to compose rather than short-circuiting.
  grep -q -- "-p lcars-jamais-cree down" "$CALLS"
}

@test "a project created by THIS compose file passes the guard" {
  seed_project "$CF"

  run bash "$SRC" down

  [ "$status" -eq 0 ]
  [[ "$output" != *"refus"* ]]
  grep -q -- "-p lcars-fleet down" "$CALLS"
}

@test "a project created by ANOTHER compose file is refused, and the refusal names both" {
  # The real case: the container predating the move, whose creating file no longer exists on disk.
  seed_project "/home/projects/LCARS/fleet/provisioning_v2/docker/docker-compose.install.yml"

  run bash "$SRC" down

  [ "$status" -eq 1 ]
  [[ "$output" == *"refus"* ]]
  # A refusal that does not say WHAT it saw cannot be acted on.
  [[ "$output" == *"provisioning_v2"* ]]
  [[ "$output" == *"$CF"* ]]
  [[ "$output" == *"docker compose ls"* ]]
  # Nothing reached compose: the guard is upstream, not a post-mortem.
  refute grep -q "down" "$CALLS"
}

@test "the file must match a WHOLE list element, never a prefix of one" {
  # `<file>` is a strict prefix of `<file>.bak`. Substring matching would call this project ours
  # and hand a live container to `down`.
  seed_project "$CF.bak"

  run bash "$SRC" down

  [ "$status" -eq 1 ]
  [[ "$output" == *"refus"* ]]
}

@test "one match inside a multi-file list is enough" {
  seed_project "/somewhere/base.yml,$CF,/somewhere/override.yml"

  run bash "$SRC" down

  [ "$status" -eq 0 ]
  [[ "$output" != *"refus"* ]]
}

@test "reset refuses BEFORE asking for confirmation" {
  # Order is the contract. A confirmation prompt shown first teaches the operator to type `yes` at
  # a question about the wrong container, and destruction follows their own answer.
  seed_project "/elsewhere/docker-compose.install.yml"

  run bash "$SRC" -p lcars-valid reset

  [ "$status" -eq 1 ]
  [[ "$output" == *"refus"* ]]
  [[ "$output" != *"reset du projet"* ]]
  refute grep -q "volume rm" "$CALLS"
}

@test "reset NAMES the project it is about to destroy" {
  # `setsid` detaches from the controlling terminal, so opening /dev/tty FAILS and the confirmation
  # read yields nothing. Without it this test HANGS whenever the suite runs from a terminal — the
  # prompt would wait for a human who is not there. Skipping loudly beats a test that blocks a gate.
  command -v setsid >/dev/null || skip "setsid absent: cannot detach the tty without risking a hang"
  seed_project "$CF"

  # The empty answer takes the abort path. What is pinned is the QUESTION — a destruction prompt
  # that does not say which container is not a question, it is a reflex to type `yes` into.
  run setsid --wait bash "$SRC" -p lcars-a-moi reset

  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-a-moi"* ]]
  [[ "$output" == *"annulé"* ]]
}

# Le nom des volumes se dérive de docker (filtre par label de projet), il ne se recompose jamais
# depuis le compose : un nom recopié à la main a déjà fait retirer un fantôme en laissant le vrai.

@test "reset NOMME les volumes que docker declare, il ne les compose pas" {
  STUB_VOLUMES="$(printf 'lcars-a-moi_lcars-home\nlcars-a-moi_cache')" \
    run setsid --wait bash "$SRC" -p lcars-a-moi reset </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-a-moi_lcars-home"* ]]
  [[ "$output" == *"lcars-a-moi_cache"* ]]
}

@test "reset le DIT quand le projet ne porte aucun volume — jamais un nom invente" {
  run setsid --wait bash "$SRC" -p lcars-a-moi reset </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"<aucun>"* ]]
}

# shellcheck disable=SC2016 # motif `grep` : `${PROJECT}` doit atteindre grep tel quel
@test "up refuse une instance dont /home vit sur un autre volume que celui du compose — jamais un /home vide en silence" {
  seed_project "$CF"
  STUB_HOME_VOLUME=lcars-fleet_home STUB_COMPOSE_HOME=lcars-fleet_lcars-home run bash "$SRC" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-fleet_home"*"lcars-fleet_lcars-home"*"volume vide"* ]]
  [[ "$output" == *"reset"* ]]
  refute grep -qE "compose .* up" "$CALLS"
  # même volume des deux côtés : la garde se tait et up va jusqu'au verdict
  STUB_HOME_VOLUME=lcars-fleet_lcars-home STUB_COMPOSE_HOME=lcars-fleet_lcars-home STUB_PROV_RC=0 \
    LCARS_UP_VERDICT_TIMEOUT=5 run bash "$SRC" up
  [ "$status" -eq 0 ]
  [[ "$output" != *"volume vide"* ]]
  grep -qE "compose .* up" "$CALLS"
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
  refute grep -q -- "-p depuis-env " "$CALLS"
}

@test "-p without a value is refused rather than swallowing the command" {
  # `container -p down` must not silently target a project named "down" and run no command.
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
  [[ "$output" == *"USAGE : deploy/container"* ]]
  [[ "$output" == *"EXIT :"* ]]
  # And the -p contract is documented where an operator looks for it.
  [[ "$output" == *"LCARS_PROJECT"* ]]
}

# ─── `up` REND LE VERDICT DE PROVISIONNEMENT ────────────────────────────────────────────────────
#
# ⚠ CES TEMOINS EXISTENT PARCE QUE `up` RENDAIT LA MAIN AVANT DE SAVOIR. `compose up -d` sort des
# que le conteneur demarre ; le provisionnement tourne DANS l'entrypoint et dure. Un conteneur qui n'a
# rien pu provisionner annoncait « fleet up », se declarait *healthy* (son healthcheck ne sonde que
# des ports : ssh + le deck) et ne pouvait demarrer AUCUN pod — le seul endroit ou ca se lisait etant les logs, qu'on ne va
# pas lire apres une commande qui a dit oui.
#
# Les quatre etats sont distincts PARCE QU'ILS APPELLENT QUATRE GESTES DIFFERENTS, et le quatrieme
# est celui qui compte : ne pas avoir LU le verdict n'est pas l'avoir lu mauvais. On le dit, et on
# sort 0 — sortir non nul sur une non-mesure apprendrait a ignorer le code de sortie, ce qui coute
# exactement le jour ou il est vrai.

@test "up: verdict 0 -> convergé, sortie 0, et compose n'a jamais bâti" {
  STUB_PROV_RC=0 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"provisionnement convergé"* ]]
  grep -q -- ' up -d --no-build' "$CALLS"
  refute grep -qE '(^| )build( |$)' "$CALLS"
}

@test "up: verdict 2 -> DRIFT nomme, mais PAS un echec (un geste manque, rien n'est casse)" {
  STUB_PROV_RC=2 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"drift résiduel"* ]]
  [[ "$output" != *"en échec"* ]]
}

@test "up: verdict non nul -> ECHEC, sortie NON NULLE, et la consequence est nommee" {
  STUB_PROV_RC=1 run "$SRC" -p lcars up
  [ "$status" -eq 1 ]
  [[ "$output" == *"en échec"* ]]
  # « le conteneur tourne » ET « ne produira rien » : les deux moities, sinon le lecteur croit que
  # le conteneur est mort et va le relancer au lieu de diagnostiquer.
  [[ "$output" == *"le conteneur tourne"* ]]
  [[ "$output" == *"ne produira rien"* ]]
}

@test "up: verdict ILLISIBLE -> on le DIT et on sort 0 — une non-mesure n'est pas un echec" {
  LCARS_UP_VERDICT_TIMEOUT=1 run "$SRC" -p lcars up
  [ "$status" -eq 0 ]
  [[ "$output" == *"non lu"* ]]
  [[ "$output" == *"n'est pas mesuré"* ]]
  [[ "$output" != *"en échec"* ]]
}

# ─── `build` DELEGUE A pack.sh — le kit, puis l'image, par le meme rail ─────────────────────────
#
# Jusqu'au 2026-09-11 `build` rendait DEUX images : `compose build` depuis le checkout, puis un
# second `docker build --target build` qui etiquetait le jumeau `lcars-build:<tag>` du label
# `elixir`. Le Dockerfile n'est plus un jumeau — il pose le kit par les modules — et le kit ne se
# fabrique que par pack.sh (gate, release, doc, tar, image). `build` n'a donc rien a faire lui-meme.

@test "build DELEGUE a pack.sh — aucun docker build, aucun compose build ici" {
  local stub="$BATS_TEST_TMPDIR/pack-stub"
  printf '#!/usr/bin/env bash\necho "PACK:$*"\n' > "$stub"; chmod 0755 "$stub"
  LCARS_PACK_BIN="$stub" run bash "$SRC" build --no-image
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"PACK:--no-image"* ]]
  refute grep -qE -- "compose .*build|build --target" "$CALLS"
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
  # ARBRE FACTICE plutot qu'une couture dans le script : un `LCARS_CONTAINER_OVERRIDE` dont le seul
  # client serait ce temoin ferait porter au code une variable qui ne sert a personne. Ici on
  # eprouve EN PLUS la resolution reelle du chemin (`SCRIPT_DIR/deploy/container`).
  local root="$BATS_TEST_TMPDIR/arbre"
  mkdir -p "$root/deploy/lib"
  mkdir -p "$root/deploy"; cp "$SRC" "$root/deploy/container"
  cp "$REPO/deploy/lib/docker-endpoint.sh" "$root/deploy/lib/"
  cat > "$root/deploy/container" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$#"; printf '[%s]' "$@"; echo
FAKE
  chmod 0755 "$root/deploy/container"

  run bash "$root/deploy/container" logs --tail "deux mots" -f
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
  local container="$BATS_TEST_DIRNAME/../container"
  # ⚠ LES CONTROLES STATIQUES D'ABORD, ET CE N'EST PAS UN DETAIL DE STYLE. Si le delegue redemande
  # son aide a la porte pendant que la porte la lui demande, les deux `exec` s'appellent sans fond
  # de pile : rien ne compte les tours, rien ne sort. Un temoin qui LANCE avant de LIRE PEND au lieu
  # de rougir — et un temoin qui pend est un temoin que le prochain desactive.
  grep -q 'usage() { sed -n .*BASH_SOURCE\[0\]' "$container"
  refute grep -q '^usage() { exec ' "$container"

  # ⚠ `timeout` : ce temoin garde contre une BOUCLE D'EXEC. Sans borne, il ne rougit pas — il PEND,
  # bats ne rend rien du tout, et le prochain qui le voit pendre le desactive.
  run env PATH=/usr/bin:/bin timeout 15 bash "$container" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE : deploy/container"* ]]
  [[ "$output" == *"EXIT :"* ]]
}

@test "les DEUX portes rendent le MEME texte — une aide recopiee derive" {
  local container="$BATS_TEST_DIRNAME/../container"
  run env PATH=/usr/bin:/bin timeout 15 bash "$SRC" help
  local par_la_porte="$output"
  # ⚠ `timeout` : ce temoin garde contre une BOUCLE D'EXEC. Sans borne, il ne rougit pas — il PEND,
  # bats ne rend rien du tout, et le prochain qui le voit pendre le desactive.
  run env PATH=/usr/bin:/bin timeout 15 bash "$container" help
  [[ "$par_la_porte" == "$output" ]]
}

@test "l'aide ne promet plus une forge que l'operateur devrait apporter" {
  # ⚠ « La forge est a TOI : LCARS ne la fabrique pas » etait vrai le 2026-07-05 et faux depuis
  # `--bench`, qui monte forge jetable + conteneur + runner CI en un geste (`install.sh:588`). C'etait
  # le SEUL texte d'aide du rail conteneur, et il disait d'apporter ce que le produit sait fabriquer.
  run env PATH=/usr/bin:/bin timeout 15 bash "$SRC" help
  [[ "$output" == *"--bench"* ]]
  [[ "$output" != *"LCARS ne la"$'\n'*"fabrique pas"* ]]
  [[ "$output" != *"ne la fabrique pas"* ]]
}

@test "l'aide se rend sans docker ni sonde, et ne crée aucun fichier de secrets" {
  run env PATH=/usr/bin:/bin timeout 15 bash "$SRC" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"*"--bench"*"EXIT"* ]]
  [ ! -e "$LCARS_CONTAINER_CONF_DIR" ]
}

@test "up --bench : exec du banc avec la base du projet, l'image et les ports traduits" {
  local bench="$BATS_TEST_TMPDIR/arbre/deploy/docker/bench"; mkdir -p "$bench" "$BATS_TEST_TMPDIR/arbre/deploy/lib" "$BATS_TEST_TMPDIR/arbre/deploy/docker"
  cp "$SRC" "$BATS_TEST_TMPDIR/arbre/deploy/container"; cp -a "$REPO/deploy/lib/." "$BATS_TEST_TMPDIR/arbre/deploy/lib/"
  cp "$CF" "$REPO/deploy/docker/docker-compose.secrets.yml" "$BATS_TEST_TMPDIR/arbre/deploy/docker/"
  printf '#!/usr/bin/env bash\necho "BENCH:$*"; echo "DOCKER_BIN=$DOCKER_BIN"\n' > "$bench/bench-up.sh"; chmod 0755 "$bench/bench-up.sh"
  LCARS_IMAGE=lcars-fleet:9 run bash "$BATS_TEST_TMPDIR/arbre/deploy/container" --forge-project bob_10 --port-forge 20100 --port-deck 20101 --port-ssh 20102 --bench up
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [[ "$output" == *"BENCH:--forge-project bob_10 --image lcars-fleet:9 --port-forge 20100 --port-deck 20101 --port-ssh 20102"* ]]
  [[ "$output" == *"DOCKER_BIN=$BINDIR/docker"* ]]
  refute grep -qE "compose .* up" "$CALLS"
}

@test "--port-forge sans --bench est refusé : la forge est fournie" {
  run bash "$SRC" --port-forge 20100 up
  [ "$status" -eq 1 ]
  [[ "$output" == *"--port-forge n'a d'objet qu'avec --bench"* ]]
}

@test "la CLI docker est celle que la sonde rend, jamais le docker nu du PATH" {
  local nu="$BATS_TEST_TMPDIR/nu"; mkdir -p "$nu"
  printf '#!/usr/bin/env bash\necho "DOCKER-NU:$*" >> "%s"\nexit 1\n' "$CALLS" > "$nu/docker"; chmod 0755 "$nu/docker"
  PATH="$nu:$PATH" run bash "$SRC" status
  [ "$status" -eq 2 ]
  refute grep -q 'DOCKER-NU' "$CALLS"
  grep -q 'compose .* ps -q lcars' "$CALLS"
}

@test "up : image absente — un up ne la fabrique pas, il nomme pull et build, et sort 1" {
  seed_project "$CF"
  STUB_NO_IMAGE=1 run bash "$SRC" up
  [ "$status" -eq 1 ]
  [[ "$output" == *"image « ghcr.io/"*" » absente"*"deploy/container pull"*"deploy/container build"* ]]
  refute grep -qE "compose .* up|build" "$CALLS"
}
