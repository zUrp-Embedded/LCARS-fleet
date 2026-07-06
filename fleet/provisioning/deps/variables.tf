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
  description = "Login de l'humain, miroir de l'user OS opérateur (ex. lordzurp)."
}

variable "human_email" {
  type        = string
  description = "Email de l'humain."
}
