defmodule Fleet.Project.Roles do
  @moduledoc """
  Shared accessors for structural roles and card-derived jury, CI and verdict policy.
  Structural resolution uses capabilities rather than role-name defaults. Truthy
  option overrides precede application overrides and bypass capability lookup;
  their types and declared capabilities are not validated here.

  Boot requires at least one producer and resolves three singletons: exception_judge,
  conflict_resolver and project_delegate. Multiple producers are valid because cards
  name their producer per step; producer_role/1 requires a singleton only when its
  last-resort lookup is needed. Singleton overrides also bypass uniqueness checks.

  Gatekeeper judges; the conflict-resolver role executes the merge rail. Their
  capability keys remain distinct even if a fixture assigns both to one profile.
  """

  require Logger

  alias Fleet.Workflow.Loader

  # Resolve responsibilities by capability rather than hardcoded role names.
  @producer_capability :producer
  @gatekeeper_capability :exception_judge
  # Execution and judgment have separate configuration keys.
  @conflict_resolver_capability :conflict_resolver
  @delegate_capability :project_delegate

  # Why each singleton is one, in the operator's terms. See `resolve_structural!/3`.
  @gatekeeper_uniqueness "single writer of the signed merge"
  @conflict_resolver_uniqueness "single addressee of a conflict the producer could not close"
  @delegate_uniqueness "single addressee of a project escalation, ensured per repo and named by no card"

  @doc """
  Returns the truthy :producer_role option, then :pilot_producer_role application
  setting, otherwise the sole role with producer capability (raising on zero/multiple).
  StepRunCompleter uses this last resort when it cannot recover the producer from
  the run branch; normal dispatch uses the card's step role.
  """
  @spec producer_role(keyword()) :: String.t()
  def producer_role(opts \\ []) do
    Keyword.get(opts, :producer_role) ||
      Application.get_env(:lcars_fleet, :pilot_producer_role) ||
      resolve_producer!()
  end

  defp resolve_producer! do
    case Fleet.CapProfile.roles_with_capability(@producer_capability) do
      {:ok, [role]} ->
        role

      {:ok, []} ->
        raise "Fleet.Project.Roles: no catalogue role declares the producer capability " <>
                "(#{inspect(@producer_capability)}) — no card can name a producer. Fix the catalogue."

      {:ok, roles} ->
        raise "Fleet.Project.Roles: #{length(roles)} roles declare the producer capability " <>
                "(#{inspect(roles)}), and this is the LAST-RESORT path — the card names the producer " <>
                "per step, the run carries it in the feature branch, and both were unavailable here. " <>
                "On a catalogue with several producers there is no fleet-wide default to fall back " <>
                "on; set `:lcars_fleet, :pilot_producer_role` if this deployment has one."

      {:error, reason} ->
        raise "Fleet.Project.Roles: cap-profile catalogue not enumerable (#{inspect(reason)}) while " <>
                "resolving the producer role — broken deploy, fail-loud."
    end
  end

  @doc """
  Returns the configured project delegate or the sole role with that capability.
  """
  @spec project_delegate_role(keyword()) :: String.t()
  def project_delegate_role(opts \\ []) do
    Keyword.get(opts, :project_delegate_role) ||
      Application.get_env(:lcars_fleet, :pilot_project_delegate_role) ||
      resolve_structural!(@delegate_capability, "project delegate", @delegate_uniqueness)
  end

  @doc """
  Runs resolve_structural_roles!/1 with default options and returns :ok, or raises.
  """
  @spec validate_structural_roles!() :: :ok
  def validate_structural_roles! do
    _ = resolve_structural_roles!()
    :ok
  end

  @doc """
  Returns producers plus resolved gatekeeper, conflict_resolver and project_delegate.
  Producer enumeration requires at least one and ignores producer_role overrides.
  Other roles use their normal option/config precedence; without overrides each
  must have exactly one capability holder. Delegate uniqueness gives project
  escalations a single addressee when no card selects one.
  """
  @spec resolve_structural_roles!(keyword()) :: %{
          producers: [String.t()],
          gatekeeper: String.t(),
          conflict_resolver: String.t(),
          project_delegate: String.t()
        }
  def resolve_structural_roles!(opts \\ []) do
    %{
      producers: producers!(),
      gatekeeper: gatekeeper_role(opts),
      conflict_resolver: conflict_resolver_role(opts),
      project_delegate: project_delegate_role(opts)
    }
  end

  # AT LEAST one — the cards choose among them.
  defp producers! do
    case Fleet.CapProfile.roles_with_capability(@producer_capability) do
      {:ok, []} ->
        raise "Fleet.Project.Roles: no catalogue role declares the producer capability " <>
                "(#{inspect(@producer_capability)}) — no card could name a producer, the fleet " <>
                "produces nothing. Fix the catalogue."

      {:ok, roles} ->
        roles

      {:error, reason} ->
        raise "Fleet.Project.Roles: cap-profile catalogue not enumerable (#{inspect(reason)}) while " <>
                "resolving the producers — broken deploy, fail-loud."
    end
  end

  # Keep the role-specific uniqueness reason in the refusal diagnostic.
  defp resolve_structural!(capability, label, why) do
    case Fleet.CapProfile.roles_with_capability(capability) do
      {:ok, [role]} ->
        role

      {:ok, []} ->
        raise "Fleet.Project.Roles: no catalogue role declares the #{label} capability " <>
                "(#{inspect(capability)}) — the single-brick model has no #{label}. A catalogue " <>
                "must NAME it; there is no default to fall back on. Fix the catalogue."

      {:ok, roles} ->
        raise "Fleet.Project.Roles: #{length(roles)} catalogue roles declare the #{label} capability " <>
                "(#{inspect(capability)}): #{inspect(roles)} — this one is unique BY DESIGN " <>
                "(#{why}), and picking one at random would be an arbitrary fleet-wide policy. " <>
                "Fix the catalogue."

      {:error, reason} ->
        raise "Fleet.Project.Roles: cap-profile catalogue not enumerable (#{inspect(reason)}) while " <>
                "resolving the #{label} role — broken deploy, fail-loud."
    end
  end

  @doc """
  Returns list-valued :reviewer_roles immediately, otherwise the card's list-valued
  jury. A nil card loads the delegation default with workflow_maps_root/catalogue_root
  options. Non-list overrides or malformed card shapes can raise; entries are not validated.
  """
  @spec jury(map() | nil, keyword()) :: [String.t()]
  def jury(workflow_map, opts \\ []) do
    case Keyword.fetch(opts, :reviewer_roles) do
      {:ok, jury} when is_list(jury) -> jury
      :error -> jury_of(workflow_map, opts)
    end
  end

  defp jury_of(%{"jury" => jury}, _opts) when is_list(jury), do: jury
  # The delegation card of the CALLER's catalogue: the opts carry it (`:catalogue_root`,
  # `:workflow_maps_root`) exactly as the fallback of `project_card_or_default/2` passes them.
  defp jury_of(nil, opts),
    do:
      Loader.load!(
        delegation_workflow_map(opts),
        Keyword.take(opts, [:workflow_maps_root, :catalogue_root])
      )["jury"]

  @doc """
  Returns :reviewer_roles when it is a list, otherwise loads the project's card
  and returns its jury (including []). A failed declared-card load logs, attempts
  an incident and loads the delegation default; failure of that fallback can raise.
  """
  @spec project_jury(String.t(), keyword()) :: [String.t()]
  def project_jury(repo, opts \\ []) when is_binary(repo) do
    case Keyword.fetch(opts, :reviewer_roles) do
      {:ok, jury} when is_list(jury) -> jury
      :error -> jury_of(load_project_card(repo, opts), opts)
    end
  end

  @doc """
  Maps required/ignore string policies to atoms. Any other card or value logs and
  returns :required: missing mandatory CI policy must not silently disable the gate.
  """
  @spec ci(map() | nil) :: :required | :ignore
  def ci(%{"ci" => "required"}), do: :required
  def ci(%{"ci" => "ignore"}), do: :ignore

  def ci(card) do
    Logger.warning(
      "Roles: card #{inspect(get_card_name(card))} carries no readable `ci` policy " <>
        "(#{inspect(is_map(card) && Map.get(card, "ci"))}) — `spec.ci` is mandatory, so this card " <>
        "bypassed schema validation. Gating on CI rather than assuming green."
    )

    :required
  end

  defp get_card_name(card) when is_map(card), do: Map.get(card, "name")
  defp get_card_name(_), do: nil

  @doc """
  Returns a map-valued verdict_policy, otherwise nil without logging.
  This field is optional, unlike ci; nil keeps Jury's boolean aggregation.
  Policy contents are not validated by this accessor.
  """
  @spec verdict_policy(map() | any()) :: map() | nil
  def verdict_policy(%{"verdict_policy" => %{} = policy}), do: policy
  def verdict_policy(_card), do: nil

  @doc "Verdict policy of the PROJECT's declared card — twin of `project_ci/2`, same fallback family."
  @spec project_verdict_policy(String.t(), keyword()) :: map() | nil
  def project_verdict_policy(repo, opts \\ []) when is_binary(repo),
    do: verdict_policy(load_project_card(repo, opts))

  @doc """
  Uses the issue route's card when get_route succeeds and the card loads as a map.
  A routed card with no policy returns nil directly. Returned route/load errors
  fall back to the project's declared card, which may have a policy of its own.

  :forge_opts goes to the forge call; routed-card loading uses repo catalogue options,
  not caller workflow_maps_root overrides. Loader exceptions on that route are caught,
  but forge exceptions and failures of project fallback are not universally rescued.
  Merge decisions and status readers share this resolution to avoid policy drift.
  """
  @spec verdict_policy_for(module(), String.t(), integer(), keyword()) :: map() | nil
  def verdict_policy_for(forge, repo, issue_number, opts \\ [])
      when is_binary(repo) and is_integer(issue_number) do
    forge_opts = Keyword.get(opts, :forge_opts, [])

    with {:ok, {map_name, _step}} <- forge.get_route(repo, issue_number, forge_opts),
         {:ok, card} when is_map(card) <- safe_load_card(map_name, repo) do
      verdict_policy(card)
    else
      _ -> verdict_policy(load_project_card(repo, opts))
    end
  end

  # Convert routed-card load exceptions to the project fallback signal.
  defp safe_load_card(map_name, repo) do
    {:ok, Loader.load!(map_name, Loader.card_opts_for_repo(repo))}
  rescue
    _ -> :error
  end

  @doc """
  Returns CI policy from the same project-card loading path used by project_jury/2.
  Human/routeless PRs must retain the project's CI choice as well as its jury.
  """
  @spec project_ci(String.t(), keyword()) :: :required | :ignore
  def project_ci(repo, opts \\ []) when is_binary(repo), do: ci(load_project_card(repo, opts))

  defp load_project_card(repo, opts) do
    name = Fleet.Project.Declaration.pipeline_default(repo, opts)
    loader_opts = Keyword.take(opts, [:workflow_maps_root])

    # Use the repo's card directory unless an explicit workflow_maps_root key was supplied.
    loader_opts =
      case {loader_opts, Loader.card_root_for_repo(repo)} do
        {[], dir} when is_binary(dir) -> [catalogue_root: dir]
        {given, _} -> given
      end

    try do
      Loader.load!(name, loader_opts)
    rescue
      e ->
        Logger.warning(
          "Roles: project card #{inspect(name)} for #{repo} does not load " <>
            "(#{Exception.message(e)}) — falling back to the delegation default card"
        )

        incident =
          Keyword.get(opts, :incident_fun, &Fleet.Project.Incidents.emit/4)

        _ =
          try do
            incident.("card", repo, :declared_card_unloadable,
              reason_detail: "#{inspect(name)}: #{Exception.message(e)}"
            )
          catch
            kind, why ->
              Logger.warning(
                "Roles: fallback incident NOT recorded (#{inspect(kind)}: #{inspect(why)})"
              )
          end

        Loader.load!(delegation_workflow_map(opts), loader_opts)
    end
  end

  @doc """
  Returns truthy :delegation_workflow_map or Catalogue.default_card().
  This accessor does not take a repo or forward directory options to Catalogue;
  a project-specific loader root does not itself change this fallback card name.
  """
  @spec delegation_workflow_map(keyword()) :: String.t() | nil
  def delegation_workflow_map(opts \\ []) do
    Keyword.get(opts, :delegation_workflow_map) || Fleet.Catalogue.default_card()
  end

  @doc """
  Returns truthy :workshop_workflow_map or finds a workshop card by capability-like
  step fields via Loader. No matching card returns nil.

  Here a binary :catalogue_root means a repo identifier, not a directory: it is
  translated through Loader.card_opts_for_repo/1 and other options are discarded.
  Without it, options pass through to Loader.workshop_card_name/1.
  """
  @spec workshop_workflow_map(keyword()) :: String.t() | nil
  def workshop_workflow_map(opts \\ []) do
    Keyword.get(opts, :workshop_workflow_map) ||
      Loader.workshop_card_name(workshop_scope(opts))
  end

  # This API's catalogue_root is a repo, unlike Loader's same-named directory option.
  defp workshop_scope(opts) do
    case Keyword.get(opts, :catalogue_root) do
      repo when is_binary(repo) -> Loader.card_opts_for_repo(repo)
      _ -> opts
    end
  end

  @doc """
  Returns the configured gatekeeper or the sole role with the `exception_judge` capability.
  """
  @spec gatekeeper_role(keyword()) :: String.t()
  def gatekeeper_role(opts \\ []) do
    Keyword.get(opts, :gatekeeper_role) ||
      Application.get_env(:lcars_fleet, :pilot_gatekeeper_role) ||
      resolve_structural!(@gatekeeper_capability, "gatekeeper", @gatekeeper_uniqueness)
  end

  @doc """
  Returns truthy :conflict_resolver_role, then :pilot_conflict_resolver_role,
  otherwise resolves a unique conflict_resolver capability holder.

  The historical key names only part of the role: it executes conflict resolution
  and the merge rail, while exception_judge decides. Keep the keys separate so
  changing an executor does not change the judge. Renaming this capability requires
  a coordinated catalogue/profile/validator/prompt migration, not a local doc edit.
  These accessors do not themselves enforce worker/judge profile separation.
  """
  @spec conflict_resolver_role(keyword()) :: String.t()
  def conflict_resolver_role(opts \\ []) do
    Keyword.get(opts, :conflict_resolver_role) ||
      Application.get_env(:lcars_fleet, :pilot_conflict_resolver_role) ||
      resolve_structural!(
        @conflict_resolver_capability,
        "conflict resolver",
        @conflict_resolver_uniqueness
      )
  end

  # Project pod IDs belong to Architect.pod_id_for/1, not a fleet permanent accessor.
end
