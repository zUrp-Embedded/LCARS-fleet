defmodule Fleet.Pilot.Application do
  require Logger

  alias Fleet.Pilot.IncidentConsumer
  alias Fleet.Pilot.StepRunConsumer
  alias Fleet.Workflow.Loader

  @moduledoc """
  Pilot supervisor. Always starts the Forge Finch pool and optionally OpsObjectSync;
  step processes are enabled by :pilot_step_dispatch?. Step boot requires
  :pilot_forge[:base_url], publishes the workflow image and checks catalogue, signer
  and verdict-schema prerequisites before returning child specs.

  Telemetry precedes Poller. Separate task pools isolate completion and incident
  work; WorktreeSync precedes their merge triggers. step_rail_processes defines the
  readiness population and is checked against step children by tests.
  """

  use Supervisor

  # Require several fully failed samples; a single transient should not flicker readiness.
  @poll_blackout_window 3

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    # CI-11: MCP brief writes require the ops serializer outside step mode too.
    children = [forge_finch_spec()] ++ ops_object_sync_child() ++ step_children()

    # Children resolve collaborators by name, so one-for-one recovery is sufficient.
    opts = [
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    ]

    Supervisor.init(children, opts)
  end

  # Work/ops write serializer (CI-11) — always-on in prod, OFF in test (hermeticity, cf. init).
  defp ops_object_sync_child do
    if Application.get_env(:lcars_fleet, :pilot_start_ops_object_sync, true),
      do: [Fleet.Workflow.OpsObjectSync],
      else: []
  end

  @doc """
  Delegates the pool child spec to Forge, which owns the pool name and configuration.
  """
  @spec forge_finch_spec() :: tuple()
  defdelegate forge_finch_spec, to: Fleet.Forge, as: :finch_spec

  @doc """
  Reports inactive when step dispatch is disabled. Otherwise checks every registered
  step process plus repository-poll and whole-cycle summaries. Missing processes,
  discovered repositories with none served, or a total error window of at least
  #{@poll_blackout_window} samples degrade readiness.

  Partial failures, slow successful polls, no_data and unavailable telemetry alone
  remain healthy. The telemeter's process has its own liveness key. A live poller
  that never polls is indistinguishable from startup with no data; this status is
  not proof of end-to-end progress or a freshness bound.
  """
  @spec step_status() :: {:inactive | :operational | :degraded, map()}
  def step_status do
    if Application.get_env(:lcars_fleet, :pilot_step_dispatch?, false) do
      detail =
        Map.new(step_rail_processes(), fn {key, name} ->
          {key, is_pid(Process.whereis(name))}
        end)

      # Keep per-repository latency separate from whole-cycle cost; averaging them would
      # hide the elapsed time across all repositories. Process population is tested below.
      detail =
        detail
        |> Map.put(:repo_poll, repo_poll_health())
        |> Map.put(:poll_cycle, poll_cycle_health())

      if rail_healthy?(detail),
        do: {:operational, detail},
        else: {:degraded, detail}
    else
      {:inactive, %{note: "step_dispatch? off"}}
    end
  end

  # Health maps/atoms are truthy; classify them rather than testing truthiness.
  defp rail_healthy?(detail), do: Enum.all?(detail, &key_healthy?/1)

  # Cycle coverage is independent of failure rate: a skipped repo can have no errors and no service.
  defp key_healthy?({:poll_cycle, health}),
    do: polls_healthy?(health) and serving?(health)

  defp key_healthy?({:repo_poll, health}), do: polls_healthy?(health)

  defp key_healthy?({_key, up?}), do: up?

  @doc """
  False only when a cycle reports discovered repositories and zero served.
  Some unserved repos alongside served ones are allowed. Missing/unexpected shapes
  return true: unknown coverage is not interpreted as measured zero.
  """
  @spec serving?(term()) :: boolean()
  def serving?(%{last_repos: repos, last_served: 0}) when is_integer(repos) and repos > 0,
    do: false

  def serving?(_other), do: true

  @doc false
  # Public classifier for telemetry shapes. no_data/unavailable do not degrade by themselves;
  # the telemeter's process key catches its absence. Error totals may be an integer or
  # per-scope map. Unknown shapes remain healthy, not evidence of measured progress.
  @spec polls_healthy?(term()) :: boolean()
  def polls_healthy?(:no_data), do: true
  def polls_healthy?(:unavailable), do: true

  def polls_healthy?(%{errors: errors, window: window}),
    do: not blackout?(error_count(errors), window)

  def polls_healthy?(_other), do: true

  defp error_count(errors) when is_map(errors), do: errors |> Map.values() |> Enum.sum()
  defp error_count(errors) when is_integer(errors), do: errors
  defp error_count(_), do: 0

  defp blackout?(errors, window)
       when is_integer(window) and window >= @poll_blackout_window and errors >= window,
       do: true

  defp blackout?(_errors, _window), do: false

  # Catch telemetry call exits to keep readiness readable during instrument failure.
  defp repo_poll_health do
    Fleet.Pilot.PollerTelemetry.stats()
  catch
    :exit, _ -> :unavailable
  end

  defp poll_cycle_health do
    Fleet.Pilot.PollerTelemetry.cycle_stats()
  catch
    :exit, _ -> :unavailable
  end

  @doc false
  # Readiness's essential registered names; tests compare them with returned step child specs.
  @spec step_rail_processes() :: list()
  def step_rail_processes do
    [
      # Telemetry process absence is degradation even though a call timeout alone is tolerated.
      poller_telemetry: Fleet.Pilot.PollerTelemetry,
      poller: Fleet.Pilot.Poller,
      step_run_consumer: StepRunConsumer,
      step_run_task_supervisor: StepRunConsumer.task_supervisor(),
      incident_registry: Fleet.Pilot.IncidentRegistry,
      incident_consumer: IncidentConsumer,
      incident_task_supervisor: IncidentConsumer.task_supervisor(),
      worktree_sync: Fleet.Project.WorktreeSync,
      arch_feed: Fleet.Pilot.ArchFeed
    ]
  end

  # Disabled step mode yields no step children; enabled mode must validate required configuration.
  defp step_children do
    if Application.get_env(:lcars_fleet, :pilot_step_dispatch?, false) do
      step_children!()
    else
      []
    end
  end

  @doc false
  # Expose child specs and boot guards without registering singleton children.
  @spec step_children_for_test() :: list()
  def step_children_for_test, do: step_children()

  # Discovery and per-run remote resolution require a forge base URL, not one fixed repo.
  defp step_children! do
    unless forge_base_url() do
      raise "pilot: :pilot_step_dispatch? enabled but the forge base_url is absent (config :lcars_fleet, " <>
              ":forge[:base_url] / FORGE_BASE_URL) — the Poller cannot DISCOVER its projects " <>
              "(list_org_repos) nor can the StepRunConsumer derive the push remote. Deploy broken, fail-loud."
    end

    # Publish the workflow image before guards/consumers read it; subsequent disk edits
    # do not mutate that image. Publication can remain even if a later guard raises.
    Loader.publish_image!()

    validate_card_juries!()
    validate_card_steps!()
    validate_structural_roles!()
    require_signer_tokens!()
    validate_workshop_card!()
    validate_default_card_loads!()

    # Resolve ingest schemas at boot so a broken artifact fails before the first verdict.
    Fleet.Pilot.StepRunConsumer.Verdict.load_schema!()

    interval = Application.get_env(:lcars_fleet, :pilot_poll_interval_ms, 30_000)

    [
      # Attach before Poller emits its first event.
      Fleet.Pilot.PollerTelemetry,
      # Completion offload must exist before its consumer. Bound concurrent forge work;
      # saturation is handled by offload_async rather than blocking the singleton.
      {Task.Supervisor, name: StepRunConsumer.task_supervisor(), max_children: 16},
      # IncidentRegistry owns WAL and asynchronous forge synchronization/retry.
      Fleet.Pilot.IncidentRegistry,
      # Separate incident offload pool so a failure burst does not occupy completion workers.
      {Task.Supervisor, name: IncidentConsumer.task_supervisor(), max_children: 16},
      {IncidentConsumer, runner: &IncidentConsumer.offload_async/1},
      # Serialize per-worktree alignment after merge before starting either merge trigger.
      Fleet.Project.WorktreeSync,
      # Architect activity feed follows the step lifecycle.
      Fleet.Pilot.ArchFeed,
      # Repos are discovered/per-run. Webhooks accelerate polling; forge state remains authoritative.
      {Fleet.Pilot.Poller, interval_ms: interval, subscribe_gitea: true},
      {StepRunConsumer, forge_opts: [], step_run_runner: &StepRunConsumer.offload_async/2}
    ]
  end

  @doc """
  Publishes the workflow image and runs catalogue/structural-role guards for the
  standalone verifier. boot.verifier_covers_rail compares validate_*! coverage with
  step boot; the sequences are separate. Container signer checks and verdict-schema
  loading remain boot-only. Raises on invalid catalogue content; opts reach card guards.
  """

  @spec verify_cards_and_roles!(keyword()) :: :ok
  def verify_cards_and_roles!(opts \\ []) do
    Loader.publish_image!()
    validate_card_juries!(opts)
    validate_card_steps!(opts)
    validate_structural_roles!()
    validate_workshop_card!(opts)
    validate_default_card_loads!(opts)
    :ok
  end

  # Re-export guards to keep boot/verifier call lists visible to the AST contract and tests.
  @doc false
  @spec validate_card_juries!(keyword()) :: :ok
  defdelegate validate_card_juries!(opts \\ []), to: Fleet.Workflow.CatalogueGuards
  @doc false
  @spec validate_workshop_card!(keyword()) :: :ok
  defdelegate validate_workshop_card!(opts \\ []), to: Fleet.Workflow.CatalogueGuards
  @doc false
  @spec validate_default_card_loads!(keyword()) :: :ok
  defdelegate validate_default_card_loads!(opts \\ []), to: Fleet.Workflow.CatalogueGuards
  @doc false
  @spec validate_card_steps!(keyword()) :: :ok
  defdelegate validate_card_steps!(opts \\ []), to: Fleet.Workflow.CatalogueGuards
  @doc false
  @spec validate_structural_roles!() :: :ok
  defdelegate validate_structural_roles!(), to: Fleet.Project.Roles

  # Container signer checks are require_*, not tokenless catalogue validate_* guards.
  # Probe the seal's credentials path, then distinguish named fatal provisioning causes.
  # Other returned causes are logged and allowed to boot; this is an allow-by-cause policy,
  # not proof that every unlisted cause is transient.
  @signer_causes_fatales [:no_role_token, :no_forge_login, :bad_role, :not_a_worker]

  defp require_signer_tokens! do
    for role <- [
          Fleet.Project.Roles.gatekeeper_role(),
          Fleet.Project.Roles.conflict_resolver_role()
        ] do
      # Use the seal's own credential resolution; request detailed cause only after its refusal.
      if match?({:error, :role_token_unavailable}, Fleet.Forge.Client.as_role([], role)) do
        signer_verdict!(role, Fleet.Credentials.RoleIdentity.token_cause(role))
      end
    end

    :ok
  end

  defp signer_verdict!(role, {:ok, _token}) do
    # The token became available between the two reads; continue with a warning.
    Logger.warning(
      "pilot: le jeton du signataire #{inspect(role)} etait indisponible puis disponible entre " <>
        "deux appels — le service d'autorite finissait de demarrer. Boot poursuivi."
    )

    :ok
  end

  defp signer_verdict!(role, {:error, cause}) when cause in @signer_causes_fatales do
    raise "pilot: no role token for merge signer #{inspect(role)} (#{inspect(cause)}) — the seal " <>
            "signs merges fail-closed as this role and would refuse every merge on its path. " <>
            "Provision the token (runtime/services/provision-role-tokens.sh) before booting the rail."
  end

  defp signer_verdict!(role, {:error, cause}) do
    Logger.error(
      "pilot: le jeton du signataire #{inspect(role)} est INDISPONIBLE (#{inspect(cause)}) — ce " <>
        "n'est PAS un defaut de provisionnement, c'est une porte qui ne repond pas : le service " <>
        "d'autorite ou la forge. Le rail demarre parce que la cause est transitoire et que les " <>
        "merges reessaient, mais TOUT SCELLEMENT ECHOUERA tant qu'elle dure. " <>
        "« systemctl status lcars-catalogue », puis la joignabilite de la forge."
    )

    :ok
  end

  # Reads :pilot_forge, despite the legacy error text naming :forge.
  defp forge_base_url do
    case Keyword.get(Application.get_env(:lcars_fleet, :pilot_forge, []), :base_url) do
      base when is_binary(base) and base != "" -> base
      _ -> nil
    end
  end
end
