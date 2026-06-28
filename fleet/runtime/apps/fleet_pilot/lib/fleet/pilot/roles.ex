defmodule Fleet.Pilot.Roles do
  @moduledoc """
  **Rôles du modèle single-brique** — accesseurs aux rôles de l'atelier (producteur, juges,
  gatekeeper). Source data UNIQUE = `config/config.exs` ; ce module est l'accesseur UNIQUE (sans lui
  le défaut serait réécrit en dur dans chaque appelant). Surcharge par projet/test via les opts.

  Pour l'instant seul le jury (`reviewer_roles/1`) vit ici ; `producer_role`/`gatekeeper_role`
  pourront l'y rejoindre, mais restent chez leurs appelants tant qu'ils ne sont pas factorisés.
  """

  @doc """
  Jury (juges PR) du modèle single-brique : les rôles dont la review est demandée sur la PR d'un
  producteur, et seedés à l'onboarding. Override par l'opt `:reviewer_roles` (projet/test) ; sinon la
  config (source data unique, `config/config.exs`). `fetch_env!` = fail-loud si la config est absente
  (elle DOIT être posée — aucun défaut codé en dur ici).
  """
  @spec reviewer_roles(keyword()) :: [String.t()]
  def reviewer_roles(opts \\ []) do
    Keyword.get(opts, :reviewer_roles) || Application.fetch_env!(:fleet_pilot, :reviewer_roles)
  end
end
