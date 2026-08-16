# ═══════════════════════════════════════════════════════════════════════════
# LCARS Fleet — ce que la forge PORTE DÉJÀ, module INSTANCE
#
# Même mécanique que `../existing.tf`, et elle est aussi nécessaire ICI : ce module s'applique EN
# PREMIER, donc c'est LUI qui prend le 409 d'abord sur une forge existante. Une correction qui
# n'aurait porté que sur le module catalogue n'aurait jamais été atteinte.
#
# Il ne sonde que des COMPTES : ce module ne possède ni org ni team.
# ═══════════════════════════════════════════════════════════════════════════

# Le script vit dans le module parent parce qu'il est le MÊME contrat pour les deux modules, et
# qu'une seconde copie dérive. `path.module` le résout depuis l'endroit d'où l'apply est joué.
data "external" "forge" {
  program = ["${path.module}/../forge-existing.sh"]

  # Ni org ni teams : ce module n'en déclare pas. La conséquence utile est que cette sonde-ci
  # n'a besoin d'AUCUNE autorité — `/users/<login>` est public (200 anonyme, 404 sur un absent).
  query = {
    gitea_url = var.gitea_url
    org       = ""
    teams     = ""
    users     = join(",", concat([var.system_account, var.human_username], var.system_roles))
  }
}

locals {
  existing_users = {
    for k, v in data.external.forge.result : trimprefix(k, "user:") => v if startswith(k, "user:")
  }

  # Les deux comptes non indexés se rendent facultatifs par une carte à zéro ou une entrée — un bloc
  # `import` n'a pas de condition, mais un `for_each` vide ne produit aucun import.
  existing_system = { for k, v in local.existing_users : k => v if k == var.system_account }
  existing_human  = { for k, v in local.existing_users : k => v if k == var.human_username }
  existing_roles  = { for k, v in local.existing_users : k => v if contains(var.system_roles, k) }
}

import {
  for_each = local.existing_system
  to       = gitea_user.system
  id       = each.value
}

import {
  for_each = local.existing_human
  to       = gitea_user.human
  id       = each.value
}

import {
  for_each = local.existing_roles
  to       = gitea_user.system_role[each.key]
  id       = each.value
}
