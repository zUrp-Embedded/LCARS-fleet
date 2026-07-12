defmodule Fleet.Pilot.Roles do
  @moduledoc """
  **Roles of the single-brick model** — accessors for the workshop's roles (producer, judges,
  gatekeeper). SINGLE data source = `config/config.exs`; this module is the SINGLE accessor (without it
  the default would be hard-rewritten in each caller). Override per project/test via the opts.

  The three roles live HERE: producer (`producer_role/1`), jury (`reviewer_roles/1`) and gatekeeper
  (`gatekeeper_role/1`). `Fleet.Pilot.ProjectOnboard` and `Fleet.Pilot.GatekeeperSeal` delegate here
  (no more `engineer`/`gatekeeper` default rewritten at the caller).
  """

  @default_producer_role "engineer"
  @default_gatekeeper_role "gatekeeper"
  @default_architect_pod_id "permanent-architect"

  @doc """
  PRODUCER role of the single-brick model (the one that codes the brick, e.g. `engineer`). Override by the opt
  `:producer_role` (project/test); otherwise config `:fleet_pilot, :producer_role` (default `"engineer"`).
  """
  @spec producer_role(keyword()) :: String.t()
  def producer_role(opts \\ []) do
    Keyword.get(opts, :producer_role) ||
      Application.get_env(:fleet_pilot, :producer_role, @default_producer_role)
  end

  @doc """
  Jury (PR judges) of the single-brick model: the roles whose review is requested on a
  producer's PR, and seeded at onboarding. Override by the opt `:reviewer_roles` (project/test); otherwise the
  config (single data source, `config/config.exs`). `fetch_env!` = fail-loud if the config is absent
  (it MUST be set — no hard-coded default here).
  """
  @spec reviewer_roles(keyword()) :: [String.t()]
  def reviewer_roles(opts \\ []) do
    Keyword.get(opts, :reviewer_roles) || Application.fetch_env!(:fleet_pilot, :reviewer_roles)
  end

  @doc """
  GATEKEEPER role (PR guardian, signs the merges). Override by the opt `:gatekeeper_role`
  (project/test); otherwise config `:fleet_pilot, :gatekeeper_role` (default `"gatekeeper"`).
  """
  @spec gatekeeper_role(keyword()) :: String.t()
  def gatekeeper_role(opts \\ []) do
    Keyword.get(opts, :gatekeeper_role) ||
      Application.get_env(:fleet_pilot, :gatekeeper_role, @default_gatekeeper_role)
  end

  @doc """
  Pod id of the permanent ARCHITECT (the SINGLE airlock to the human). Override by the opt `:architect_pod_id`
  (test); otherwise config `:fleet_pilot, :architect_pod_id` (default `"permanent-architect"`,
  deterministic id set by `PermanentBoot`). SINGLE accessor — the default is NOT rewritten at the
  callers (`StepRunConsumer.kick_architect`, `Poller` re-kick of `lcars-awaits-arch` issues).
  """
  @spec architect_pod_id(keyword()) :: String.t()
  def architect_pod_id(opts \\ []) do
    Keyword.get(opts, :architect_pod_id) ||
      Application.get_env(:fleet_pilot, :architect_pod_id, @default_architect_pod_id)
  end
end
