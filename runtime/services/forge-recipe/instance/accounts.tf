# ═══════════════════════════════════════════════════════════════════════════
# LCARS Fleet — empreinte forge, module INSTANCE
#
# Ce que ce module possede : les comptes qui ne dependent d'AUCUN catalogue et
# vivent une fois par forge — le systeme, l'humain, et les roles de MECANIQUE
# (`system_*`), la meme autorite dans toutes les orgs.
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

# VARIABLE, pas litteral : le module catalogue NOMME le meme login (`var.system_account`, pour ses
# adhesions), et deux ecritures d'un meme fait derivent. La sonde d'existence a besoin de celui-ci —
# un nom faux ne rend pas d'erreur, il rend « absent », et tofu retente alors une creation qui
# echoue en 409.
variable "system_account" {
  type        = string
  default     = "system_starfleet"
  description = "Compte SYSTEME de l'instance — meme valeur que `var.system_account` du module catalogue"
}

resource "gitea_user" "system" {
  username             = var.system_account
  login_name           = var.system_account
  email                = "${var.system_account}@lcars.local"
  password             = var.seed_password
  must_change_password = false
  admin                = false # PAS site-admin : org-power via la team `system`, blast-radius borné à l'org
  # Hardening : system_starfleet crée des repos DANS l'org (team can_create_repos), jamais de
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

# ⚠ AUCUN COMPTE `starfleet` SUR LA FORGE, et son absence est une DECISION (2026-08-15).
#
# starfleet est chef de PORTEFEUILLE : il ne met jamais la main dans un projet, et surtout pas en
# ecriture. Le canon le declare — `cap-profiles/starfleet.yaml` : « NO forge identity : starfleet
# holds no forge account and no role token — every forge write it causes goes through the SYSTEM ».
# Une ressource `gitea_user` pour lui creerait, en SITE-ADMIN, le compte que la donnee dit ne pas
# exister — et aucun gate ne l'attraperait : le verrou a quatre listes (`roles.provisioning_locked`)
# impose canon == forge.tf == ROLES == PROV_ROLES mais EXCLUT starfleet sur `forge_identity`
# (l'asymetrie vit dans la donnee, volontairement), et les ressources AUTONOMES de ce fichier
# (`system`, `human`) sont hors de la boucle des roles.
#
# MESURE DU 2026-08-15 (banc) : zero site `as_role("starfleet")` dans tout `runtime/` (marcheur
# independant, pas un grep) · aucun `starfleet.gitea_token` dans `/opt/lcars/var/tokens` · absent du
# `forge-role-passwords.json` et de la liste `ROLES` de `provision-role-tokens.sh` · aucune org,
# aucun depot. Rien ne peut s'authentifier sous lui.
#
# L'ONBOARDING (creer des users = op site-admin) appartient au MASTER (l'installeur, materialise en
# `admiral` au banc), qui porte le compte admin de la forge et le master-token que tofu consomme. Le
# break-glass est le compte de l'installeur — `gitea_user "human"` ci-dessous le dit dans son propre
# commentaire. Le BADGE de starfleet, lui, est pose par `provision-forge-charte.sh` sur le master
# (option `--admiral`) : le nom n'est pas sur la forge, la charte y est.

# ⚠ `count`, ET C'EST LA CONSEQUENCE DU COMMENTAIRE CI-DESSOUS (⚖ user 2026-08-30) : CE COMPTE
# N'EST PAS UNE PERSONNE — c'est l'humain de demonstration d'un banc, et les vraies personnes ont des
# comptes a leur nom. Une ressource inconditionnelle semerait ce compte sur TOUT deploiement. `builtin_human` vide (le defaut) = aucun compte : un
# deploiement de travail pose les autorites, pas les humains.
resource "gitea_user" "human" {
  count                = var.builtin_human == "" ? 0 : 1
  username             = var.builtin_human
  login_name           = var.builtin_human
  email                = var.builtin_email
  password             = var.seed_password

  # `false`, et c'est un CORRECTIF (⚖ arbitrage user 2026-08-11) : pas de `must_change_password =
  # true` au motif que « l'humain pose son propre secret au 1er login ».
  #
  # CE COMPTE N'EST PAS UNE PERSONNE. Sur un banc, c'est l'humain de démonstration, un admin de
  # LCARS que cette recette pose pour essayer LCARS sans enrôler personne. Les vraies personnes ont
  # des comptes à leur nom, et elles n'existent pas encore (enrollment). Le réglage attendrait donc un premier login que personne ne fait, et il
  # n'est pas inerte : il ferme le compte en attendant — le banc devrait le lever à chaque nuke, une
  # installation réelle l'oublierait simplement.
  must_change_password = false

  # `true` (T2). Deux adminités existent, et elles ne se confondent pas :
  #
  #   · L'ADMIN DE LCARS — les droits d'administration que la fleet voit. Il est porté par un compte
  #     SITE-ADMIN de la forge, et c'est `is_admin` que lit la porte de `lcars catalogue install`
  #     (`catalogue-executor.py`, `forge_is_admin`). L'humain de démonstration est un admin de LCARS,
  #     et cette recette le pose.
  #   · L'ADMIN DU SYSTÈME — le siège (`/etc/lcars/seat.uid`) : sur un poste, le compte qui installe
  #     (celui qui lance sudo) ; dans un conteneur, le compte n°1 de la forge (`admiral` au banc).
  #     Il administre la machine ; sur la forge, il porte le compte d'administration, posé HORS de
  #     cette recette (par l'installeur sur un poste dont la forge est montée, par l'opérateur de la
  #     forge sinon), avec le jeton master et le break-glass. La garde du siège lui refuse la fleet :
  #     son adminité ne passe jamais par elle.
  #
  # CETTE LIGNE EST LA SEULE MAIN QUI POSE L'ADMINITÉ DE CE COMPTE. Tofu la réapplique à chaque
  # passe de 61-forge-structure : une autre main (le banc) qui la poserait aussi serait défaite ici
  # dès que les deux divergent. Le banc (`bench_human_seed`) la vérifie, il ne la pose pas.
  admin                = true
  # Réglages durcis, gardés pour le jour où l'adminité serait retirée : un site-admin Gitea passe
  # outre `allow_create_organization` (POST /orgs rend 201 sous ce compte).
  allow_create_organization = false
  allow_git_hook            = false
  allow_import_local        = false
}
