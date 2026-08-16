terraform {
  # `for_each` on `import` blocks lands in 1.7 — the existence source of this recipe imports what
  # the forge already carries instead of failing with 409, and it cannot enumerate that set
  # statically. This is the floor of the FEATURE, not the version measured on any given box:
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
  }
}
