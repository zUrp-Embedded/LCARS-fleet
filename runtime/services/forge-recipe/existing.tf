# ═══════════════════════════════════════════════════════════════════════════
# LCARS Fleet — ce que la forge PORTE DÉJÀ, et les imports qui en découlent
#
# Un apply à état vide contre une forge déjà provisionnée meurt en 409 « user already exists ». La
# forge est donc sondée : ce qui existe entre dans l'état par `import`, ce qui manque est créé. Un
# état perdu se reconstruit ainsi, mais ce qui ne s'importe pas serait recréé : l'appelant garde
# l'état d'une passe à l'autre (61-forge-structure sur un poste).
# ═══════════════════════════════════════════════════════════════════════════

# La sonde est un programme externe et pas une data source du provider, pour deux raisons mesurées :
# le provider n'énumère pas les comptes, et ses data sources par-objet ÉCHOUENT sur un objet absent
# — or « absent » est exactement le cas qu'il faut décrire ici.
data "external" "forge" {
  program = ["${path.module}/forge-existing.sh"]

  # Le jeton n'est PAS ici, et c'est structurel : `data.external` imprime sa query dans la sortie de
  # `tofu plan` et la garde dans le fichier de plan. Il passe par l'environnement (cf. le script).
  query = {
    gitea_url = var.gitea_url
    org       = var.org
    users     = join(",", var.roles)
    teams     = join(",", keys(local.teams))
    # le dépôt du système et ses branches, sur l'org système seule (sinon vide : pas de sonde)
    repo       = local.system_play ? var.system_repo : ""
    store      = local.system_play ? var.store_repo : ""
    branches   = local.system_play ? "tool_request,incidents" : ""
    files      = local.system_play ? "main:README.md,tool_request:README.md,tool_request:ops/toolchains.d/.gitkeep,incidents:work/README.md" : ""
    protection = local.system_play ? "tool_request" : ""
  }
}

locals {
  existing = data.external.forge.result

  # `trimprefix` et pas `replace` : un remplacement global renommerait un objet dont le nom
  # contiendrait le préfixe. Ici c'est improbable, et une improbabilité n'est pas une garantie.
  existing_roles = { for k, v in local.existing : trimprefix(k, "user:") => v if startswith(k, "user:") }
  existing_teams = { for k, v in local.existing : trimprefix(k, "team:") => v if startswith(k, "team:") }

  # Carte à zéro ou une entrée : un bloc `import` n'a pas de condition, mais un `for_each` vide ne
  # produit aucun import. C'est la forme qui rend un import FACULTATIF, et elle vaut aussi pour une
  # ressource non indexée — `to` n'a alors pas besoin de `each.key` (mesuré 2026-08-16).
  existing_org = { for k, v in local.existing : trimprefix(k, "org:") => v if startswith(k, "org:") }

  # Le dépôt du système (id numérique), ses branches (`<id du dépôt>/<nom>`), ses fichiers
  # (`<org>/<dépôt>/<branche>/<chemin encodé>`) et la protection (`<org>/<dépôt>/<règle>`) — les
  # formes que le provider rend à la création, mesurées. ⚠ LES FICHIERS DE LA BRANCHE PROTÉGÉE
  # S'IMPORTENT, ET CE N'EST PAS DU CONFORT : une fois la protection posée, le master ne peut plus y
  # commiter (« user cannot commit to repo », mesuré à état perdu sur le banc 2002) — un fichier
  # non importé serait « à créer », et l'apply mourrait dessus.
  existing_repo         = { for k, v in local.existing : trimprefix(k, "repo:") => v if startswith(k, "repo:") }
  existing_store        = { for k, v in local.existing : trimprefix(k, "store:") => v if startswith(k, "store:") }
  existing_branches     = { for k, v in local.existing : trimprefix(k, "branch:") => v if startswith(k, "branch:") }
  existing_files        = { for k, v in local.existing : trimprefix(k, "file:") => v if startswith(k, "file:") }
  existing_tool_request = { for k, v in local.existing_branches : k => v if k == "tool_request" }
  existing_incidents    = { for k, v in local.existing_branches : k => v if k == "incidents" }
  existing_protection   = { for k, v in local.existing : trimprefix(k, "protection:") => v if startswith(k, "protection:") }
}

# ⚠ LES IDENTIFIANTS SONT NUMÉRIQUES, POUR LES TROIS TYPES. Le provider convertit l'id d'import en
# entier : importer par login rend `user not found with id 0` (mesuré). Un login est un nom, pas une
# adresse.
#
# ⚠ ET UN IMPORT SUR OBJET ABSENT EST UNE PANNE DURE, pas un no-op : `id 9999` rend
# `Error: user not found with id 9999`. C'est ce qui interdit d'importer « tout ce que la recette
# déclare » et fait de la sonde ci-dessus une nécessité et non un confort.

import {
  for_each = local.existing_roles
  to       = gitea_user.role[each.key]
  id       = each.value
}

import {
  for_each = local.existing_org
  to       = gitea_org.this
  id       = each.value
}

import {
  for_each = local.existing_teams
  to       = gitea_team.this[each.key]
  id       = each.value
}

import {
  for_each = local.existing_repo
  to       = gitea_repository.ops[0]
  id       = each.value
}

import {
  for_each = local.existing_store
  to       = gitea_repository.catalogues[0]
  id       = each.value
}

import {
  for_each = { for k, v in local.existing_files : k => v if k == "store-main:README.md" }
  to       = gitea_repository_file.catalogues_readme[0]
  id       = each.value
}

import {
  for_each = local.existing_tool_request
  to       = gitea_repository_branch.tool_request[0]
  id       = each.value
}

import {
  for_each = local.existing_incidents
  to       = gitea_repository_branch.incidents[0]
  id       = each.value
}

import {
  for_each = { for k, v in local.existing_files : k => v if k == "main:README.md" }
  to       = gitea_repository_file.ops_readme[0]
  id       = each.value
}

import {
  for_each = { for k, v in local.existing_files : k => v if k == "tool_request:README.md" }
  to       = gitea_repository_file.tool_request_readme[0]
  id       = each.value
}

import {
  for_each = { for k, v in local.existing_files : k => v if k == "tool_request:ops/toolchains.d/.gitkeep" }
  to       = gitea_repository_file.tool_request_keep[0]
  id       = each.value
}

import {
  for_each = { for k, v in local.existing_files : k => v if k == "incidents:work/README.md" }
  to       = gitea_repository_file.incidents_readme[0]
  id       = each.value
}

import {
  for_each = local.existing_protection
  to       = gitea_repository_branch_protection.tool_request[0]
  id       = each.value
}

# PAS D'IMPORT POUR LES ADHÉSIONS, et c'est mesuré, pas supposé. `PUT /teams/<id>/members/<login>`
# rend 204 sur un membre qui l'est déjà, et le provider s'en contente : les 12
# `gitea_team_membership` se « créent » sur une forge où elles existent toutes, sans une erreur
# (2026-08-16). Une ressource qui converge à la création n'a rien à importer.
