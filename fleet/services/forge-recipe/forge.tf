# ═══════════════════════════════════════════════════════════════════════════
# LCARS Fleet — empreinte forge (structure déclarative)
#
# Provisionne la STRUCTURE d'une forge Gitea vierge pour accueillir une fleet :
# comptes (système + rôles + humain), org `fleet`, teams + memberships.
#
# HORS de ce fichier, par choix :
#   · les tokens runtime      → bin/provision-role-tokens.sh (le provider ne minte
#     pas proprement un secret par-rôle → seam bash assumé, comme partout ailleurs).
#   · les repos projet        → créés au RUNTIME par system_starfleet (project_onboard).
#     C'est de la DONNÉE MÉTIER, pas de la structure : ça ne vit pas dans le socle.
#
# MODÈLE D'ACCÈS — la clé de voûte : les PODS sont FORGE-AVEUGLES (zéro token, zéro
# remote crédité, cf. forge_auth.ex « le pod hérite d'un remote SANS credential »).
# SEUL le système tape sur la forge, portant TOUS les tokens (système + rôles) ;
# `as_role` (système-side, forge_client.ex) ne sert QU'À l'authorship (la PR affiche
# « engineer »). Les comptes de rôle ne sont donc pas des acteurs indépendants → leur
# niveau exact (read/write) n'est PAS sécurité-critique : détourner un token de rôle
# suppose l'accès à /opt/lcars/var/tokens, qui porte AUSSI le token système (org-power).
#
# Le SEUL acteur indépendant à verrouiller, c'est l'HUMAIN (gestes UI manuels) → team
# `humans` en READ : il voit et commente, il ne relabellise (issues:write requis) ni
# ne crée. C'est CE lock — et non un units_map par-rôle — qui rend les labels
# `stage/*` infalsifiables. Et il s'exprime en permission UNIFORME, donc nativement
# en TF (le provider ne fait que de l'uniforme par team ; sans importance ici,
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
# DEUX listes, parce que les comptes n'ont pas la meme DUREE DE VIE. Les `system_*` sont une autorite
# d'INSTANCE — la meme dans toutes les orgs, membre de chacune, creee une fois. Les metier
# appartiennent au catalogue qui les declare. Les fondre ferait tenter la creation des comptes
# systeme a chaque enrolement d'un catalogue, et Gitea rend « user already exists » (mesure).
variable "roles" {
  type        = list(string)
  description = "Comptes de role METIER de ce catalogue, en LOGINS <catalogue>_<role> — derive"
  default     = ["fleet_engineer", "fleet_scribe", "fleet_qualifier", "fleet_reviewer", "fleet_scoper", "fleet_vulcan"]
}

# NON CREES ICI — le module `instance/` les possede. Ce module les NOMME, pour les placer dans ses
# teams : une adhesion prend un login, pas une ressource. C'est la coupure qui permet a un second
# catalogue de s'enroler sans retenter la creation des comptes partages (Gitea : « user already
# exists », mesure).
variable "system_roles" {
  type        = list(string)
  description = "Comptes de role SYSTEME, crees par le module instance/ — nommes ici pour les adhesions"
  default     = ["system_architect", "system_chief", "system_gatekeeper"]
}

# ⚠ AUCUN DEFAUT, ET C'EST LE POINT. Cette variable portait `default = "system_starfleet"` — un
# litteral qu'aucun `.tfvars` n'alimentait et qu'aucun verrou ne comparait, alors que ce compte est
# dans la team `Owners` de l'org (il possede tous les depots projet), que son email passe le gate
# d'identite de commit, et qu'il est le `forge_push_account` par defaut. Le compte qui POSSEDE l'org
# naissait d'un nom que personne ne tenait.
#
# Il arrive desormais par `roles.auto.tfvars.json`, comme l'org et les quatre listes, projete depuis
# `Fleet.Credentials.ForgeIdentity` — l'autorite designee (arbitrage user, 2026-08-27), parce que
# l'identite du compte (email, signature, `allowed_emails/2`) en derive et ne peut pas s'en detacher.
#
# SANS DEFAUT, tofu REFUSE de planifier si le JSON manque, au lieu de creer un compte sous un nom
# que personne n'a choisi. Le verrou `forge.system_account_single_source` garde l'absence de defaut :
# le reintroduire ferait rougir le gate.
variable "system_account" {
  type        = string
  description = "Compte systeme, cree par le module instance/ — recu de roles.auto.tfvars.json (autorite : Fleet.Credentials.ForgeIdentity)"
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
# ── Org + teams ────────────────────────────────────────────────────────────
# L'ORG PORTE LE NOM DU CATALOGUE — c'est la reponse a « quel metier traite ce projet », gravee la
# ou la verite vit deja. Elle etait le litteral `fleet` ; elle est desormais derivee, et le defaut
# vaut le nom du catalogue de reference, donc rien ne bouge pour un deploiement qui n'apporte rien.
#
# `public` et non `private` (arbitrage user 2026-08-10) : la forge est INTERNE et locale, elle n'est
# pas vouee a partir sur GitHub — c'est aussi pourquoi les deux sont separees. Mesure : en `private`,
# un humain non-membre voit ZERO, meme un depot public (404 sur l'org, sur le depot, sur la creation
# d'issue) ; en `public`, il voit et peut ouvrir une issue sans adherer a quoi que ce soit. C'est ce
# qui permet a un collegue de travailler sur le projet d'un autre sans etre membre de son org.
# L'ecriture n'est pas ouverte pour autant : un anonyme ne peut pas ouvrir d'issue, Gitea exige
# l'auth en ecriture.
variable "org" {
  type        = string
  description = "Org forge portant les projets de ce catalogue — c'est le nom du catalogue"
  default     = "fleet"
}

resource "gitea_org" "fleet" {
  name       = var.org
  visibility = "public"

  # ⚖ REGLE DU RE-ROLL (user, 2026-08-17) : un re-roll repose le SQUELETTE sans lequel la fleet ne
  # produit rien, et rien d'autre. L'EXISTENCE de cette org est du squelette ; sa visibilite est un
  # reglage, et un admin qui la passe en `limited` a pris une decision qu'on ne lui reprend pas.
  #
  # MESURE DU 2026-08-17 SUR BANC, parce que ce n'est pas une precaution theorique : org passee en
  # `limited` par l'API, puis `tofu plan` -> `~ visibility = "limited" -> "public"`. Sans ce bloc, le
  # prochain apply annule le geste, en silence, au milieu de cinq autres lignes de plan.
  #
  # ⚠ POURQUOI `ignore_changes` ET PAS « ne pas declarer l'attribut » : mesure du schema du provider
  # (`tofu providers schema -json`), `visibility` est `optional=true, computed=FALSE`. Sans
  # `computed`, un attribut omis ne veut pas dire « non gere » — il vaut sa valeur ZERO, et tofu
  # planifie un diff vers `""` a chaque apply. C'est `Optional + Computed:true` qui signifie « si tu
  # ne le declares pas, je n'y touche pas », et ce n'est pas le cas ici.
  #
  # ⚠ ET LE PIEGE DE `ignore_changes` DE CE FICHIER NE MORD PAS ICI, verifie plutot que suppose. Il
  # a ete retire des teams (cf. la cicatrice sur `gitea_team`) parce que Gitea relit `permission` en
  # `none` — une valeur INVALIDE en ecriture, que l'update renvoyait et que Gitea refusait. La
  # visibilite, elle, se relit `public`/`limited` : des valeurs valides. Plan apres ce bloc :
  # `gitea_org.fleet` disparait du plan, l'org reste `limited`.
  lifecycle {
    ignore_changes = [visibility, repo_admin_change_team_access]
  }
}

# system : SEUL à créer des repos d'org (création réservée au système) + write dessus
# (push, topics de découverte, labels via le token système). PAS admin/owner : le moindre
# privilège suffit à ce que cette recette doit faire. La branch-protection n'est PAS de son
# ressort — elle se pose PAR DÉPÔT, au moment où le dépôt existe, donc hors provisioning.
#
# ⚠ CE CHOIX A UNE CONSÉQUENCE QU'IL N'AVAIT PAS QUAND IL A ÉTÉ ÉCRIT, et elle est mesurée
# (2026-08-11) : `lcars project migrate` transfère un dépôt d'une org à l'autre, et Gitea exige pour
# ça le PROPRIÉTAIRE de l'org SOURCE — pas l'admin, pas le write.
#
#   token système (membre, write)                    -> 403 "user should be the owner of the repo"
#   même token, ajouté aux Owners de l'org SOURCE    -> 202
#   Owners de la CIBLE seulement                     -> 403   (seule la source compte)
#
# Le moindre privilège ne suffit donc plus à ce que la fleet doit faire, et la recette ne peut pas
# le corriger elle-même : `50-forge` n'écrit qu'avec le jeton système ou en basic-auth machine, et
# le jeton système ne peut gérer une team qu'une fois DÉJÀ propriétaire. La seule identité de classe
# propriétaire est celle qui lance cet apply. Le provider n'a pas de champ propriétaire sur
# `gitea_org` — le créateur d'une org en est le propriétaire, un point c'est tout.
#
# ⚖ TRANCHÉ (user, 2026-08-11) : c'est `system_starfleet` qui possède les orgs — c'est déjà le seul
# compte qui y crée des dépôts. L'adhésion se pose dans la FENÊTRE DU MASTER TOKEN, celle qui lance
# cet apply. Elle EST posée par cette recette depuis le 2026-08-16 (`gitea_team_membership.owner`,
# plus bas) : elle vivait à l'étape 4-bis du banc, et n'existait donc PAS en production.
#
# La team `system` ci-dessous reste donc au moindre privilège pour ce qu'elle sert (créer et pousser)
# ; la propriété de l'org est un fait SÉPARÉ, posé ailleurs, et écrit ici pour qu'on ne relise pas
# « PAS admin/owner » comme « ce compte n'a aucun pouvoir d'org ». Il en a un, et il est nommé.

# LES CINQ TEAMS SONT UNE SEULE RESSOURCE INDEXÉE, et la table ci-dessous est la SEULE liste de
# leurs noms. Elles étaient cinq ressources nommées ; le bloc `import` qui les fait rejoindre l'état
# sur une forge existante a besoin de cette liste, et l'écrire une seconde fois dans `existing.tf`
# aurait produit exactement la classe de dérive qui a déjà mordu ici (`chief` dans `roles` et pas
# dans `writers` : un compte, un token, aucun droit — trouvé en lisant une org, par aucun check).
locals {
  base_teams = {
    # SEULE à créer des repos d'org (création réservée au système) + write dessus (push, topics de
    # découverte, labels via le token système). PAS admin/owner : cf. la cicatrice de propriété
    # ci-dessus — elle se pose hors de cette recette, dans la fenêtre du master token.
    system = { permission = "write", can_create_repos = true }

    # rôles qui PRODUISENT (push code, ouvrent/mergent des PR). Le système agit `as_role` pour
    # l'authorship. Write uniforme (issues:write inclus = bénin : pods aveugles).
    # `can_create_repos = false` est EXPLICITE : le provider défaute à true → seul `system` crée.
    writers = { permission = "write", can_create_repos = false }

    # qualifier/reviewer — WRITE. Ils postent des RAPPORTS D'AUDIT lourds committés dans ops (via le
    # système `as_role`, jamais le pod forge-aveugle) → write, pas juste la review en read.
    # Corollaire : le grant per-repo `add_collaborator` du runtime (engineer/qualifier/reviewer/
    # gatekeeper) devient REDONDANT avec writers+judges → à retirer côté runtime.
    judges = { permission = "write", can_create_repos = false }

    # rôle EXTERNE (vulcan) — READ strict. Séparé des judges JUSTEMENT pour que leur write ne fuite
    # pas à l'externe : un externe ne pousse RIEN (ni code, ni audit), il commente/review en read.
    externals = { permission = "read", can_create_repos = false }
  }

  # ⚠ `humans` N'EXISTE QUE DANS L'ORG SYSTÈME, et cette recette est jouée UNE FOIS PAR ORG — pour
  # `fleet` par `cmd_apply`, puis pour chaque catalogue par `cmd_install`, qui la recopie dans le
  # dossier du catalogue avec `var.org` = son nom.
  #
  # POURQUOI ELLE N'A RIEN À FAIRE DANS UNE ORG DE CATALOGUE. Elle répondait à UNE question : le
  # préflight d'onboarding vérifiait l'adhésion de l'humain à `<catalogue>:humans` avant de créer un
  # projet. Ce préflight exigeait un `read` que l'humain a déjà (l'org est publique, les dépôts
  # aussi) pour des écritures qu'il ne fait pas — c'est le jeton système qui écrit. Il part avec ce
  # lot, et la team n'a plus de lecteur : mesuré, `web-demo/humans` ne contenait que le compte
  # built-in et `system_starfleet`, jamais un humain réel.
  #
  # ⚠ ET CE RETRAIT DÉPEND D'UN AUTRE : tant que la forge naissait avec
  # `DEFAULT_USER_IS_RESTRICTED=true`, l'adhésion à `<catalogue>:humans` était la SEULE chose qui
  # rendait un catalogue visible à un humain — un compte restreint ne voit que ce qui lui est
  # explicitement accordé, et mesuré le 2026-08-17 il recevait 404 sur l'org d'un catalogue en étant
  # connecté, 200 en anonyme. Le drapeau est parti d'abord (`dev/forge-compose.yml`) ; retirer la
  # team avant lui aurait aveuglé tous les humains sur tous les catalogues.
  #
  # LA FORME EST UN CONDITIONNEL ET PAS UN MODULE SÉPARÉ, mesuré : un module neuf n'hérite pas de la
  # couche sonde+`import` d'`existing.tf`, donc son premier apply meurt en 409 sur toute forge déjà
  # provisionnée. Ici la sonde suit d'elle-même — elle interroge `keys(local.teams)`, donc elle ne
  # demande `humans` que là où la table la porte.
  teams = var.org == var.system_org ? merge(local.base_teams, {
    # l'humain daily — READ. LE lock qui compte : voit + commente, ne relabellise ni ne crée. Rend
    # `stage/*` infalsifiable côté acteur indépendant, et `can_create_repos = false` EST ce lock.
    humans = { permission = "read", can_create_repos = false }
  }) : local.base_teams
}

# L'ORG SYSTÈME EST NOMMÉE, PAS DEVINÉE. Elle porte l'identité (`humans`, lue par le convergeur et
# par le deck) ; les orgs de catalogue portent du travail. Une recette qui sert les deux a besoin de
# savoir laquelle elle sert, et une variable le dit mieux qu'une convention de nommage.
variable "system_org" {
  type        = string
  description = "Org qui porte l'identité de la fleet — la seule à recevoir la team `humans`"
  default     = "fleet"
}

# ⚠ IL N'Y A PLUS DE `ignore_changes = [permission]` ICI, ET SON RETRAIT EST UN CORRECTIF.
# Il portait ceci, qui reste vrai : Gitea 1.26 stocke l'accès en units_map et relit le champ
# `permission` top-level en « none » (déprécié), donc le provider voit un drift perpétuel
# write→none. Mais sur une team IMPORTÉE, la valeur planifiée d'un attribut ignoré est celle de
# l'ÉTAT, soit « none » — et l'update part avec, ce que Gitea refuse : `permission mode invalid`,
# les cinq teams d'un coup (mesuré 2026-08-16). Un garde-fou cosmétique transformait l'import en
# panne dure.
# Le prix, mesuré et assumé : `permission` et `units` ne convergent jamais en lecture, donc chaque
# apply annonce et rejoue un update par team. Il réussit, l'apply rend 0 — mais un plan VIDE est
# impossible tant que le provider relit ce champ ainsi. C'est le bruit, pas la panne.
resource "gitea_team" "this" {
  for_each                 = local.teams
  name                     = each.key
  organisation             = gitea_org.fleet.name
  permission               = each.value.permission
  can_create_repos         = each.value.can_create_repos
  include_all_repositories = true
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
  team_id  = gitea_team.this["system"].id
  username = var.system_account
}

resource "gitea_team_membership" "writers" {
  for_each   = toset(var.writers)
  team_id    = gitea_team.this["writers"].id
  username   = each.key
  depends_on = [gitea_user.role]
}

resource "gitea_team_membership" "judges" {
  for_each   = toset(var.judges)
  team_id    = gitea_team.this["judges"].id
  username   = each.key
  depends_on = [gitea_user.role]
}

resource "gitea_team_membership" "externals" {
  for_each   = toset(var.externals)
  team_id    = gitea_team.this["externals"].id
  username   = each.key
  depends_on = [gitea_user.role]
}

# LE COMPTE BUILT-IN, et il n'est PAS une personne : il tient le siège du compte que l'admin d'une
# forge crée à son installation. Sa raison d'être aujourd'hui est un TUTORIEL — il donne à l'admiral
# une cible sur laquelle exercer la promotion (`is_admin` sur la forge → onglet admin du deck à la
# session suivante), sans avoir à enrôler une vraie personne pour essayer.
#
# `count` et pas une ressource inconditionnelle : `humans` n'existe que dans l'org système (cf. la
# table plus haut), donc l'adhésion la suit. Une org de catalogue n'a ni la team ni ce compte.
# ⚠ DEUX CONDITIONS, PAS UNE (⚖ user 2026-08-30) : l'org système, ET un compte de démonstration à
# inscrire. `builtin_human` est vide sur un déploiement de travail — l'adhésion nommerait alors un
# compte « » que rien ne crée.
resource "gitea_team_membership" "human" {
  count    = var.org == var.system_org && var.builtin_human != "" ? 1 : 0
  team_id  = gitea_team.this["humans"].id
  username = var.builtin_human
}

# ⚠ LE COMPTE SYSTÈME N'EST MEMBRE D'AUCUNE TEAM, ET IL NE DOIT PAS LE DEVENIR.
#
# `fleet:humans` répond « qui est une personne de cette fleet ». Une liste qui contient son propre
# lecteur n'est plus un filtre d'enrôlement — c'est une liste que le système peuple. L'adhésion qui
# vivait ici (le système dans `humans`) faisait exactement ça, pour un droit qu'il a déjà.
#
# LA PROPRIÉTÉ DE L'ORG SUFFIT À LIRE LES TEAMS, et c'est ce qu'il faut savoir avant de « réparer »
# une lecture en ajoutant une adhésion : `gitea_team_membership.owner` (plus bas) met le compte
# système dans `Owners`, et depuis ce siège il lit les membres de n'importe quelle team de l'org.
# Mesuré le 2026-08-17 : 200 sur `judges`, `writers` et `externals`, membre d'aucune.

# ─── LA PROPRIÉTÉ DE L'ORG — rapatriée du banc le 2026-08-16 ─────────────────────────────────────
# CE GESTE N'EXISTAIT QU'AU BANC, donc PAS en production. Il vivait à l'étape 4-bis de
# `bench-forge-bootstrap.sh`, dont le commentaire annonçait « et l'admin de l'opérateur en
# production » — sans qu'aucun code ne le fasse jamais nulle part ailleurs. Une forge d'opérateur
# rendait donc 403 au premier `lcars project migrate`, avec « user should be the owner of the repo »
# et rien pour dire pourquoi.
#
# CE QUI L'EMPÊCHAIT EST TOMBÉ AVEC LE PROVIDER 0.8 : la team `Owners` est créée par Gitea avec
# l'org, la recette ne la déclare pas, et son id était introuvable. `data.gitea_teams` (0.8) rend
# la liste des teams d'une org — c'est par là qu'on retrouve son id, et par nulle part ailleurs :
# `data.gitea_team` prend un id NUMÉRIQUE en entrée, il ne cherche pas par nom (mesuré, il rend
# « The argument "id" is required »).
#
# `depends_on` EST LOAD-BEARING. `organisation` se calcule depuis une variable, donc sans lui la
# source serait lue au PLAN — c'est-à-dire avant que l'org existe, et l'apply mourrait sur une
# forge vierge. Avec, la lecture est différée à l'apply, après la création.
data "gitea_teams" "org" {
  organisation = gitea_org.fleet.name
  depends_on   = [gitea_org.fleet]
}

resource "gitea_team_membership" "owner" {
  # `one()` et pas `[0]` : si Gitea cessait un jour de créer `Owners`, `[0]` prendrait la première
  # team venue et donnerait la propriété de l'org à un compte au petit bonheur. `one()` sur un
  # ensemble vide rend `null`, et le membership échoue en le disant.
  team_id  = one([for t in data.gitea_teams.org.teams : t.id if t.name == "Owners"])
  username = var.system_account
}
