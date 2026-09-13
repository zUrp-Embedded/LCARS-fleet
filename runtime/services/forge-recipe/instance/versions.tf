terraform {
  # Same floors as the catalogue module next door, for the same reasons: `for_each` on `import`
  # blocks (1.7) and the data sources absent from provider 0.7.0. The two modules apply against
  # the SAME forge with SEPARATE states — a version drift between them surfaces as a provider
  # crash in whichever one is stale, never as a clear message.
  required_version = ">= 1.7"

  required_providers {
    gitea = {
      source  = "go-gitea/gitea"
      version = "~> 0.8"
    }

    # Meme sonde d'existence que le module catalogue, meme script — cf. `existing.tf`.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
