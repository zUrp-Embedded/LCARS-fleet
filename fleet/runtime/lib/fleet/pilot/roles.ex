defmodule Fleet.Pilot.Roles do
  @moduledoc """
  **Roles of the single-brick model** — accessors for the workshop's roles (producer, judges,
  gatekeeper). SINGLE data source = `config/config.exs`; this module is the SINGLE accessor (without it
  the default would be hard-rewritten in each caller). Override per project/test via the opts.

  The three roles live HERE: producer (`producer_role/1`), jury (`jury/2`) and gatekeeper
  (`gatekeeper_role/1`). `Fleet.Pilot.ProjectOnboard` and `Fleet.Pilot.GatekeeperSeal` delegate here
  (never an `engineer`/`gatekeeper` default rewritten at the caller).

  **Last revised**: 2026-07-21
  """

  require Logger

  @default_producer_role "engineer"
  @default_gatekeeper_role "gatekeeper"

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
  Jury of the PROJECT's declared card — the per-issue jury source at every PR call-site
  (review laying, verdict classification, orphan adoption, branch-protection sizing).
  Resolution: `Fleet.Pilot.ProjectIntensity.pipeline_default/2` (the committed declaration;
  absent → delegation default) → loaded card → `spec.jury`. An empty jury is a DELIBERATE
  zero-judge card (schema doctrine) — the caller decides what that means (no review round,
  straight to the sealed merge; the mechanical floor holds regardless).

  The `:reviewer_roles` opt is the injection seam (tests), checked FIRST — no disk read
  under the seam. A declared card that no longer loads falls back LOUD to the delegation
  default (same repair doctrine as the burn: re-declare to fix, never a stalled rail).
  """
  @spec project_jury(String.t(), keyword()) :: [String.t()]
  def project_jury(repo, opts \\ []) when is_binary(repo) do
    case Keyword.fetch(opts, :reviewer_roles) do
      {:ok, jury} when is_list(jury) -> jury
      :error -> jury_of(load_project_card(repo, opts), opts)
    end
  end

  defp load_project_card(repo, opts) do
    name = Fleet.Pilot.ProjectIntensity.pipeline_default(repo, opts)
    loader_opts = Keyword.take(opts, [:workflow_maps_root])

    try do
      Fleet.Workflow.Loader.load!(name, loader_opts)
    rescue
      e ->
        Logger.warning(
          "Roles: project card #{inspect(name)} for #{repo} does not load " <>
            "(#{Exception.message(e)}) — falling back to the delegation default card"
        )

        Fleet.Workflow.Loader.load!(delegation_workflow_map(opts), loader_opts)
    end
  end

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

  # (`architect_pod_id/1` — the singleton "permanent-architect" accessor + its config knob — was
  # REMOVED by the 2026-07-19 reorg: the architect is PER-PROJECT, its pod id derives from the repo
  # via the single authority `Fleet.Pilot.ProjectArchitect.pod_id_for/1`.)
end
