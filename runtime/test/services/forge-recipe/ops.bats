#!/usr/bin/env bats
# SOURCE: runtime/test/services/forge-recipe/ops.bats
# AUTHOR: bob
# STARDATE: 2026-09-16
# STATUS: temoin de forme de forge-recipe/ops.tf — le depot du systeme est declare par la recette, pour l'org systeme seule
#
# La recette a ete jouee pour de vrai sur la forge du banc 2002 le 2026-09-16 (org sonde) : 17
# ressources ; second apply avec l'etat garde, seul le bruit connu des teams (C-12) ; apply a ETAT
# PERDU, 14 ressources importees et rien de recree ; destroy propre. Ce temoin ne rejoue pas tofu :
# il tient la FORME qui a ete mesuree — ce que la recette declare, sous quelle condition, et ce
# qu'elle ne declare pas.

setup() {
  RECIPE="$BATS_TEST_DIRNAME/../../../services/forge-recipe"
  TF="$RECIPE/ops.tf"
  [ -f "$TF" ]
}

@test "le depot, deux branches, quatre fichiers et une protection sont declares — chacun conditionne sur l'org systeme" {
  local r n
  for r in 'resource "gitea_repository" "ops"' 'resource "gitea_repository_branch" "tool_request"' \
           'resource "gitea_repository_branch" "incidents"' 'resource "gitea_repository_file" "ops_readme"' \
           'resource "gitea_repository_file" "tool_request_readme"' 'resource "gitea_repository_file" "tool_request_keep"' \
           'resource "gitea_repository_file" "incidents_readme"' 'resource "gitea_repository_branch_protection" "tool_request"'; do
    grep -q "^$r {" "$TF" || { echo "manque : $r" >&2; return 1; }
  done
  n="$(grep -c '^  count *= local.system_play ? 1 : 0$' "$TF")"
  [ "$n" -eq 10 ] || { echo "$n ressources conditionnees sur l'org systeme, attendu 10" >&2; return 1; }
  grep -q '^  system_play = var.org == var.system_org$' "$TF"
}

@test "les noms sont ceux que le runtime lit : _ops, tool_request, incidents, ops/toolchains.d, work/" {
  grep -q '^  default     = "_ops"$' "$TF"
  grep -q '^  name       = "tool_request"$' "$TF"
  grep -q '^  name       = "incidents"$' "$TF"
  grep -q 'file_path      = "ops/toolchains.d/.gitkeep"' "$TF"
  grep -q 'file_path      = "work/README.md"' "$TF"
  # le nom de la branche du registre est celui du store du pilote
  grep -q ':pilot_incident_registry_branch, "incidents")' "$BATS_TEST_DIRNAME/../../../lib/fleet/pilot/incident_registry/store.ex"
}

@test "la protection de tool_request : une approbation du siege (variable approvers, sans defaut nomme, refusee vide), reapprobation a chaque push, le siege seul pousse, l admin ne contourne pas" {
  grep -q '^  required_approvals              = 1$' "$TF"
  grep -q '^  dismiss_stale_approvals         = true$' "$TF"
  grep -q '^  approval_whitelist_users        = var.approvers$' "$TF"
  grep -q '^  block_merge_on_rejected_reviews = true$' "$TF"
  # le siege seul pousse directement (les semences) ; le compte systeme n'est pas dans la liste
  grep -q '^  enable_push          = true$' "$TF"
  grep -q '^  push_whitelist_users = var.approvers$' "$TF"
  grep -q '^  block_admin_merge_override = true$' "$TF"
  grep -q 'condition     = !local.system_play || length(var.approvers) > 0' "$TF"
  # `approvers` : une liste, vide par defaut — c'est cmd_apply qui la remplit avec le siege resolu
  grep -A3 '^variable "approvers" {' "$TF" | grep -q 'default     = \[\]'
}

@test "les branches sont adressees par l'ID numerique du depot (mesure : le provider refuse un nom), et les semences existent" {
  [ "$(grep -c '^  repository = gitea_repository.ops\[0\].id$' "$TF")" -eq 2 ]
  [ -f "$RECIPE/ops/README.md" ]
  [ -f "$RECIPE/ops/tool_request.README.md" ]
  [ -f "$RECIPE/ops/incidents.README.md" ]
  grep -q 'ops/toolchains.d' "$RECIPE/ops/tool_request.README.md"
  grep -q 'system-incidents.json' "$RECIPE/ops/incidents.README.md"
}

# ⚠ LE MAGASIN DES CATALOGUES EST POSE PAR LA RECETTE, COMME `_ops` — et pour la meme raison : deux
# poseurs pour un objet, c'est un objet que personne ne tient. Ce que la recette NE pose pas, ce sont
# ses branches : elles arrivent par `catalogue install`, une par catalogue installe.
@test "le magasin des catalogues est declare, avec son README, sur l'org systeme seule" {
  grep -q '^resource "gitea_repository" "catalogues" {$' "$TF"
  grep -q '^resource "gitea_repository_file" "catalogues_readme" {$' "$TF"
  grep -A3 '^variable "store_repo" {' "$TF" | grep -q 'default     = "_catalogues"'
  # le nom du depot est celui que le produit declare, et que les deux ecrivains shell recopient
  grep -q '@store_name "_catalogues"' "$BATS_TEST_DIRNAME/../../../lib/fleet/catalogue.ex"
  [ -f "$RECIPE/ops/catalogues.README.md" ]
  # aucune branche de catalogue n'est declaree ici : elles viennent de `catalogue install`
  ! grep -q 'gitea_repository_branch" "[a-z-]*catalogue' "$TF"
}

@test "le geste de forge ne pose plus le depot ni la protection : ni ensure_ops_repo ni toolchain-protection" {
  ! grep -q 'ensure_ops_repo\|toolchain-protection\|branch_protections' "$RECIPE/../forge-gestures.sh"
}

# ⚠ UN ETAT PERDU NE RECREE PAS CE QUI EXISTE, et pour le depot du systeme c'est une PANNE et pas un
# bruit : la protection de `tool_request` interdit au master d'y commiter (mesure : « user cannot
# commit to repo »), donc un fichier non importe tue l'apply. La sonde les cherche, les imports les
# reprennent, et les attributs d'ECRITURE que le provider ne relit pas sont ignores.
@test "l'etat perdu se reconstruit : depot, branches, fichiers et protection sont sondes puis importes" {
  local ex="$RECIPE/existing.tf" sonde="$RECIPE/forge-existing.sh"
  # la sonde recoit ce qu'il faut chercher, sur l'org systeme SEULE
  grep -qE '^ +repo +=' "$ex" && grep -q 'local.system_play ? var.system_repo : ""' "$ex"
  grep -q 'local.system_play ? "tool_request,incidents" : ""' "$ex"
  grep -qE '^ +files +=' "$ex"
  grep -q 'local.system_play ? "tool_request" : ""' "$ex"
  # et elle les rend, chacun sous la forme d'id que le provider attend
  grep -q 'add "repo:\$REPO" "\$REPO_ID"' "$sonde"
  grep -q 'add "branch:\$b" "\$REPO_ID/\$b"' "$sonde"
  grep -q 'add "file:\$f" "\$ORG/\$REPO/\$fb/\${fp//' "$sonde"
  grep -q 'add "protection:\$PROTECTION" "\$ORG/\$REPO/\$PROTECTION"' "$sonde"
  # un import par objet : le depot, deux branches, quatre fichiers, la protection
  local n
  n="$(grep -c 'to       = gitea_repository' "$ex")"
  [ "$n" -eq 10 ] || { echo "$n imports vers des objets de depot, attendu 10" >&2; return 1; }
  grep -q 'local.system_play ? var.store_repo : ""' "$ex"
  grep -q 'add "store:\$STORE" "\$STORE_ID"' "$sonde"
  # les attributs d'ecriture que le provider ne relit pas ne font pas rejouer un update
  [ "$(grep -c 'ignore_changes = \[encoding, overwrite, commit_message\]' "$TF")" -eq 5 ]
}
