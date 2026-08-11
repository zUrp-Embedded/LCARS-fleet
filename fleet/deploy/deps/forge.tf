# ═══════════════════════════════════════════════════════════════════════════
# LCARS Fleet — empreinte forge (structure déclarative)
#
# Provisionne la STRUCTURE d'une forge Gitea vierge pour accueillir une fleet :
# comptes (système + rôles + humain + starfleet), org `fleet`, teams + memberships.
#
# HORS de ce fichier, par choix :
#   · les tokens runtime      → bin/provision-role-tokens.sh (le provider ne minte
#     pas proprement un secret par-rôle → seam bash assumé, comme partout ailleurs).
#   · les repos projet        → créés au RUNTIME par lcars-system (project_onboard).
#     C'est de la DONNÉE MÉTIER, pas de la structure : ça ne vit pas dans le socle.
#
# MODÈLE D'ACCÈS — la clé de voûte : les PODS sont FORGE-AVEUGLES (zéro token, zéro
# remote crédité, cf. forge_auth.ex « le pod hérite d'un remote SANS credential »).
# SEUL le système tape sur la forge, portant TOUS les tokens (système + rôles) ;
# `as_role` (système-side, forge_client.ex) ne sert QU'À l'authorship (la PR affiche
# « engineer »). Les comptes de rôle ne sont donc pas des acteurs indépendants → leur
# niveau exact (read/write) n'est PAS sécurité-critique : détourner un token de rôle
# suppose l'accès à /home/private, qui porte AUSSI le token système (org-power).
#
# Le SEUL acteur indépendant à verrouiller, c'est l'HUMAIN (gestes UI manuels) → team
# `humans` en READ : il voit et commente, il ne relabellise (issues:write requis) ni
# ne crée. C'est CE lock — et non un units_map par-rôle — qui rend les labels
# `stage/*` infalsifiables. Et il s'exprime en permission UNIFORME, donc nativement
# en TF (le provider v0.7 ne fait que de l'uniforme par team ; sans importance ici,
# justement parce que le per-rôle n'a pas besoin d'être fin).
# ═══════════════════════════════════════════════════════════════════════════

provider "gitea" {
  base_url = var.gitea_url
  token    = var.gitea_token
}

# ── Comptes ────────────────────────────────────────────────────────────────
# Bots : ils s'authentifient par TOKEN (posé hors-TF) ; le password n'est qu'une
# formalité exigée par l'API de création.

# Le ROSTER — la liste des comptes de rôle à créer.
#
# ⚠ L'ORDRE COMPTE : un compte sans cap-profile est inerte, l'inverse ne l'est pas. Un rôle ajouté
# au catalogue SANS son compte boucle en `role_token_unavailable` — le compte naît ICI, avec le
# rôle. C'est la cause racine de BL-6-34, payée deux fois.
#
# VARIABLE et non plus `local` : le roster appartient au CATALOGUE en service, pas à cette recette.
# Le défaut ci-dessous est celui du catalogue de référence, et il reste la valeur sans laquelle rien
# ne change pour un déploiement qui n'apporte pas le sien.
#
# Un déploiement qui apporte un autre catalogue pose un `roles.auto.tfvars.json` DÉRIVÉ de ce
# catalogue (`etc/enroll-catalogue.sh`) — tofu le lit nativement. Le roster cesse alors d'être tenu
# à la main, ce qui est la cause racine connue de BL-6-34 : un rôle ajouté au catalogue sans son
# compte boucle en `role_token_unavailable`, vécu deux fois (eng_doc, puis son rename scribe).
#
# Ce que la dérivation N'apporte PAS : les règles ci-dessous (pas de création d'org, pas de git-hook
# serveur, pas d'import local, l'org et les teams). Un catalogue dit QUI existe ; cette recette dit
# ce qu'exister permet. Une recette générée depuis un catalogue donnerait à un fichier remplaçable
# l'autorité d'élargir ses propres droits.
variable "roles" {
  type        = list(string)
  description = "Comptes de role a creer, en LOGINS <catalogue>_<role> — derive du catalogue en service, defaut = catalogue de reference"
  default = [
    "system_architect", "system_chief", "system_gatekeeper",
    "fleet_engineer", "fleet_scribe", "fleet_qualifier", "fleet_reviewer", "fleet_scoper", "fleet_vulcan",
  ]
}

variable "role_names" {
  type        = map(string)
  description = "login -> nom du role, pose en full_name (l'UI l'affiche a la place du login)"
  default = {
    system_architect  = "architect"
    system_chief      = "chief"
    system_gatekeeper = "gatekeeper"
    fleet_engineer    = "engineer"
    fleet_scribe      = "scribe"
    fleet_qualifier   = "qualifier"
    fleet_reviewer    = "reviewer"
    fleet_scoper      = "scoper"
    fleet_vulcan      = "vulcan"
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
resource "gitea_user" "role" {
  for_each             = toset(var.roles)
  username             = each.key
  login_name           = each.key
  # Le LOGIN porte le catalogue (`<catalogue>_<role>`), parce qu'un username Gitea est unique a
  # l'INSTANCE : sans prefixe, deux catalogues nommant chacun un `dev` se partagent un compte et un
  # jeton, avec ecriture sur les deux orgs. Le `full_name` porte le nom du role, et l'UI l'affiche a
  # la place du login quand `[ui] DEFAULT_SHOW_FULL_NAME` est pose — le prefixe ne subsiste alors que
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

# PAS de compte admin dans la recette — le premier admin est un PRÉREQUIS D'ENTRÉE, pas un
# produit : une forge fonctionnelle a déjà son master-admin (le wizard d'install gitea le crée
# chez l'opérateur ; une forge jetable headless le reçoit d'un `gitea admin user create`, compte
# `bootstrap` au nom explicite). La recette reproduit la STRUCTURE ; l'identité admin appartient
# au pet et à son opérateur, comme l'URL et le master token.
#
# La garde qui reste vraie quoi qu'il arrive : le daily ci-dessous n'est JAMAIS site-admin — un
# site-admin Gitea passe outre toutes les permissions de team, donc un daily-admin rendrait
# `humans` décoratif : il pourrait relabelliser `stage/*` et déclarer terminé un travail qui ne
# l'est pas.
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

# ── Org + teams ────────────────────────────────────────────────────────────
resource "gitea_org" "fleet" {
  name       = "fleet"
  visibility = "private"
}

# system : SEUL à créer des repos d'org (création réservée au système) + write dessus
# (push, topics de découverte, labels via le token système). PAS admin/owner : le moindre
# privilège suffit à ce que cette recette doit faire. La branch-protection n'est PAS de son
# ressort — elle se pose PAR DÉPÔT, au moment où le dépôt existe, donc hors provisioning.
resource "gitea_team" "system" {
  name                     = "system"
  organisation             = gitea_org.fleet.name
  permission               = "write"
  can_create_repos         = true
  include_all_repositories = true
  # Gitea 1.26 stocke l'accès en units_map ; le champ `permission` top-level se relit « none »
  # (déprécié) → sans ça le provider verrait un drift perpétuel write→none. L'accès réel
  # (units_map) est posé au CREATE depuis `permission` et stable → on ignore la relecture cosmétique.
  # (Coût assumé : changer le niveau d'une team plus tard = taint/recreate, pas un simple edit.)
  lifecycle {
    ignore_changes = [permission]
  }
}

# writers : rôles qui PRODUISENT (push code, ouvrent/mergent des PR). Le système agit
# `as_role` pour l'authorship. Write uniforme (issues:write inclus = bénin : pods aveugles).
resource "gitea_team" "writers" {
  name                     = "writers"
  organisation             = gitea_org.fleet.name
  permission               = "write"
  can_create_repos         = false # EXPLICITE : le provider défaute à true → seul `system` crée des repos.
  include_all_repositories = true
  lifecycle {
    ignore_changes = [permission] # cf. team `system` : relecture `permission=none` dépréciée.
  }
}

# judges : qualifier/reviewer — WRITE. Ils postent des RAPPORTS D'AUDIT lourds committés dans ops
# (via le système `as_role`, jamais le pod forge-aveugle) → ils ont besoin de write, pas juste de la
# review en read. Corollaire : le grant per-repo `add_collaborator` du runtime (engineer/qualifier/
# reviewer/gatekeeper) devient REDONDANT avec les teams writers+judges → à retirer côté runtime.
resource "gitea_team" "judges" {
  name                     = "judges"
  organisation             = gitea_org.fleet.name
  permission               = "write"
  can_create_repos         = false # EXPLICITE : le provider défaute à true.
  include_all_repositories = true
  lifecycle {
    ignore_changes = [permission] # cf. team `system` : relecture `permission=none` dépréciée.
  }
}

# externals : rôle EXTERNE (vulcan) — READ strict. Séparé des judges JUSTEMENT pour que leur write ne
# fuite pas à l'externe : un externe ne pousse RIEN (ni code, ni audit), il commente/review en read.
resource "gitea_team" "externals" {
  name                     = "externals"
  organisation             = gitea_org.fleet.name
  permission               = "read"
  can_create_repos         = false
  include_all_repositories = true
  lifecycle {
    ignore_changes = [permission]
  }
}

# humans : l'humain daily — READ. LE lock qui compte : voit + commente, ne relabellise
# ni ne crée. Rend `stage/*` infalsifiable côté acteur indépendant.
resource "gitea_team" "humans" {
  name                     = "humans"
  organisation             = gitea_org.fleet.name
  permission               = "read"
  can_create_repos         = false # EXPLICITE (le lock) : l'humain ne crée AUCUN repo.
  include_all_repositories = true
  lifecycle {
    ignore_changes = [permission] # cf. team `system` : relecture `permission=none` dépréciée.
  }
}

# ── Memberships ────────────────────────────────────────────────────────────
# Les trois placements, VARIABLES pour la meme raison que `roles` : qui est producteur et qui est
# juge est une propriete du catalogue, pas de cette recette. Les defauts sont ceux du catalogue de
# reference — un deploiement qui n'apporte rien ne change pas d'un pouce.
#
# La REGLE de placement, elle, reste ici et se derive (`Fleet.Application.CatalogueRoles.tfvars/1`) :
# un siege reserve va en `externals`, un role qui ne fait que juger (`brief_kind: judge` sans
# capacite) en `judges`, tout le reste en `writers`. Un role peut n'etre dans AUCUNE des trois et
# garder son compte : `roles` est le roster des comptes, ces trois-ci sont des placements.
variable "writers" {
  type        = list(string)
  description = "Roles qui ecrivent dans les depots — defaut = catalogue de reference"
  # `chief` manquait ici alors qu'il est dans `roles` : il obtenait un compte et un role-token, et
  # aucun droit d'ecriture sur l'org. C'est le conflict_resolver — il n'agit que sur un conflit que
  # le producteur n'a pas su fermer, donc le defaut attendait le pire moment pour se manifester, et
  # le doctor ne le voyait pas (il verifie les tokens, pas les appartenances). Ce defaut est la
  # SECONDE ecriture d'un fait que la derivation produit deja (`mix lcars.catalogue.roles --tfvars`
  # rend `writers: architect chief engineer gatekeeper scribe`) : deux listes pour un fait derivent,
  # et c'est celle en dur qui servait.
  default     = ["system_architect", "system_chief", "system_gatekeeper", "fleet_engineer", "fleet_scribe"]
}

variable "judges" {
  type        = list(string)
  description = "Roles qui ne rendent que des verdicts — defaut = catalogue de reference"
  default     = ["fleet_qualifier", "fleet_reviewer", "fleet_scoper"]
}

variable "externals" {
  type        = list(string)
  description = "Sieges reserves — defaut = catalogue de reference"
  default     = ["fleet_vulcan"]
}

resource "gitea_team_membership" "system" {
  team_id  = gitea_team.system.id
  username = gitea_user.system.username
}

resource "gitea_team_membership" "writers" {
  for_each = toset(var.writers)
  team_id  = gitea_team.writers.id
  username = gitea_user.role[each.key].username
}

resource "gitea_team_membership" "judges" {
  for_each = toset(var.judges)
  team_id  = gitea_team.judges.id
  username = gitea_user.role[each.key].username
}

resource "gitea_team_membership" "externals" {
  for_each = toset(var.externals)
  team_id  = gitea_team.externals.id
  username = gitea_user.role[each.key].username
}

resource "gitea_team_membership" "human" {
  team_id  = gitea_team.humans.id
  username = gitea_user.human.username
}

# lcars-system ∈ humans : le token système doit LIRE les membres de `humans` — c'est la
# vérification d'admission de l'onboard (`{:human_team_unverifiable, …}` refuse l'onboard quand
# cette lecture échoue). BL-6-27 : deux agents ont posé ce membership à la main, séparément, sur
# deux bancs — un contournement réinventé deux fois est un trou de recette. Aucun privilège
# nouveau : la team est `read` et `system` (write, can_create_repos) la domine déjà — seule la
# visibilité de la liste des membres est acquise. Le volet delete_project (repo-admin exigé par
# Gitea) reste OUVERT dans BL-6-27 : il se règle par une identité, pas en élargissant `system`.
resource "gitea_team_membership" "system_reads_humans" {
  team_id  = gitea_team.humans.id
  username = gitea_user.system.username
}
