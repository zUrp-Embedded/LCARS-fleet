#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/image_verify.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for le stage `verify` du Dockerfile — l'ISO des rails se mesure au build, pas chez l'operateur
#
# ⚖ user 2026-09-04 (point 2 du chantier deploy-independance, DI-08). Le stage `runtime` refait a la
# main sept modules du rail poste, et le doctor commun ne se jouait qu'au boot : trois derives de
# l'image (groupe de `lcars-authority`, tampon `.helpers-revision`, arbre `assets/`) ont ete vues au
# premier `box up` du 04/09, jamais au build. Ces temoins tiennent la FORME du dispositif ; sa
# mesure, c'est le build lui-meme (job `image` de la CI, `box build` sur un banc).
#
# ⚠ CES TEMOINS NE BATISSENT AUCUNE IMAGE.

load ../refute

setup() {
  DF="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  [ -f "$DF" ]
  WF="$BATS_TEST_DIRNAME/../../../.gitea/workflows/gate.yml"
  MANIFEST="$BATS_TEST_DIRNAME/../../system.manifest"
}

code() { grep -vE '^\s*#|^\s*`#' "$DF"; }

@test "le stage verify EXISTE, part de runtime, et joue le doctor sur le substrat docker" {
  code | grep -qE '^FROM runtime AS verify$'
  local v; v="$(sed -n '/^FROM runtime AS verify$/,/^FROM /p' "$DF" | grep -vE '^\s*#')"
  grep -qE 'provision doctor --substrate docker' <<<"$v"
  # et il ecrit le marqueur SEULEMENT si le doctor est vert (`&&`, pas `;`)
  grep -qE 'doctor --substrate docker.*\\$' <<<"$v"
  grep -qE '^\s*&& printf .*> /verified' <<<"$v"
}

@test "verify ne demande QUE ce que l'image pose — ni volume, ni forge, ni boot" {
  local v; v="$(sed -n '/^FROM runtime AS verify$/,/^FROM /p' "$DF" | grep -vE '^\s*#')"
  local m
  # 25-directories est dans la liste depuis le lot 14 : c'est le seul module du stage qui mesure un
  # MODE (`stat`). Sa table melange volumes et /run, mais il les ecarte lui-meme sur docker, par le
  # substrat du manifeste et les VOLUME du Dockerfile (25-directories.bats, « docker : »).
  for m in 10-packages 16-node 21-service-accounts 25-directories 44-media 46-tofu 60-deploy 62-runtime-helpers 64-services; do
    grep -q -- "--only $m" <<<"$v" || { echo "verify ne demande pas $m" >&2; return 1; }
  done
  # 20-groups mesure l'appartenance du SIEGE, qui n'existe qu'au boot ; la sonde bwrap de 10-packages
  # mesure le noyau — verify la debranche (`PROV_KERNEL_PROBES=0`), elle se joue au boot.
  grep -q 'PROV_KERNEL_PROBES=0' <<<"$v"
  # ⚠ « NE DEMANDE QUE » SE MESURE PAR LE COMPLEMENT (relecture hostile 2026-09-04, M10). Une liste
  # noire de sept noms laissait huit modules dans aucune des deux listes : un `--only 49-forge-runner`
  # ajoute au stage — il parle a une forge — passait vert. Ici : tout `--only` du stage est dans la
  # liste blanche, et tout module de modules.d/ hors liste blanche est absent du stage.
  local blanche=" 10-packages 16-node 21-service-accounts 25-directories 44-media 46-tofu 60-deploy 62-runtime-helpers 64-services "
  local demande
  while read -r demande; do
    [ -n "$demande" ] || continue
    [[ "$blanche" == *" $demande "* ]] || { echo "verify demande $demande, qui n'est pas dans la liste de ce que l'image POSE" >&2; return 1; }
  done < <(grep -oE -- '--only [0-9]{2}-[a-z-]+' <<<"$v" | sed 's/^--only //')
  local f n=0
  for f in "$BATS_TEST_DIRNAME"/../../modules.d/[0-9][0-9]-*.sh; do
    m="$(basename "$f" .sh)"; n=$((n + 1))
    [[ "$blanche" == *" $m "* ]] && continue
    refute grep -q -- "--only $m" <<<"$v"
  done
  [ "$n" -ge 20 ] || { echo "seulement $n modules lus dans modules.d — l'instrument ne lit plus le repertoire" >&2; return 1; }
}

@test "deploy/ entre dans verify, a la place que le doctor connait — et c'est LA que 62 le retrouvera quand runtime ne l'aura plus" {
  local v; v="$(sed -n '/^FROM runtime AS verify$/,/^FROM /p' "$DF" | grep -vE '^\s*#')"
  grep -qE '^COPY deploy /opt/lcars/deploy$' <<<"$v"
  # la meme revision que le LABEL : 62 compare deux fois la meme verite
  grep -qE 'PROV_SOURCE_REV="\$\{GIT_SHA\}"' <<<"$v"
}

@test "final DEPEND de verify par le marqueur — un stage dont personne ne depend n'est pas bati" {
  code | grep -qE '^FROM runtime AS final$'
  code | grep -qE '^COPY --from=verify /verified /opt/lcars/.verified$'
  # et final est le DERNIER stage : c'est lui que compose et `box build` produisent sans --target
  [ "$(code | grep -E '^FROM ' | tail -n1)" = "FROM runtime AS final" ]
}

@test "le marqueur est un objet du PRODUIT — hors de la table de l'installeur, nomme par box/README" {
  # ⚖ user 2026-09-04 (Q1, lot 7) : la table n'a plus de colonne docker. Le tampon est pose par le
  # Dockerfile (stage final), lu par « box status » : l'installeur ne le pose, ne le sonde, ni ne le
  # desinstalle.
  refute grep -qE '^anchor +/opt/lcars/\.verified' "$MANIFEST"
  refute grep -qE '^(anchor|runtime|dir|file|link) +\S+ +\S+ +\S+ +docker$' "$MANIFEST"
  grep -q '\.verified' "$BATS_TEST_DIRNAME/../../../runtime/services/box/README.md"
}
@test "la CI bâtit l'image sur dood, et se declenche sur deploy/ et install.sh (DI-08)" {
  [ -f "$WF" ]
  grep -qE "^\s+- 'deploy/\*\*'$" "$WF"
  grep -qE "^\s+- 'install\.sh'$" "$WF"
  grep -qE '^\s+image:$' "$WF"
  local job; job="$(sed -n '/^  image:$/,$p' "$WF")"
  grep -qE 'runs-on: dood' <<<"$job"
  grep -qE 'docker build' <<<"$job"
  grep -qE '/opt/lcars/\.verified' <<<"$job"
  # le job ne pousse RIEN : bâtir n'est pas publier (publish.yml le fait, sur un tag)
  refute grep -qE 'docker push|docker login' <<<"$job"
}

@test "le stage RUNTIME ne porte plus deploy/ — seul verify le copie, et final repart de runtime" {
  # ⚖ user 2026-09-04 (Q1, lot 7) : rien dans la boite ne lit /opt/lcars/deploy.
  local r; r="$(sed -n '/^FROM .* AS runtime$/,/^FROM runtime AS verify$/p' "$DF" | grep -vE '^\s*#|`#')"
  refute grep -qE '^COPY deploy ' <<<"$r"
  refute grep -q '/opt/lcars/deploy' <<<"$r"
  code | grep -qE '^FROM runtime AS final$'
}
