#!/usr/bin/env bats
# SOURCE: deploy/tests/docker/image_verify.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for le stage `verify` du Dockerfile — l'ISO des rails se mesure au build, pas chez l'operateur
#
# ⚖ user 2026-09-04 (point 2 du chantier deploy-independance, DI-08). Le stage `runtime` refait a la
# main sept modules du rail poste, et le doctor commun ne se jouait qu'au boot : trois derives de
# l'image (groupe de `lcars-authority`, tampon `.helpers-revision`, arbre `assets/`) ont ete vues au
# premier `container up` du 04/09, jamais au build. Ces temoins tiennent la FORME du dispositif ; sa
# mesure, c'est le build lui-meme (job `image` de la CI, `container build` sur un banc).
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

@test "verify joue le doctor SANS --only, depuis la copie que 62 embarque — la selection est celle des CHECK-ON" {
  # L'ancien verify copiait deploy/ lui-meme et nommait neuf modules par --only : une selection
  # ecrite dans le Dockerfile, contre la regle « une difference de terrain s'exprime par une
  # selection d'en-tete ». Depuis que le rail pose l'image (2026-09-11), 62 embarque deploy/ sous
  # /opt/lcars comme sur un poste, et le doctor s'y joue entier : ce qui n'est pas mesurable sur
  # ce substrat le dit par CHECK-ON, pas par une liste ici.
  local v; v="$(sed -n '/^FROM runtime AS verify$/,/^FROM /p' "$DF" | grep -vE '^\s*#')"
  grep -qE '/opt/lcars/deploy/provision doctor --substrate docker' <<<"$v"
  refute grep -qE -- '--only' <<<"$v"
  refute grep -qE '^COPY ' <<<"$v"
  grep -q 'PROV_KERNEL_PROBES=0' <<<"$v"
}

@test "final DEPEND de verify par le marqueur — un stage dont personne ne depend n'est pas bati" {
  code | grep -qE '^FROM runtime AS final$'
  code | grep -qE '^COPY --from=verify /verified /opt/lcars/.verified$'
  # et final est le DERNIER stage : c'est lui que compose et `container build` produisent sans --target
  [ "$(code | grep -E '^FROM ' | tail -n1)" = "FROM runtime AS final" ]
}

@test "le marqueur est un objet du PRODUIT — hors de la table de l'installeur, nomme par container/README" {
  # ⚖ user 2026-09-04 (Q1, lot 7) : la table n'a plus de colonne docker. Le tampon est pose par le
  # Dockerfile (stage final), lu par « container status » : l'installeur ne le pose, ne le sonde, ni ne le
  # desinstalle.
  refute grep -qE '^anchor +/opt/lcars/\.verified' "$MANIFEST"
  refute grep -qE '^(anchor|runtime|dir|file|link) +\S+ +\S+ +\S+ +docker$' "$MANIFEST"
  grep -q '\.verified' "$BATS_TEST_DIRNAME/../../../runtime/services/container/README.md"
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
