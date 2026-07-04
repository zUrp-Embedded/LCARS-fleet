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
  @default_architect_pod_id "permanent-architect"

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

  @doc """
  Pod id de l'ARCHITECTE permanent (le sas UNIQUE vers l'humain). Override par l'opt `:architect_pod_id`
  (test) ; sinon config `:fleet_pilot, :architect_pod_id` (défaut `"permanent-architect"`, id
  déterministe posé par `PermanentBoot`). Accesseur UNIQUE — le défaut n'est PAS réécrit chez les
  appelants (`StepRunConsumer.kick_architect`, `Poller` re-kick des issues `lcars-awaits-arch`).
  """
  @spec architect_pod_id(keyword()) :: String.t()
  def architect_pod_id(opts \\ []) do
    Keyword.get(opts, :architect_pod_id) ||
      Application.get_env(:fleet_pilot, :architect_pod_id, @default_architect_pod_id)
  end
end
