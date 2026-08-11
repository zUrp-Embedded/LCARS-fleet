variable "gitea_url" {
  type        = string
  description = "Base URL de la forge Gitea cible (ex. http://localhost:3000)."
}

variable "gitea_token" {
  type        = string
  sensitive   = true
  description = "Master/admin-token du bootstrap. ÉPHÉMÈRE : révoqué après apply. Passé via TF_VAR_gitea_token (jamais sur disque/git)."
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
