# ═══════════════════════════════════════════════════════════════════════════
# `_ops` — LE DÉPÔT DU SYSTÈME, posé par la recette et par personne d'autre
#
# Le runtime le LIT et y ÉCRIT (demandes d'outillage, registre d'incidents, escalades) ; il ne le
# CRÉE pas, ni ses branches — un runtime qui pose ses propres branches à l'envie est ce qu'on a
# mesuré sur le banc beta (⚖ user 2026-09-16) : un registre écrit sur une branche que rien n'avait
# créée, 380 échecs en onze heures. Ici tout est déclaré, et le geste `forge.d/ops-repo.sh` VÉRIFIE.
#
# SEULEMENT DANS L'ORG SYSTÈME : `count` sur `var.org == var.system_org`, comme la team `humans`.
# Un play de catalogue (`cmd_install`) ne pose aucun dépôt.
#
# ⚠ LES BRANCHES SONT DES FILLES DE `main`, et ce n'est plus un problème : `main` ne porte que le
# README de ce dépôt. L'orpheline d'avant existait parce que `main` portait TOUT LE CODE de LCARS
# (le dépôt système était aussi la source), et une PR de manifeste se serait lue contre lui.
#
# ⚠ SCHÉMA DU PROVIDER 0.8.1, lu sur le banc 2002 (`tofu providers schema -json`) :
#   gitea_repository_branch            : name, repository (l'ID NUMÉRIQUE du dépôt, pas son nom ; aucune base : fille de la branche par défaut)
#   gitea_repository_file              : username, name, file_path, content, branch, commit_message, overwrite
#   gitea_repository_branch_protection : username, name, rule_name, required_approvals,
#                                        dismiss_stale_approvals, enable_approval_whitelist,
#                                        approval_whitelist_users, block_merge_on_rejected_reviews, enable_push…
# ═══════════════════════════════════════════════════════════════════════════

variable "system_repo" {
  type        = string
  description = "Le dépôt du système dans l'org système — `Fleet.Toolchain.ops_repo/0` en porte l'adresse complète"
  default     = "_ops"
}

# LE MAGASIN DES CATALOGUES : une branche par catalogue installé (⚖ user 2026-09-16). Ce dépôt est le
# seul endroit où la question « quels catalogues sont installés ? » se pose — une liste de branches,
# pas une recherche sur tous les dépôts de la forge. `Fleet.Catalogue.store_repo/0` en est l'autorité
# côté produit, `catalogue install` écrit ses branches, le geste `catalogues` les lit.
variable "store_repo" {
  type        = string
  description = "Le magasin des catalogues dans l'org système — une branche par catalogue installé"
  default     = "_catalogues"
}

# LES APPROBATEURS DE `tool_request` : le siège — le master, compte n°1 de la forge, celui qui
# installe. `cmd_apply` le résout par `/api/v1/user` avec le jeton master et le passe ici. PAS la
# team `humans` : un manifeste d'outillage est appliqué par root sur le conteneur, et signer ça est
# l'affaire de l'admin du système, pas d'une personne de fleet.
variable "approvers" {
  type        = list(string)
  description = "Logins autorisés à approuver une PR vers tool_request — le siège, résolu par cmd_apply"
  default     = []
}

locals {
  system_play = var.org == var.system_org
}

resource "gitea_repository" "ops" {
  count             = local.system_play ? 1 : 0
  username          = gitea_org.this.name
  name              = var.system_repo
  description       = "Le dépôt du système LCARS : demandes d'outillage (tool_request), registre d'incidents (incidents), escalades (issues)."
  private           = false
  auto_init         = true
  default_branch    = "main"
  has_issues        = true
  has_pull_requests = true
  # ⚠ MESURÉ (banc 2002, provider 0.8.1) : `has_wiki = false` et `has_projects = false` sont replanifiés
  # à CHAQUE apply — la forge les garde vrais, l'update ne prend pas. Non déclarés, donc : un wiki
  # que personne n'ouvre ne coûte rien, un plan qui ment à chaque passe coûte la lecture du plan.
  # `ignore_whitespace_conflicts` : le défaut du provider (true) n'est pas celui de la forge (false).
  ignore_whitespace_conflicts = false
  # `migration_mirror_interval` : un defaut du provider pour les miroirs, replanifie a chaque passe
  # sur un depot qui n'en est pas un (mesure). Valeur valide, donc `ignore_changes` ne mord pas ici.
  lifecycle {
    ignore_changes = [migration_mirror_interval]
  }
  # POSÉ APRÈS LA PROPRIÉTÉ : le compte système écrit ici par la team `system` (write, toutes les
  # dépôts de l'org), et lit la protection de `tool_request` en tant que propriétaire de l'org
  # (`Owners`) — le geste `ops-repo` en dépend. L'arête dit l'ordre.
  depends_on = [gitea_team_membership.owner]
}

resource "gitea_repository" "catalogues" {
  count          = local.system_play ? 1 : 0
  username       = gitea_org.this.name
  name           = var.store_repo
  description    = "Le magasin des catalogues installés : une branche par catalogue, poussée par « lcars catalogue install »."
  private        = false
  auto_init      = true
  default_branch = "main"
  # ⚠ `has_issues` / `has_pull_requests` NE SONT PAS DÉCLARÉS, et ce n'est pas un oubli : ce dépôt
  # n'est un lieu de travail pour personne, mais la forge ne reprend pas ces deux réglages (mesuré
  # sur le banc 2002 : posés `false`, relus `true`, replanifiés à chaque passe — même défaut que
  # `has_wiki` sur `_ops`). Un plan qui ment à chaque apply coûte plus cher que deux onglets que
  # personne n'ouvre.
  ignore_whitespace_conflicts = false

  lifecycle {
    ignore_changes = [migration_mirror_interval]
  }

  depends_on = [gitea_team_membership.owner]
}

resource "gitea_repository_file" "catalogues_readme" {
  count          = local.system_play ? 1 : 0
  username       = gitea_org.this.name
  name           = gitea_repository.catalogues[0].name
  branch         = "main"
  file_path      = "README.md"
  content        = file("${path.module}/ops/catalogues.README.md")
  commit_message = "catalogues: ce que ce dépôt est, et qui y écrit"
  overwrite      = true

  lifecycle {
    ignore_changes = [encoding, overwrite, commit_message]
  }
}

resource "gitea_repository_file" "ops_readme" {
  count          = local.system_play ? 1 : 0
  username       = gitea_org.this.name
  name           = gitea_repository.ops[0].name
  branch         = "main"
  file_path      = "README.md"
  content        = file("${path.module}/ops/README.md")
  commit_message = "ops: ce que ce dépôt est, branche par branche"
  overwrite      = true
  # `encoding` et `overwrite` sont des attributs d'ÉCRITURE que le provider ne relit pas : après un
  # import (état perdu), il les replanifie — et sur la branche protégée l'update meurt (mesuré). Le
  # contenu, lui, se compare.
  lifecycle {
    ignore_changes = [encoding, overwrite, commit_message]
  }
}

resource "gitea_repository_branch" "tool_request" {
  count      = local.system_play ? 1 : 0
  repository = gitea_repository.ops[0].id
  name       = "tool_request"
  depends_on = [gitea_repository_file.ops_readme]
}

resource "gitea_repository_branch" "incidents" {
  count      = local.system_play ? 1 : 0
  repository = gitea_repository.ops[0].id
  name       = "incidents"
  depends_on = [gitea_repository_file.ops_readme]
}

resource "gitea_repository_file" "tool_request_readme" {
  count          = local.system_play ? 1 : 0
  username       = gitea_org.this.name
  name           = gitea_repository.ops[0].name
  branch         = gitea_repository_branch.tool_request[0].name
  file_path      = "README.md"
  content        = file("${path.module}/ops/tool_request.README.md")
  commit_message = "ops(toolchain): la boîte aux lettres des demandes d'outillage"
  overwrite      = true
  # `encoding` et `overwrite` sont des attributs d'ÉCRITURE que le provider ne relit pas : après un
  # import (état perdu), il les replanifie — et sur la branche protégée l'update meurt (mesuré). Le
  # contenu, lui, se compare.
  lifecycle {
    ignore_changes = [encoding, overwrite, commit_message]
  }
}

# Le dossier des manifestes existe dès le départ : le convergeur lit `ops/toolchains.d/*.yaml` au
# SHA mergé, et une PR y ajoute son manifeste sans avoir à créer l'arborescence.
resource "gitea_repository_file" "tool_request_keep" {
  count          = local.system_play ? 1 : 0
  username       = gitea_org.this.name
  name           = gitea_repository.ops[0].name
  branch         = gitea_repository_branch.tool_request[0].name
  file_path      = "ops/toolchains.d/.gitkeep"
  content        = "\n"
  commit_message = "ops(toolchain): le dossier des manifestes"
  overwrite      = true
  # `encoding` et `overwrite` sont des attributs d'ÉCRITURE que le provider ne relit pas : après un
  # import (état perdu), il les replanifie — et sur la branche protégée l'update meurt (mesuré). Le
  # contenu, lui, se compare.
  lifecycle {
    ignore_changes = [encoding, overwrite, commit_message]
  }
  depends_on = [gitea_repository_file.tool_request_readme]
}

resource "gitea_repository_file" "incidents_readme" {
  count          = local.system_play ? 1 : 0
  username       = gitea_org.this.name
  name           = gitea_repository.ops[0].name
  branch         = gitea_repository_branch.incidents[0].name
  file_path      = "work/README.md"
  content        = file("${path.module}/ops/incidents.README.md")
  commit_message = "ops(incident): le registre du pilote"
  overwrite      = true
  # `encoding` et `overwrite` sont des attributs d'ÉCRITURE que le provider ne relit pas : après un
  # import (état perdu), il les replanifie — et sur la branche protégée l'update meurt (mesuré). Le
  # contenu, lui, se compare.
  lifecycle {
    ignore_changes = [encoding, overwrite, commit_message]
  }
}

# ⚠ UN APPROBATEUR SANS ÉCRITURE N'EST PAS UN APPROBATEUR. Gitea EXIGE `write` sur le dépôt pour
# retenir un compte dans `approval_whitelist_users` ; en dessous, il le RETIRE EN SILENCE et laisse
# la whitelist activée et VIDE — donc une demande d'outil qu'aucune signature ne peut débloquer.
# Mesuré le 2026-09-17 sur le banc 2003, sur les quatre niveaux : aucun accès (le siège est pourtant
# site-admin de la forge) et `read` sont écartés, `write` et `admin` sont retenus. C'est `write`, le
# plancher, et pas `admin` : un approbateur n'a pas à administrer ce qu'il signe.
#
# La portée est CE DÉPÔT, jamais l'org système : le siège n'en devient pas membre. Ce que `write`
# ouvrirait par ailleurs — un push libre sur les autres branches — est refermé juste en dessous,
# par la protection de `main` et de `incidents`.
resource "gitea_repository_collaborator" "approvers" {
  for_each   = local.system_play ? toset(var.approvers) : toset([])
  owner      = gitea_org.this.name
  repo       = gitea_repository.ops[0].name
  username   = each.value
  permission = "write"
}

# ⚠ `main` PORTE LE CONTRAT DU DÉPÔT, et `incidents` le registre que le pilote écrit. Ni l'un ni
# l'autre ne se pousse à la main : le premier est semé par cette recette, le second par le runtime,
# et un `write` accordé pour APPROUVER ne doit pas devenir un droit d'écrire partout. Pas
# d'approbation exigée ici — ce n'est pas une boîte aux lettres à réviser, c'est une branche que
# personne ne pousse : la liste de push vide dit exactement ça.
resource "gitea_repository_branch_protection" "main" {
  count                = local.system_play ? 1 : 0
  username             = gitea_org.this.name
  name                 = gitea_repository.ops[0].name
  rule_name            = "main"
  enable_push          = true
  push_whitelist_users = var.approvers
  # le compte systeme est proprietaire de l'org, donc admin du depot : sans ce verrou il passe outre
  block_admin_merge_override = true
  depends_on                 = [gitea_repository_file.ops_readme]
}

resource "gitea_repository_branch_protection" "incidents" {
  count     = local.system_play ? 1 : 0
  username  = gitea_org.this.name
  name      = gitea_repository.ops[0].name
  rule_name = gitea_repository_branch.incidents[0].name
  # LE RUNTIME ÉCRIT ICI, par le compte système : c'est le registre des incidents du pilote, pas une
  # branche de revue. La protection existe pour que le `write` d'un approbateur ne l'ouvre pas.
  enable_push                = true
  push_whitelist_users       = [var.system_account]
  block_admin_merge_override = true
  depends_on                 = [gitea_repository_file.incidents_readme]
}

# ⚠ LA PROTECTION ET LA CONFIG `:toolchain_auto_merge` VONT ENSEMBLE : armer l'auto-merge sur une
# branche sans protection, c'est « conditions remplies » tout de suite, donc un merge sans signature
# avec le convergeur derrière. `dismiss_stale_approvals` : un re-push tue l'approbation. Sans status
# check : l'allumage est en deux temps, le contexte viendra avec son job. Le siège seul pousse
# directement (semences) ; le runtime n'entre que par une PR.
resource "gitea_repository_branch_protection" "tool_request" {
  count                           = local.system_play ? 1 : 0
  username                        = gitea_org.this.name
  name                            = gitea_repository.ops[0].name
  rule_name                       = gitea_repository_branch.tool_request[0].name
  required_approvals              = 1
  dismiss_stale_approvals         = true
  approval_whitelist_users        = var.approvers
  block_merge_on_rejected_reviews = true
  # Le compte système est propriétaire de l'org, donc admin du dépôt, et c'est lui qui arme
  # l'auto-merge : sans ce verrou, un admin passe outre les approbations.
  block_admin_merge_override = true
  # SEUL LE SIÈGE POUSSE DIRECTEMENT — pour que la recette puisse un jour changer les semences de
  # cette branche (une fois la protection posée, un push hors liste est refusé, mesuré : « user
  # cannot commit to repo »). Le compte système n'y est pas : le runtime n'entre que par une PR.
  enable_push          = true
  push_whitelist_users = var.approvers
  depends_on           = [gitea_repository_file.tool_request_keep]

  lifecycle {
    # SANS APPROBATEUR, LA PROTECTION EST OUVERTE : une liste vide veut dire « toute review d'un
    # compte en écriture compte » — les bots. Une recette jouée sans `cmd_apply` (qui résout le
    # siège) refuse ici plutôt que de poser une signature que personne ne donne.
    precondition {
      condition     = !local.system_play || length(var.approvers) > 0
      error_message = "approvers est vide : la protection de tool_request n'aurait aucun signataire — cmd_apply résout le siège (/api/v1/user) et le passe en -var approvers."
    }
  }
}
