defmodule Fleet.Pilot.Roles do
  @moduledoc """
  **Roles of the single-brick model** — accessors for the workshop's roles (producer, judges,
  gatekeeper). This module is the SINGLE accessor (without it the resolution would be rewritten in
  each caller). Override per project/test via the opts.

  The three roles live HERE: producer (`producer_role/1`), jury (`jury/2`) and gatekeeper
  (`gatekeeper_role/1`). `Fleet.Pilot.ProjectOnboard` and `Fleet.Pilot.GatekeeperSeal` delegate here
  (never an `engineer`/`gatekeeper` literal rewritten at the caller).

  ## The structural roles are RESOLVED, not defaulted

  `producer_role/1` and `gatekeeper_role/1` used to fall back on the literals `"engineer"` and
  `"gatekeeper"`. A default is **a requirement that gave up on being verified**: the runtime needs a
  producer, and instead of demanding one it guessed. A catalogue carrying no producer booted green
  and failed at the first spawn — far from the deploy fault, exactly what `Fleet.Spawner.CanonProof`
  was written to prevent everywhere else.

  They now resolve by CAPABILITY (`spec.capabilities`, the B-03 mechanism): `producer` for the one
  that codes the brick, `exception_judge` for the one that signs the merge. The catalogue already
  declared both — the resolver was what was missing, not the field. Substituting a role stays a
  cap-profile edit; there is simply no longer a name the code falls back to when the catalogue is
  silent.

  Resolution is **fail-loud on zero AND on several**: for a structural role, an ambiguity is a broken
  catalogue, not a choice to arbitrate at random. `Fleet.Pilot.Application.validate_structural_roles!/0`
  runs it at boot, so a catalogue that cannot name its producer refuses readiness instead of dying at
  the first dispatch.

  **Last revised**: 2026-08-01
  """

  require Logger

  # The capability each structural role is resolved BY. Not a role name: the point of B-03 is that a
  # gate resolves a responsibility, never a magic name.
  @producer_capability :producer
  @gatekeeper_capability :exception_judge

  @doc """
  PRODUCER role of the single-brick model (the one that codes the brick). Override by the opt
  `:producer_role` (project/test), then config `:fleet_pilot, :producer_role`; otherwise RESOLVED
  from the catalogue by the `producer` capability. Raises if no role declares it, or if several do.
  """
  @spec producer_role(keyword()) :: String.t()
  def producer_role(opts \\ []) do
    Keyword.get(opts, :producer_role) ||
      Application.get_env(:fleet_pilot, :producer_role) ||
      resolve_structural!(@producer_capability, "producer")
  end

  @doc """
  Resolves BOTH structural roles, raising on the first that cannot be. Called at rail boot
  (`Fleet.Pilot.Application`) so a catalogue that names neither refuses readiness rather than
  wedging the first dispatch. Returns them for the log.
  """
  @spec resolve_structural_roles!(keyword()) :: %{producer: String.t(), gatekeeper: String.t()}
  def resolve_structural_roles!(opts \\ []),
    do: %{producer: producer_role(opts), gatekeeper: gatekeeper_role(opts)}

  # ONE resolution for both — a second copy would be a second dialect of "structural role".
  defp resolve_structural!(capability, label) do
    case Fleet.CapProfile.roles_with_capability(capability) do
      {:ok, [role]} ->
        role

      {:ok, []} ->
        raise "Fleet.Pilot.Roles: no catalogue role declares the #{label} capability " <>
                "(#{inspect(capability)}) — the single-brick model has no #{label}. A catalogue " <>
                "must NAME its structural roles; there is no default to fall back on. Fix the catalogue."

      {:ok, roles} ->
        raise "Fleet.Pilot.Roles: #{length(roles)} catalogue roles declare the #{label} capability " <>
                "(#{inspect(capability)}): #{inspect(roles)} — a structural role is unique by " <>
                "construction, and picking one at random would be an arbitrary fleet-wide policy. " <>
                "Fix the catalogue."

      {:error, reason} ->
        raise "Fleet.Pilot.Roles: cap-profile catalogue not enumerable (#{inspect(reason)}) while " <>
                "resolving the #{label} role — broken deploy, fail-loud."
    end
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

        # Same stance as the intensity fallback: the never-stall substitution stays, but
        # swapping a project's DECLARED card for the default is a judgment-layer change —
        # recorded as an incident (recurrence → sysadmin issue), never only a warning.
        incident =
          Keyword.get(opts, :incident_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4)

        _ =
          try do
            incident.("card", repo, :declared_card_unloadable,
              reason_detail: "#{inspect(name)}: #{Exception.message(e)}"
            )
          catch
            # An incident that cannot record must not break the burn (never-stall) — loud, not silent.
            kind, why ->
              Logger.warning(
                "Roles: fallback incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
              )
          end

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
  (project/test), then config `:fleet_pilot, :gatekeeper_role`; otherwise RESOLVED from the catalogue
  by the `exception_judge` capability. Raises if no role declares it, or if several do.
  """
  @spec gatekeeper_role(keyword()) :: String.t()
  def gatekeeper_role(opts \\ []) do
    Keyword.get(opts, :gatekeeper_role) ||
      Application.get_env(:fleet_pilot, :gatekeeper_role) ||
      resolve_structural!(@gatekeeper_capability, "gatekeeper")
  end

  # (`architect_pod_id/1` — the singleton "permanent-architect" accessor + its config knob — was
  # REMOVED by the 2026-07-19 reorg: the architect is PER-PROJECT, its pod id derives from the repo
  # via the single authority `Fleet.Pilot.ProjectArchitect.pod_id_for/1`.)
end
