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

# ⚠ LE COMPTE `starfleet` A ETE RETIRE (2026-08-15), et son absence est une DECISION.
#
# Il datait de l'epoque ou starfleet etait le role sysadmin et recevait les tickets systeme. Depuis
# le reorg du 2026-07-19 il est chef de PORTEFEUILLE : il ne met jamais la main dans un projet, et
# surtout pas en ecriture. Le canon le declarait deja — `cap-profiles/starfleet.yaml` :
# « NO forge identity : starfleet holds no forge account and no role token — every forge write it
# causes goes through the SYSTEM ». Cette ressource creait donc, en SITE-ADMIN, le compte que la
# donnee disait ne pas exister.
#
# MESURE DU 2026-08-15 (banc), avant retrait : zero site `as_role("starfleet")` dans tout `fleet/`
# (marcheur independant, pas un grep) · aucun `starfleet.gitea_token` dans `/home/private` (dix
# tokens, aucun pour lui) · absent du `forge-role-passwords.json` · absent de la liste `ROLES` de
# `provision-role-tokens.sh` · aucune org, aucun depot. Aucun secret ne vivait nulle part pour ce
# compte : rien ne pouvait s'authentifier sous lui, et il etait site-admin.
#
# POURQUOI IL A SURVECU SI LONGTEMPS. Le verrou a quatre listes (`roles.provisioning_locked`) impose
# l'egalite canon == forge.tf == ROLES == PROV_ROLES, et il EXCLUT starfleet sur `forge_identity`
# — l'asymetrie vit dans la donnee, volontairement. Mais cette ressource-ci etait AUTONOME, hors de
# la boucle des roles, comme `system` et `human` : elle echappait donc au verrou. Le canon pouvait
# dire « pas de compte forge » pendant que le provisionnement en creait un, indefiniment, sans
# qu'aucun gate ne les confronte.
#
# Son motif ecrit etait « site-admin : l'identite d'ONBOARDING (creer des users = op site-admin) ».
# Ce role appartient desormais au MASTER (l'installeur, materialise en `admiral` au banc), qui porte
# le compte admin de la forge et le master-token que tofu consomme. Le break-glass est le compte de
# l'installeur — `gitea_user "human"` ci-dessous le dit deja dans son propre commentaire.
#
# Son BADGE, lui, ne disparait pas : `provision-forge-charte.sh` le pose sur le master (option
# `--admiral`). Le nom quitte la forge, la charte reste.

resource "gitea_user" "human" {
  username             = var.human_username
  login_name           = var.human_username
  email                = var.human_email
  password             = var.seed_password

  # `false`, et c'est un CORRECTIF (⚖ arbitrage user 2026-08-11). Ce compte portait
  # `must_change_password = true` au motif que « l'humain pose son propre secret au 1er login ».
  #
  # CE COMPTE N'EST PAS UNE PERSONNE. Sur un banc, il tient la place du compte admin que Gitea fait
  # créer À SON INSTALLATION — celui que l'opérateur pose quand il prépare la forge qu'on lui
  # demande. Les vraies personnes ont des comptes à leur nom, et elles n'existent pas encore
  # (chantier enrollment). Le réglage attendait donc un premier login que personne ne fait, et il
  # n'est pas inerte : il ferme le compte en attendant. Les DEUX chemins le contredisaient — le banc
  # le levait à chaque nuke, une installation réelle l'aurait simplement oublié.
  must_change_password = false

  admin                = false # NON site-admin : ce compte opère VIA la fleet, pas par gestes forge manuels
  # Hardening : il ne crée ni org, ni git-hook serveur, ni import local
  # (le break-glass, c'est le compte admin de l'installeur, pas ce compte-ci).
  allow_create_organization = false
  allow_git_hook            = false
  allow_import_local        = false
}
