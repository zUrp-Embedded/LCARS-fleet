defmodule Fleet.Pilot.AutoDispatcher do
  @moduledoc """
  GenServer subscribe Bus `fleet.events`, filtre `gitea.*`, route via
  `Fleet.Pilot.Routing`, lock idempotent via
  `Fleet.Pilot.ForgeClient.add_label/4` (`lcars-dispatched`), invoke
  pipeline via `Fleet.Pilot.PipelineInvoker`.

  ## Serial by design

  Le GenServer sérialise les events → pas de race entre 2 events sur le
  même ticket (lock via label OK). Multi-node : la race revient ; cf.
  brique 2 poller reconciliateur (label = source de vérité, poller
  catch-up post-crash respecte le label).

  ## Tolérance aux pannes

  Chaque event est traité en `try/rescue` → un payload malformé ne
  crash pas le dispatcher (logged, ignored). Le supervisor `one_for_one`
  redémarre le GenServer ; les events Bus non encore consommés sont
  perdus (Phoenix.PubSub : pas de persistance) — c'est exactement ce
  que la brique 2 (poller) doit catch-up.

  ## Configuration init

    * `:dispatch_label` — default `"lcars-dispatched"`
    * `:forge_opts` — Keyword passé tel quel à `ForgeClient.add_label/4`
      (`base_url`, `token`/`token_file`, `req_options`)
    * `:forge_client` — module impl (défaut `Fleet.Pilot.ForgeClient`,
      injection test)
    * `:invoker` — module impl (défaut `PipelineInvoker.Default`,
      injection test)
    * `:routes_path` — override path catalogue (défaut résolu via
      `Application.get_env(:fleet_pilot, :forge_routing_path)`)
    * `:subscribe?` — bool, défaut `true`. `false` = n'appelle pas
      `Bus.subscribe/0` à l'init (utilisé par tests qui injectent
      directement via `handle_info`).
  """

  use GenServer
  require Logger

  alias Fleet.Pilot.Routing
  alias Fleet.EventRouter.Bus

  @default_dispatch_label "lcars-dispatched"
  @gitea_prefix "gitea."

  defstruct [
    :routes,
    :dispatch_label,
    :forge_opts,
    :forge_client,
    :invoker
  ]

  @type t :: %__MODULE__{
          routes: [map()],
          dispatch_label: String.t(),
          forge_opts: keyword(),
          forge_client: module(),
          invoker: module()
        }

  # ============================================================
  # Public API
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc """
  Recharge le catalogue `forge-routing.yaml`. Utilisé après édition
  fichier sans redémarrer le service.
  """
  @spec reload_routes(GenServer.server()) :: :ok
  def reload_routes(server \\ __MODULE__), do: GenServer.call(server, :reload_routes)

  @doc """
  Inspect state (debug). Retourne le nombre de routes chargées.
  """
  @spec stats(GenServer.server()) :: %{routes_count: non_neg_integer()}
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(opts) do
    routes_path = Keyword.get(opts, :routes_path)
    routes = if routes_path, do: Routing.load_routes(routes_path), else: Routing.load_routes()

    state = %__MODULE__{
      routes: routes,
      dispatch_label: Keyword.get(opts, :dispatch_label, @default_dispatch_label),
      forge_opts: Keyword.get(opts, :forge_opts, []),
      forge_client: Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient),
      invoker: Keyword.get(opts, :invoker, Fleet.Pilot.PipelineInvoker.Default)
    }

    if Keyword.get(opts, :subscribe?, true) do
      {:ok, state, {:continue, :subscribe}}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_continue(:subscribe, state) do
    case Bus.subscribe() do
      :ok ->
        Logger.info(
          "fleet_pilot AutoDispatcher subscribed to Bus, routes=#{length(state.routes)}"
        )

        {:noreply, state}

      {:error, reason} ->
        Logger.error("fleet_pilot AutoDispatcher Bus.subscribe failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def handle_call(:reload_routes, _from, state) do
    routes = Routing.load_routes()
    Logger.info("fleet_pilot AutoDispatcher reloaded routes=#{length(routes)}")
    {:reply, :ok, %{state | routes: routes}}
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{routes_count: length(state.routes)}, state}
  end

  # Exposé pour Fleet.Pilot.Poller qui partage la même config runtime
  # (routes, forge_opts, modules injectés). Évite la duplication de
  # configuration entre les 2 GenServers.
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl GenServer
  def handle_info({_event_atom, event}, state) when is_map(event) do
    safe_process(event, state)
    {:noreply, state}
  end

  def handle_info(event, state) when is_map(event) do
    safe_process(event, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================
  # Dispatch logic (testable directly)
  # ============================================================

  @doc """
  Traite un event Bus. Retourne `{:dispatched, pipeline_id}`,
  `{:skipped, reason}` ou `{:error, reason}`. Expose pour tests.

  Chaîne : fetch event_type → ensure `gitea.*` → Routing.match_event
  (event_type + when-clauses) → extract repo/issue_number →
  délègue à `Fleet.Pilot.Dispatcher.dispatch/5` (lock + invoke).
  """
  @spec process_event(map(), t()) ::
          {:dispatched, String.t()}
          | {:skipped, atom()}
          | {:error, term()}
  def process_event(event, %__MODULE__{} = state) do
    with {:ok, event_type} <- fetch_event_type(event),
         :ok <- ensure_gitea_event(event_type),
         payload = Map.get(event, "payload", %{}),
         {:match, pipeline_name} <- Routing.match_event(event_type, payload, state.routes),
         {:ok, repo} <- extract_repo(payload),
         {:ok, issue_number} <- extract_issue_number(payload) do
      Fleet.Pilot.Dispatcher.dispatch(
        dispatcher_config(state),
        pipeline_name,
        repo,
        issue_number,
        payload
      )
    else
      :no_match -> {:skipped, :no_route}
      {:skipped, _} = s -> s
      {:error, _} = e -> e
    end
  end

  @doc """
  Projette l'état AutoDispatcher en config Dispatcher (utilisée aussi
  par Poller pour partager la même configuration runtime).
  """
  @spec dispatcher_config(t()) :: Fleet.Pilot.Dispatcher.config()
  def dispatcher_config(%__MODULE__{} = state) do
    %{
      dispatch_label: state.dispatch_label,
      forge_opts: state.forge_opts,
      forge_client: state.forge_client,
      invoker: state.invoker
    }
  end

  # ============================================================
  # Internals
  # ============================================================

  defp safe_process(event, state) do
    process_event(event, state)
  rescue
    exception ->
      Logger.error(
        "fleet_pilot AutoDispatcher crash on event: #{inspect(exception)} event=#{inspect(event, limit: 5)}"
      )

      {:error, {:exception, exception}}
  end

  defp fetch_event_type(event) do
    case Map.get(event, "event_type") do
      type when is_binary(type) -> {:ok, type}
      _ -> {:error, :missing_event_type}
    end
  end

  defp ensure_gitea_event(event_type) do
    if String.starts_with?(event_type, @gitea_prefix),
      do: :ok,
      else: {:skipped, :not_gitea_event}
  end

  defp extract_repo(payload) do
    case get_in(payload, ["repository", "full_name"]) do
      repo when is_binary(repo) and repo != "" -> {:ok, repo}
      _ -> {:error, :missing_repo}
    end
  end

  defp extract_issue_number(payload) do
    case get_in(payload, ["issue", "number"]) do
      n when is_integer(n) -> {:ok, n}
      _ -> {:error, :missing_issue_number}
    end
  end
end
