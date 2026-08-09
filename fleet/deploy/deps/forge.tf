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

locals {
  # scoper (2026-07-31) : RENOMMAGE complet de consultant — l'inspection des SP a montré que
  # consultant était le juge de brief EN ENTIER (la « dualité » était une seconde carte pointant
  # sur lui, BL-6-11 fermé). scoper = juge natif (team judges) ; le nom consultant est LIBRE,
  # le runtime l'a retiré ({:error, :not_found}) AVANT cette dépose — un compte sans cap-profile
  # est inerte, l'ordre inverse ne l'est pas.
  # scribe (2026-08-02, chantier face-projet) : le producteur DOCUMENTAIRE — meme mecanique de
  # livraison que l'engineer (git-native, forge-blind), sur la face ops. Team writers, comme
  # tout producteur. Lecon scoper (BL du 2026-08-02) : un role ajoute au catalogue SANS son compte
  # forge boucle en role_token_unavailable — le compte nait ICI, avec le role.
  roles = ["architect", "engineer", "scribe", "chief", "gatekeeper", "qualifier", "reviewer", "scoper", "vulcan"]
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
  for_each             = toset(local.roles)
  username             = each.key
  login_name           = each.key
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
locals {
  writers   = ["architect", "engineer", "scribe", "gatekeeper"]
  judges    = ["qualifier", "reviewer", "scoper"]
  externals = ["vulcan"]
}

resource "gitea_team_membership" "system" {
  team_id  = gitea_team.system.id
  username = gitea_user.system.username
}

resource "gitea_team_membership" "writers" {
  for_each = toset(local.writers)
  team_id  = gitea_team.writers.id
  username = gitea_user.role[each.key].username
}

resource "gitea_team_membership" "judges" {
  for_each = toset(local.judges)
  team_id  = gitea_team.judges.id
  username = gitea_user.role[each.key].username
}

resource "gitea_team_membership" "externals" {
  for_each = toset(local.externals)
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
