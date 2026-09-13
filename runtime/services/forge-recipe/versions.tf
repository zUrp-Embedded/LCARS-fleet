terraform {
  # `for_each` on `import` blocks lands in 1.7 — the existence source of this recipe imports what
  # the forge already carries instead of failing with 409, and it cannot enumerate that set
  # statically. This is the floor of the FEATURE, not the version measured on any given container:
  # pinning an exact release here would lock an operator out for no reason.
  required_version = ">= 1.7"

  required_providers {
    gitea = {
      source = "go-gitea/gitea"
      # 0.8 FLOOR, not cosmetics: `gitea_team`, `gitea_teams`,
      # `gitea_actions_runner_registration_token` and `gitea_actions_runners` DO NOT EXIST in
      # 0.7.0. Half of this recipe stops compiling below this line.
      version = "~> 0.8"
    }

    # La sonde d'existence (`existing.tf`) tourne par ce provider-ci : le provider gitea n'enumere
    # pas les comptes, et ses data sources par-objet ECHOUENT sur un objet absent — or « absent »
    # est exactement ce qu'il faut pouvoir lire pour decider d'importer ou de creer.
    # Espace de noms `hashicorp/` et non `opentofu/` : les deux sont servis par le registre
    # OpenTofu, seul le premier l'est AUSSI par celui de Terraform — la recette reste jouable par
    # les deux binaires, ce qui est deja vrai du provider gitea.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
