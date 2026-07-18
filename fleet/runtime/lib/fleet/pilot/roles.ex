defmodule Fleet.Pilot.Roles do
  @moduledoc """
  **Roles of the single-brick model** — accessors for the workshop's roles (producer, judges,
  gatekeeper). SINGLE data source = `config/config.exs`; this module is the SINGLE accessor (without it
  the default would be hard-rewritten in each caller). Override per project/test via the opts.

  The three roles live HERE: producer (`producer_role/1`), jury (`reviewer_roles/1`) and gatekeeper
  (`gatekeeper_role/1`). `Fleet.Pilot.ProjectOnboard` and `Fleet.Pilot.GatekeeperSeal` delegate here
  (never an `engineer`/`gatekeeper` default rewritten at the caller).

  **Last revised**: 2026-07-18
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
  producer's PR, whose approvals gate the seal, and whose count sizes the branch
  protection at onboarding.

  **THE CARD is the single source** (`spec.jury`, schema-required — the card governs the
  judgment layer; there is NO engine config for the jury). Pass the loaded workflow map
  when in hand; `nil` loads the delegation DEFAULT card (today: every issue runs it —
  per-project card selection is the intensity chain, F-29). The `:reviewer_roles` opt is
  an INJECTION SEAM (tests / hermetic overrides), never a config: the config key died
  with the parallel lane.
  """
  @spec jury(map() | nil, keyword()) :: [String.t()]
  def jury(workflow_map, opts \\ []) do
    case Keyword.fetch(opts, :reviewer_roles) do
      {:ok, jury} when is_list(jury) -> jury
      :error -> jury_of(workflow_map, opts)
    end
  end

  defp jury_of(%{"jury" => jury}, _opts) when is_list(jury), do: jury
  defp jury_of(nil, opts), do: Fleet.Workflow.Loader.load!(delegation_workflow_map(opts))["jury"]

  @doc """
  Name of the delegation DEFAULT workflow map (burned on any routeless issue and used as
  the jury source when no per-issue map is in hand). Opt `:delegation_workflow_map` (test),
  else config `:fleet_pilot, :delegation_workflow_map` (default `"brief-gate"`). SINGLE
  accessor — the literal is not rewritten at the callers.
  """
  @spec delegation_workflow_map(keyword()) :: String.t()
  def delegation_workflow_map(opts \\ []) do
    Keyword.get(opts, :delegation_workflow_map) ||
      Application.get_env(:fleet_pilot, :delegation_workflow_map, "brief-gate")
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
