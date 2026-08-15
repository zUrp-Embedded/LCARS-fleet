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

variable "admiral_username" {
  type        = string
  default     = ""
  description = "Login forge du MASTER (le sysadmin de la boîte : `admiral` au banc, le login de l'installeur en prod). Sert UNIQUEMENT à lui poser le badge de charte — il reçoit celui de l'ex-compte `starfleet`, supprimé le 2026-08-15. Vide = aucun avatar posé sur un compte humain, ce qui est le défaut VOULU : la charte ne décide pas de la tête d'une personne (cf. `provision-forge-avatars.sh`, en-tête de la table). Ce module ne CRÉE pas ce compte — il existe avant lui (installateur, ou `bench-forge-bootstrap.sh` au banc)."

  # Le login part dans une ligne de commande shell (`local-exec`). Un login Gitea est alphanumérique
  # + `.`, `-`, `_`, et commence par un alphanumérique : on le VÉRIFIE ici plutôt que de l'espérer,
  # sinon un login exotique casse la commande ou y injecte. Vide reste valide — c'est le défaut.
  validation {
    condition     = var.admiral_username == "" || can(regex("^[a-zA-Z0-9][a-zA-Z0-9._-]*$", var.admiral_username))
    error_message = "admiral_username: login forge invalide (alphanumérique, puis . - _ ; ou vide pour ne poser aucun badge)."
  }
}
