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

variable "human_username" {
  type        = string
  default     = "lcars"
  description = "Login de l'humain daily, miroir de l'user OS de la boîte (`id -un`, sans table de correspondance). Défaut = l'humain DÉMO ; un déploiement réel passe le sien."
}

variable "human_email" {
  type        = string
  default     = "lcars@lcars.local"
  description = "Email du compte forge de l'humain — celui qui mappe ses commits (LCARS_HUMAN_EMAIL côté boîte doit porter le même)."
}

# ⚠ `admiral_username` A ETE RETIREE (2026-08-16), et son absence est l'arbitrage : le login du
# master ne se parametre pas, il se DERIVE. Une instance Gitea a toujours un premier compte,
# `id = 1`, site-admin par construction — `provision-forge-charte.sh` le resout lui-meme, pour son
# badge ET pour le nom de son siege, d'une seule resolution. Une variable pour une donnee derivable
# est une occasion de la contredire.
