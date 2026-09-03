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

# ⚠ VIDE = AUCUN COMPTE (⚖ user 2026-08-30) — même défaut et même raison que dans `deps/variables.tf`.
variable "builtin_human" {
  type        = string
  default     = ""
  description = "Login de l'humain de DÉMONSTRATION d'un banc. VIDE (défaut) = aucun compte semé : un déploiement de travail ne fabrique pas d'humain, les personnes s'inscrivent sur la forge."
}

variable "builtin_email" {
  type        = string
  default     = "lcars@lcars.local"
  description = "Email du compte built-in. Formalité d'API : ce compte ne reçoit rien et ne mappe aucun commit d'humain."
}
