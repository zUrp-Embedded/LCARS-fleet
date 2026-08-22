#!/usr/bin/env bats
# SOURCE: fleet/deploy/tests/bench_runner_labels.bats
# AUTHOR: DrDree
# STARDATE: 2026-08-05
# STATUS: bats tests for forge-runner.sh — a label is a promise, checked before it is made
#
# WHY THIS EXISTS. A runner label is a KEY the runner announces to the forge: "send me the jobs that
# ask for this". The runner registers GREEN whatever image sits behind the key, then fails every job
# handed to it. That is trap n°2 of the script's own header at another layer — "a green runner that
# fails all its jobs, the worst of states" — and the file carried it as a NOTE since 2026-08-02
# without acting on it. A note describing a silence is still a silence.
#
# Both refusals fire BEFORE the first call to the forge: registering and then discovering the
# runner is useless costs a forge round-trip and leaves a zombie identity in the volume.
#
# `docker image inspect` is deliberate: it is a NON-attached-stream command, so it crosses the
# fleet group's systemd relay, unlike `exec`/`run`/`cp` which return zero bytes and exit 0 there.
# The probe therefore works on both sockets — a probe that only works on the good one would be
# absent exactly when it is needed.

setup() {
  SRC="$BATS_TEST_DIRNAME/../docker/forge-runner.sh"
  BINDIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$BINDIR"
  CALLS="$BATS_TEST_TMPDIR/docker.calls"
  : > "$CALLS"

  # Knows two images and nothing else. `image inspect` on anything else fails, which is exactly
  # what a daemon does for an image nobody built.
  # Le daemon connait deux images au depart. `pull` ACQUIERT — sauf ce que `PULLABLE` refuse : une
  # image locale (`lcars-build:<tag>`) n'est sur aucun registre, et c'est la difference que la garde
  # doit garder entre « pas encore tiree » et « n'existe nulle part ».
  KNOWN="$BATS_TEST_TMPDIR/known"
  printf 'alpine:3.20\nlcars-build:9\n' > "$KNOWN"
  UNPULLABLE="$BATS_TEST_TMPDIR/unpullable"
  : > "$UNPULLABLE"
  cat > "$BINDIR/dockerstub" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
if [[ "\$1 \$2" == "image inspect" ]]; then
  grep -qxF "\$3" "$KNOWN" && exit 0 || exit 1
fi
if [[ "\$1" == "pull" ]]; then
  img="\${@: -1}"
  # Un tag LOCAL (`lcars-build:*`) n'est sur aucun registre — le tir echoue, comme en vrai.
  case "\$img" in lcars-build:*) exit 1 ;; esac
  grep -qxF "\$img" "$UNPULLABLE" && exit 1
  echo "\$img" >> "$KNOWN"
  exit 0
fi
exit 0
EOF
  chmod 0755 "$BINDIR/dockerstub"

  # The forge must never be reached in these tests: every refusal is upstream of it. A curl that
  # ran would prove the check fired too late.
  cat > "$BINDIR/curl" <<EOF
#!/usr/bin/env bash
echo "CURL \$*" >> "$CALLS"
exit 0
EOF
  chmod 0755 "$BINDIR/curl"

  export PATH="$BINDIR:$PATH"
  export DOCKER_BIN=dockerstub
  unset LCARS_RUNNER_LABELS
}

# ⚠ LE DECOR NOMME LE RESEAU ET LE PROJET, PARCE QUE LE SCRIPT LES EXIGE. Ils ont porte des
# defauts de banc, qui visaient le deploiement d'un AUTRE rail : un appelant qui en heritait
# enrolait son runner a cote de sa forge — il demarre, ne joint rien, et la CI reste muette. Sans
# defaut, le refus est net ; ces temoins mesurent les LABELS, ils doivent donc fournir le reste.
run_runner() {
  run bash "$SRC" --forge-api http://f/api/v1 --admin-token tok \
      --network t_default --project t-runner "$@"
}

@test "no --labels at all is REFUSED, and the refusal carries the way out" {
  run_runner

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  # A refusal that does not say how to proceed is an obstacle, not a wall.
  [[ "$output" == *"--target build"* ]]
  [[ "$output" == *"--accept-generic"* ]]
  # Upstream of the forge: nothing was minted, nothing registered.
  ! grep -q '^CURL' "$CALLS"
}

@test "--accept-generic proceeds, and SAYS what was accepted" {
  run_runner --accept-generic

  # The generic default is right for an operator who cannot resolve a local LCARS image. Choosing
  # it is a decision; inheriting it silently was the defect.
  [[ "$output" == *"ACCEPTE"* ]]
  [[ "$output" == *"ne sait pas jouer mix gate"* ]]
  grep -q '^CURL' "$CALLS"
}

@test "an image no daemon can resolve is REFUSED — the runner would announce it anyway" {
  run_runner --labels "shell:docker://alpine:3.20,elixir:docker://lcars-build:absente"

  [ "$status" -eq 1 ]
  [[ "$output" == *"lcars-build:absente"* ]]
  [[ "$output" == *"rate chaque job"* ]]
  ! grep -q '^CURL' "$CALLS"
}

@test "labels whose images all resolve pass, and the check reaches the forge after" {
  run_runner --labels "shell:docker://alpine:3.20,elixir:docker://lcars-build:9"

  [[ "$output" == *"labels:"* ]]
  grep -q "image inspect alpine:3.20" "$CALLS"
  grep -q "image inspect lcars-build:9" "$CALLS"
  grep -q '^CURL' "$CALLS"
}

@test "a label with no docker:// image is skipped, not reported missing" {
  # A host-runner label resolves to nothing to pull. Treating it as a missing image would refuse a
  # perfectly valid configuration — the check must answer the question it was asked.
  run_runner --labels "host,shell:docker://alpine:3.20"

  [[ "$output" != *"introuvable"* ]]
  ! grep -q "image inspect host" "$CALLS"
}

# ─── une image publique absente se TIRE avant de se refuser ──────────────────────────────────────

@test "une image de label absente est TIREE, et le banc continue" {
  # LE DEFAUT MESURE (2026-08-18, Debian neuve, chemin de livraison) : `REFUS : docker:cli`, banc
  # exit 6. Personne ne tirait les images publiques dont les labels dependent — sur la machine de
  # dev elles etaient la depuis des mois, donc invisible. ⚖ La BP est arbitree : le banc tire.
  run_runner --labels "shell:docker://alpine:3.20,dood:docker://docker:cli"

  # Ce qui est mesure est la GARDE, pas la fin du script : la forge est une doublure muette, donc
  # l'enregistrement echoue apres — comme dans le temoin « labels whose images all resolve ».
  [[ "$output" == *"tentative de tir : docker:cli"* ]]
  [[ "$output" != *"REFUS"* ]]
  grep -q "^pull -q docker:cli" "$CALLS"
  # Une image DEJA la n'est pas re-tiree : la garde tire ce qui manque, pas ce qui est.
  ! grep -q "^pull -q alpine:3.20" "$CALLS"
  grep -q '^CURL' "$CALLS"
}

@test "une image que le tir ne ramene pas reste un REFUS, et il nomme le build" {
  # La distinction qui compte : `lcars-build:<tag>` n'est sur aucun registre. Tirer echoue, l'image
  # reste absente, et le refus doit rester celui qui nomme la commande de build — pas un message de
  # registre que personne ne peut suivre.
  run_runner --labels "shell:docker://alpine:3.20,elixir:docker://lcars-build:absente"

  [ "$status" -eq 1 ]
  [[ "$output" == *"REFUS"* ]]
  [[ "$output" == *"lcars-build:absente"* ]]
  [[ "$output" == *"--target build"* ]]
  ! grep -q '^CURL' "$CALLS"
}

# ─── UN SEUL RAIL, ET C'EST LE SECURISE ──────────────────────────────────────────────────────────
#
# ⚖ ARBITRAGE USER 2026-08-18 : « si on fait les 2 rails, on peut pas juste faire le bon, secure, et
# l'utiliser aussi pour le banc ? ». Oui — parce que deux rails, c'est un rail qui pourrit.
#
# Le socket de l'hote donnait a N'IMPORTE QUEL job le daemon de la machine : root, par conception,
# sans rien avoir a casser. La doc Gitea le dit elle-meme (« jobs share the host's daemon and can
# see its other containers »).

@test "le compose du runner ne monte PLUS le socket de l'hote" {
  C="$BATS_TEST_DIRNAME/../docker/runner-compose.yml"
  [ -f "$C" ]
  # aucune ligne de MONTAGE du socket (les mentions en commentaire, elles, expliquent pourquoi)
  ! grep -qE '^\s*-\s*/var/run/docker\.sock' "$C"
  # ⚠ CE QUI EST TENU EST LA VARIANTE, PLUS LA VERSION. Ce temoin exigeait un digest fige
  # (`0.6.1-dind-rootless@sha256:…`). Le pin est parti — ⚖ user 2026-08-20 : ce compose ne sert que
  # des BANCS (`act_runner` n'apparait dans aucun des deux compose produit ; en prod l'admin
  # provisionne son runner), et un banc est fait pour DECOUVRIR qu'un amont a bouge. Figer du
  # jetable, c'est apprendre la rupture chez quelqu'un d'autre.
  #
  # Le SUFFIXE, lui, reste tenu : `dind` decide si un job a un daemon docker — donc si `container:`
  # est jouable — et un `latest` nu ramenerait le montage du socket de l'hote que la ligne
  # ci-dessus refuse. C'est la variante qui porte la propriete de securite, pas le numero.
  grep -qE 'gitea/runner:[a-z0-9.]+-dind-rootless' "$C"
  # Et le digest ne revient pas par la fenetre : un pin ici serait un choix a re-arbitrer.
  ! grep -qE 'gitea/runner:[^[:space:]]*@sha256:' "$C"
  grep -qE '^\s*privileged: true' "$C"
  grep -q 'apparmor=rootlesskit' "$C"
  grep -q 'DOCKER_HOST: "unix:///var/run/user/1000/docker.sock"' "$C"
}

@test "le magasin du daemon embarque est un volume NOMME — sinon le semis meurt au recreate" {
  # L'image DECLARE ce chemin comme volume : docker en cree donc un, mais ANONYME. Un `down -v`
  # l'emporte, un `recreate` l'orpheline, et `lcars-build` — qu'aucun registre ne porte — part avec.
  C="$BATS_TEST_DIRNAME/../docker/runner-compose.yml"
  grep -q 'runner-dind:/home/rootless/.local/share/docker' "$C"
  grep -qE '^\s{2}runner-dind:\s*$' "$C"
}

@test "le semeur EXIGE une sortie non vide — un exec qui avale ne doit pas passer pour un succes" {
  # L'etape 0 de ce script le dit deja : `exec` rend zero octet et exit 0 a travers le relais
  # systemd du groupe fleet. Une sonde qui se contenterait du code de retour semerait dans le vide
  # en se croyant verte.
  SUT="$BATS_TEST_DIRNAME/../docker/forge-runner.sh"
  grep -q 'seed_dind_images' "$SUT"
  grep -q 'docker image inspect -f .{{.Id}}.' "$SUT"
  # le refus existe et il nomme les deux causes possibles
  grep -q "ne rend rien apres 60 s" "$SUT"
}

@test "le semeur lit LES LABELS — aucune seconde liste d'images a tenir" {
  # Une quatrieme liste du meme fait est morte ailleurs dans ce depot (PROV_ROLES). On ne
  # recommence pas : les labels nomment deja les images, l'etape 0 a deja verifie qu'elles existent.
  SUT="$BATS_TEST_DIRNAME/../docker/forge-runner.sh"
  awk '/^seed_dind_images\(\)/,/^}/' "$SUT" | grep -q 'for entry in \$LABELS'
  awk '/^seed_dind_images\(\)/,/^}/' "$SUT" | grep -q 'image="\${entry#\*docker://}"'
}
