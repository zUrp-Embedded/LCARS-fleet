defmodule Fleet.Pilot.Roles do
  @moduledoc """
  **Rôles du modèle single-brique** — accesseurs aux rôles de l'atelier (producteur, juges,
  gatekeeper). Source data UNIQUE = `config/config.exs` ; ce module est l'accesseur UNIQUE (sans lui
  le défaut serait réécrit en dur dans chaque appelant). Surcharge par projet/test via les opts.

  Les trois rôles vivent ICI : producteur (`producer_role/1`), jury (`reviewer_roles/1`) et gatekeeper
  (`gatekeeper_role/1`). `Fleet.Pilot.ProjectOnboard` et `Fleet.Pilot.GatekeeperSeal` délèguent ici
  (plus aucun défaut `engineer`/`gatekeeper` réécrit chez l'appelant).
  """

  @default_producer_role "engineer"
  @default_gatekeeper_role "gatekeeper"

  @doc """
  Rôle PRODUCTEUR du modèle single-brique (celui qui code la brique, ex. `engineer`). Override par l'opt
  `:producer_role` (projet/test) ; sinon config `:fleet_pilot, :producer_role` (défaut `"engineer"`).
  """
  @spec producer_role(keyword()) :: String.t()
  def producer_role(opts \\ []) do
    Keyword.get(opts, :producer_role) ||
      Application.get_env(:fleet_pilot, :producer_role, @default_producer_role)
  end

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

  @doc """
  Rôle GATEKEEPER (gardien des PRs, signe les fusions). Override par l'opt `:gatekeeper_role`
  (projet/test) ; sinon config `:fleet_pilot, :gatekeeper_role` (défaut `"gatekeeper"`).
  """
  @spec gatekeeper_role(keyword()) :: String.t()
  def gatekeeper_role(opts \\ []) do
    Keyword.get(opts, :gatekeeper_role) ||
      Application.get_env(:fleet_pilot, :gatekeeper_role, @default_gatekeeper_role)
  end
end
