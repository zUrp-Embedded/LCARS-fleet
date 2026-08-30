variable "gitea_url" {
  type        = string
  description = "Base URL de la forge Gitea cible (ex. http://localhost:3000)."
}

variable "gitea_token" {
  type        = string
  sensitive   = true
  # Le qualificatif « ÉPHÉMÈRE : révoqué après apply » vivait ici et il est FAUX depuis l'arbitrage
  # du 2026-08-16 : toute évolution de structure — un catalogue de plus, un rôle de plus — a besoin
  # de cette même autorité, au jour 400 comme au premier jour. Rien ne le POSE durablement encore ;
  # cette ligne dit donc ce qu'il est, pas une durée de vie que personne ne tient.
  description = "Master/admin-token site-admin : la seule autorité qui CRÉE. Passé via TF_VAR_gitea_token (jamais sur disque/git)."
}

variable "seed_password" {
  type        = string
  sensitive   = true
  description = "Mot de passe initial des comptes. Bots : simple formalité API (ils s'authentifient par token). Humain : change au 1er login."
}

# ⚠ CETTE VARIABLE S'APPELAIT `human_username` ET SON DÉFAUT TOMBAIT D'UNE VARIABLE MORTE. Côté
# boîte elle était alimentée par `${LCARS_FORGE_HUMAN:-${LCARS_HUMAN:-lcars}}`, et `LCARS_HUMAN`
# n'existe plus depuis identity-v2 (cf. `console.sh` : « Pas de defaut : identite-v2 a retire
# l'humain unique »). Le nom `lcars` n'était donc plus un choix, c'était un résidu — alors que le
# compte qu'il désigne, lui, a une raison d'être précise.
#
# CE COMPTE N'EST PAS UNE PERSONNE : il tient le siège du compte que l'admin d'une forge crée à son
# installation, et il sert de cible au tutoriel de promotion (l'admiral le passe `is_admin`, l'onglet
# admin du deck apparaît à sa session suivante). Un déploiement réel ne « passe pas le sien » — les
# vraies personnes s'inscrivent seules et un admin les ajoute à `humans`.
# ⚠ VIDE = AUCUN COMPTE, ET C'EST LE DÉFAUT (⚖ user 2026-08-30). Il valait `lcars`, donc tout
# déploiement semait ce compte — le commentaire ci-dessus disait pourtant déjà qu'un déploiement
# réel ne passe pas le sien. La conséquence manquait : elle est ici. Un banc le NOMME
# (`bench-forge-bootstrap.sh`), et c'est du confort assumé sur une machine jetable.
variable "builtin_human" {
  type        = string
  default     = ""
  description = "Login du compte BUILT-IN de démonstration — pas une personne : le siège tutoriel sur lequel un admin exerce la promotion. VIDE (défaut) = aucun compte n'est semé, et c'est le cas d'un déploiement de travail."
}

variable "builtin_email" {
  type        = string
  default     = "lcars@lcars.local"
  description = "Email du compte built-in. Formalité d'API : ce compte ne reçoit rien et ne mappe aucun commit d'humain."
}

# ⚠ `admiral_username` A ETE RETIREE (2026-08-16), et son absence est l'arbitrage : le login du
# master ne se parametre pas, il se DERIVE. Une instance Gitea a toujours un premier compte,
# `id = 1`, site-admin par construction — `provision-forge-charte.sh` le resout lui-meme, pour son
# badge ET pour le nom de son siege, d'une seule resolution. Une variable pour une donnee derivable
# est une occasion de la contredire.
