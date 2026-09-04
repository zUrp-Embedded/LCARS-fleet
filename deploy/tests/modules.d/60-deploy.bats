#!/usr/bin/env bats
# SOURCE: deploy/tests/modules.d/60-deploy.bats
# AUTHOR: bob
# STARDATE: 2026-09-04
# STATUS: bats tests for 60-deploy — le raccourci « rien a batir » lit le VRAI arbre du runtime
#
# Relecture hostile 2026-09-04 : `git diff --quiet HEAD -- fleet` rendait toujours 0 (un pathspec
# vide n'est pas une erreur pour git diff), donc « l'arbre du runtime est propre » etait
# inconditionnellement vrai, et un apply sur un checkout modifie sautait la construction.

load ../refute

setup() { MOD="$BATS_TEST_DIRNAME/../../modules.d/60-deploy.sh"; [ -f "$MOD" ]; }

@test "le pathspec du raccourci est runtime/ — un arbre qui n'existe pas rendrait toujours « propre »" {
  grep -vE '^\s*#' "$MOD" | grep -qE 'diff --quiet HEAD -- runtime'
  refute grep -qE 'diff --quiet HEAD -- fleet' <(grep -vE '^\s*#' "$MOD")
  [ -d "$BATS_TEST_DIRNAME/../../../runtime" ]
}

@test "TEMOIN DU TEMOIN : sur ce depot, un pathspec inexistant rend 0 et le vrai rend un verdict" {
  local repo; repo="$BATS_TEST_DIRNAME/../../.."
  git -C "$repo" diff --quiet HEAD -- nexistepas ; [ "$?" -eq 0 ]
  git -C "$repo" ls-files runtime | grep -q .
}
