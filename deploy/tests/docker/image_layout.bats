#!/usr/bin/env bats
# bats file_tags=structure
# SOURCE: deploy/tests/docker/image_layout.bats
# AUTHOR: bob
# STARDATE: 2026-09-11
# STATUS: bats tests for le Dockerfile — l'image est POSEE PAR LE RAIL, et ce fichier ne pose rien que le rail pose
#
# Jusqu'au 2026-09-11 ce corpus tenait le stage runtime d'accord avec la table de l'installeur :
# chaque `install -d`, chaque `COPY --chmod`, chaque `chmod -R` du Dockerfile compare au mode que
# system.manifest declare — neuf temoins pour un jumeau. Le jumeau est parti (02-CIBLE § 3, spike du
# 2026-09-10) : l'image se batit par `provision apply --substrate docker` depuis le kit, donc ce que
# la table declare est pose par les MEMES modules que sur un poste, et se mesure par les temoins de
# ces modules. Ce qui reste a tenir ici, c'est que le Dockerfile ne redevienne pas un jumeau.
#
# ⚠ CES TEMOINS NE BATISSENT AUCUNE IMAGE. Ils lisent le Dockerfile.

load ../refute

setup() {
  DF="$BATS_TEST_DIRNAME/../../docker/Dockerfile"
  [ -f "$DF" ]
  CODE="$(grep -vE '^\s*#|^\s*$' "$DF")"
  RUNTIME="$(sed -n '/^FROM .* AS runtime$/,/^FROM runtime AS verify$/p' "$DF" | grep -vE '^\s*#')"
  [ -n "$RUNTIME" ]
}

@test "TROIS stages, et un seul qui pose : runtime (le rail), verify (le doctor), final (la preuve)" {
  [ "$(grep -cE '^FROM ' <<<"$CODE")" -eq 3 ]
  grep -qE '^FROM \$\{BASE_IMAGE\} AS runtime$' <<<"$CODE"
  grep -qE '^FROM runtime AS verify$' <<<"$CODE"
  grep -qE '^FROM runtime AS final$' <<<"$CODE"
  # plus de stage build, plus de stage site : la release et la doc arrivent dans le kit
  refute grep -qE 'AS (build|site)$' <<<"$CODE"
  refute grep -qE '^COPY --from=(build|site)' <<<"$CODE"
}

@test "LE RAIL POSE L'IMAGE : un COPY du kit, un provision apply --substrate docker, et aucun --only" {
  [ "$(grep -cE '^COPY ' <<<"$RUNTIME")" -eq 1 ]
  grep -qE '^COPY --chown=builder:builder \. /src/lcars_install$' <<<"$RUNTIME"
  grep -qE 'deploy/provision apply --substrate docker --human builder' <<<"$RUNTIME"
  refute grep -qE -- '--only' <<<"$CODE"
  # les sondes noyau sont desarmees au build : ce noyau n'est pas celui de la cible
  local n_probe n_apply
  n_probe="$(grep -n 'PROV_KERNEL_PROBES=0' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  n_apply="$(grep -n 'provision apply --substrate docker' <<<"$RUNTIME" | head -1 | cut -d: -f1)"
  [ -n "$n_probe" ]
  [ -n "$n_apply" ]
  [ "$n_probe" -le "$n_apply" ]
  [ $((n_apply - n_probe)) -le 2 ]
  # et le kit n'est pas livre : /src part
  grep -qE 'cd / && rm -rf /src' <<<"$RUNTIME"
}

@test "LE DOCTOR VERIFIE SOUS LE MEME SIEGE QUE LE RAIL, et builder ne part qu'au stage final" {
  local v f
  v="$(sed -n '/^FROM runtime AS verify$/,/^FROM /p' "$DF" | grep -vE '^\s*#')"
  f="$(sed -n '/^FROM runtime AS final$/,$p' "$DF" | grep -vE '^\s*#')"
  grep -qE 'provision doctor --substrate docker --human builder' <<<"$v"
  refute grep -q 'userdel -r builder' <<<"$RUNTIME"
  grep -qE '^RUN userdel -r builder$' <<<"$f"
}

@test "LE SOCLE SEUL : une liste apt, sans pin, sans sha256, sans version — tout pin vit dans un module" {
  [ "$(grep -cE 'apt-get install' <<<"$RUNTIME")" -eq 1 ]
  # aucun sha256 hors le digest de la base, aucun ARG de version d'outil
  [ "$(grep -cE 'sha256' <<<"$CODE")" -eq 1 ]
  grep -qE '^ARG BASE_IMAGE=ubuntu:[0-9.]+@sha256:[0-9a-f]{64}$' <<<"$CODE"
  refute grep -qE '^ARG (ELIXIR|TOFU|XTERM|NODE)' <<<"$CODE"
  refute grep -qE 'curl .*(github.com|get.opentofu|jsdelivr|nodejs.org)' <<<"$CODE"
  # aucun compte de service, aucun groupe, aucun repertoire du produit pose a la main
  refute grep -qE 'groupadd|useradd --system' <<<"$CODE"
  refute grep -qE '^RUN install -d' <<<"$CODE"
  refute grep -qE 'chown -R|chmod -R' <<<"$CODE"
}

@test "L'UID 1000 est libere AVANT le rail, et repris APRES — le siege du boot le trouve libre" {
  local socle; socle="$(sed -n '/^RUN apt-get update/,/mkdir -p \/run\/sshd/p' "$DF")"
  grep -q 'userdel -r "$(getent passwd 1000 | cut -d: -f1)"' <<<"$socle"
  grep -q 'useradd -m -u 1000 -s /bin/bash builder' <<<"$socle"
  local n_del n_use n_rail
  n_del="$(grep -nF 'userdel -r "$(getent passwd 1000' <<<"$CODE" | head -1 | cut -d: -f1)"
  n_use="$(grep -n 'useradd -m -u 1000' <<<"$CODE" | head -1 | cut -d: -f1)"
  n_rail="$(grep -n 'provision apply --substrate docker' <<<"$CODE" | head -1 | cut -d: -f1)"
  [ -n "$n_del" ]
  [ -n "$n_use" ]
  [ -n "$n_rail" ]
  [ "$n_del" -lt "$n_use" ]
  [ "$n_use" -lt "$n_rail" ]
  grep -q 'userdel -r builder' <<<"$CODE"
}

@test "LA REVISION a UNE origine, l'ARG GIT_SHA, et elle arrive au rail (PROV_SOURCE_REV), a l'ENV et au LABEL" {
  grep -qE '^ENV PROV_SOURCE_REV=\$\{GIT_SHA\} LCARS_IMAGE_REVISION=\$\{GIT_SHA\}' <<<"$CODE"
  grep -qE 'org.opencontainers.image.revision="\$\{GIT_SHA\}"' <<<"$CODE"
  # verify la redonne au doctor, sinon 62 compare la copie posee a « inconnue »
  local v; v="$(sed -n '/^FROM runtime AS verify$/,/^FROM /p' "$DF" | grep -vE '^\s*#')"
  grep -qE 'PROV_SOURCE_REV="\$\{GIT_SHA\}"' <<<"$v"
}

@test "CE QUE SEULE L'IMAGE PORTE, et rien de plus : volumes, port, healthcheck, entrypoint du produit" {
  grep -qE '^VOLUME \["/home", "/opt/lcars/var"\]$' <<<"$CODE"
  grep -qE '^EXPOSE 22$' <<<"$CODE"
  grep -qE '^HEALTHCHECK ' <<<"$CODE"
  grep -qE '^ENTRYPOINT \["/usr/bin/tini", "--", "bash", "/opt/lcars/services/container/boot.sh"\]$' <<<"$CODE"
  # tini et sshd viennent du socle, pas d'un module : ils n'ont pas de sens sur un poste
  grep -qE '^\s+ca-certificates curl git sudo tini openssh-server \\$' <<<"$RUNTIME"
}
