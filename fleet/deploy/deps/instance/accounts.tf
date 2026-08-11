# ═══════════════════════════════════════════════════════════════════════════
# LCARS Fleet — empreinte forge, module INSTANCE
#
# Ce que ce module possede : les comptes qui ne dependent d'AUCUN catalogue et
# vivent une fois par forge — le systeme, starfleet, l'humain, et les roles de
# MECANIQUE (`system_*`), la meme autorite dans toutes les orgs.
#
# POURQUOI IL EXISTE, ET C'EST UNE MESURE. Un apply = un DOSSIER, et
# `enroll-catalogue --tofu-dir` ecrit un tfvars par catalogue : le modele est
# donc « un apply par catalogue ». Les comptes ci-dessous etant partages, chaque
# apply de catalogue tenterait de les creer, et Gitea rend « user already
# exists » (mesure sur la forge du banc, 2026-08-11). Les sortir ici est la
# seule facon qu'un second catalogue s'enrole sans detruire le premier.
#
# ORDRE : ce module s'applique AVANT tout module catalogue. Une adhesion peut
# nommer un compte qu'elle ne cree pas, mais pas un compte qui n'existe pas —
# l'inversion echoue en 404 cote Gitea, bruyamment, jamais en silence.
# ═══════════════════════════════════════════════════════════════════════════

provider "gitea" {
  base_url = var.gitea_url
  token    = var.gitea_token
}

variable "system_roles" {
  type        = list(string)
  description = "Comptes de role SYSTEME, partages par tous les catalogues — derive du catalogue"
  default     = ["system_architect", "system_chief", "system_gatekeeper"]
}

variable "role_names" {
  type        = map(string)
  description = "login -> nom du role, pose en full_name (l'UI l'affiche a la place du login)"
  default = {
    system_architect  = "architect"
    system_chief      = "chief"
    system_gatekeeper = "gatekeeper"
  }
}

resource "gitea_user" "system" {
  username             = "lcars-system"
  login_name           = "lcars-system"
  email                = "lcars-system@lcars.local"
  password             = var.seed_password
  must_change_password = false
  admin                = false # PAS site-admin : org-power via la team `system`, blast-radius borné à l'org
  # Hardening : lcars-system crée des repos DANS l'org (team can_create_repos), jamais de
  # nouvelle org ; aucun git-hook serveur ni import local (vecteurs d'exécution sur l'hôte forge).
  allow_create_organization = false
  allow_git_hook            = false
  allow_import_local        = false
}

# ⚠ PIÈGE provider (constaté 2026-07-30, drill docker) : le password n'est réellement posé
# qu'à la CRÉATION. Un changement de `seed_password` sur des comptes existants rend un plan
# « changed » VERT mais ne change PAS le password côté forge (basic-auth : « invalid username,
# password or token »). Rotation réelle = API admin PATCH /admin/users/{u} (exige login_name
# dans le body) puis re-mint A4 — jamais « tofu apply » seul.
resource "gitea_user" "system_role" {
  for_each             = toset(var.system_roles)
  username             = each.key
  login_name           = each.key
  # Le LOGIN porte le catalogue (`<catalogue>_<role>`), parce qu'un username Gitea est unique a
  # l'INSTANCE : sans prefixe, deux catalogues nommant chacun un `dev` se partagent un compte et un
  # jeton, avec ecriture sur les deux orgs. Le `full_name` porte le nom du role, et l'UI l'affiche a
  # la place du login sous `[ui] DEFAULT_SHOW_FULL_NAME` (cable dans forge-compose.yml pour la forge
  # de banc ; geste d'operateur sur une forge preexistante) — le prefixe ne subsiste alors que
  # dans l'URL et l'API. Le defaut `each.key` vaut pour un deploiement qui n'apporte pas la table.
  full_name            = lookup(var.role_names, each.key, each.key)
  email                = "${each.key}@lcars.local"
  password             = var.seed_password
  must_change_password = false
  admin                = false
  # Hardening : un rôle ne crée ni org, ni git-hook serveur, ni import local.
  allow_create_organization = false
  allow_git_hook            = false
  allow_import_local        = false
}

resource "gitea_user" "starfleet" {
  username             = "starfleet"
  login_name           = "starfleet"
  email                = "starfleet@lcars.local"
  password             = var.seed_password
  must_change_password = false
  admin                = true # site-admin : l'identité d'ONBOARDING (créer des users = op site-admin)
}

resource "gitea_user" "human" {
  username             = var.human_username
  login_name           = var.human_username
  email                = var.human_email
  password             = var.seed_password
  must_change_password = true  # daily : l'humain pose son propre secret au 1er login
  admin                = false # NON site-admin : l'humain opère VIA la fleet, pas par gestes forge manuels
  # Hardening : l'humain daily ne crée ni org, ni git-hook serveur, ni import local
  # (le break-glass, c'est le compte admin de l'installeur, pas ce compte-ci).
  allow_create_organization = false
  allow_git_hook            = false
  allow_import_local        = false
}
