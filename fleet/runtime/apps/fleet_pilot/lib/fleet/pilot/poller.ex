defmodule Fleet.Pilot.Poller do
  @moduledoc """
  Réacteur du rail forge-state-machine (**mode STAGE uniquement**) : scan périodique du `repo`
  configuré, délégation des issues + PR ouvertes au spawn des rôles via `StageDispatcher`.

  ## Rôle

  La forge EST la machine à états ; ce poller en est le réacteur. À chaque tick, pour le `repo`
  surveillé, il liste les **issues** + **PR** ouvertes et délègue :

    * **issue assignée** (assignee=humain owner), non verrouillée, sans PR ouverte → spawn le rôle
      **producteur** (`StageDispatcher.dispatch_issue` ; rôle = `:producer_role`, défaut engineer).
    * **PR** avec reviewer demandé → spawn le **juge** ; PR `REQUEST_CHANGES` sans reviewer → re-spawn
      le **producteur** pour le rework (`StageDispatcher.dispatch_review`).
    * verrou `lcars-in-flight` → skip (un pod travaille déjà la brique). **Bail repo-sérialisé** :
      au plus un pipeline actif par repo (feature-branches séquentielles → merge FF garanti).

  ## Robustesse (port v1.5 `LcarsFleetPoller`, conservé)

    * **Jitter ±10%** sur l'interval — anti thundering-herd (N daemons qui redémarrent ensemble).
    * **Backoff exponentiel** sur erreurs API (capé à 5 min) — la forge down n'inonde pas les logs.
    * **Safety-net `try/rescue`** sur `do_poll/1` — un bug du path dispatch ne crash pas le poller.
    * **Telemetry** `[:fleet_pilot, :poller, :poll]` (duration_ms, dispatched, skipped, errors).

  ## Configuration init

    * `:repo` — `"owner/name"`, obligatoire.
    * `:interval_ms` — défaut `30_000` (30s).
    * `:forge_opts` — keyword ForgeClient (base_url, token, req_options).
    * `:routing` — map `type:X → carte` pour l'`Entry` legacy (transitionnel, FALL).
    * `:stage_dispatch?` — historiquement le switch de mode ; aujourd'hui toujours `true` (seul mode).
    * seams test : `:forge_client`, `:loader`, `:carte_loader`, `:spawner`, `:clock` (injectés si non-nil).
    * `:start_tick?` — défaut `true` ; `false` = pas de 1er tick auto (tests drivent via `force_poll/1`).

  ## Historique — mode legacy RETIRÉ (②.3 / BL-050, 2026-06-16)

  L'ancien mode `do_poll` legacy (route-table `Routing.match_issue` → `Dispatcher.dispatch` →
  `Fleet.Pipeline.start_pipeline` = Executor RAM, via l'état de l'`AutoDispatcher`) a été **supprimé**
  avec le rail legacy (`auto_dispatcher`/`dispatcher`/`pipeline_invoker`). Seul le mode stage subsiste ;
  le moteur RAM tombe en aval.
  """

  use GenServer
  require Logger

  alias Fleet.Pilot.{StageDispatcher, Entry}

  @default_interval_ms 30_000
  @max_backoff_ms 300_000
  @jitter_ratio 0.1

  defstruct [
    :repo,
    :interval_ms,
    :forge_client_override,
    stage_dispatch?: false,
    forge_opts: [],
    routing: %{},
    loader: nil,
    carte_loader: nil,
    spawner: nil,
    clock: nil,
    poll_count: 0,
    error_count: 0,
    err_streak: 0,
    last_error: nil
  ]

  @type t :: %__MODULE__{
          repo: String.t(),
          interval_ms: pos_integer(),
          forge_client_override: module() | nil,
          stage_dispatch?: boolean(),
          forge_opts: keyword(),
          loader: module() | nil,
          spawner: module() | nil,
          clock: (atom() -> integer()) | nil,
          poll_count: non_neg_integer(),
          error_count: non_neg_integer(),
          err_streak: non_neg_integer(),
          last_error: term() | nil
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

  @doc "Force un poll immédiat (synchrone). Utilisé par tests + ops."
  @spec force_poll(GenServer.server()) :: %{
          dispatched: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer()
        }
  def force_poll(server \\ __MODULE__), do: GenServer.call(server, :force_poll, 30_000)

  @doc "Stats runtime : poll_count, error_count, err_streak, last_error."
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(opts) do
    case Keyword.fetch(opts, :repo) do
      {:ok, repo} when is_binary(repo) and repo != "" ->
        state = %__MODULE__{
          repo: repo,
          interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
          forge_client_override: Keyword.get(opts, :forge_client),
          stage_dispatch?: Keyword.get(opts, :stage_dispatch?, false),
          forge_opts: Keyword.get(opts, :forge_opts, []),
          routing: Keyword.get(opts, :routing, %{}),
          loader: Keyword.get(opts, :loader),
          carte_loader: Keyword.get(opts, :carte_loader),
          spawner: Keyword.get(opts, :spawner),
          clock: Keyword.get(opts, :clock)
        }

        if Keyword.get(opts, :start_tick?, true) do
          schedule(jitter(state.interval_ms))
        end

        Logger.info(
          "fleet_pilot Poller start repo=#{repo} mode=stage " <>
            "interval=#{state.interval_ms}ms jitter=±10%"
        )

        {:ok, state}

      _ ->
        {:stop, {:missing_required_opt, :repo}}
    end
  end

  @impl GenServer
  def handle_info(:poll, state) do
    {_result, new_state} = safe_poll(state)
    schedule(next_delay(new_state))
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_call(:force_poll, _from, state) do
    {result, new_state} = safe_poll(state)
    {:reply, result, new_state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       poll_count: state.poll_count,
       error_count: state.error_count,
       err_streak: state.err_streak,
       last_error: state.last_error
     }, state}
  end

  # ============================================================
  # Internals — scheduling / safety
  # ============================================================

  defp schedule(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :poll, interval_ms)
  end

  defp next_delay(%__MODULE__{err_streak: 0, interval_ms: base}), do: jitter(base)

  defp next_delay(%__MODULE__{err_streak: streak, interval_ms: base}) do
    factor = :math.pow(2, min(streak, 10)) |> trunc()
    delay = min(base * factor, @max_backoff_ms)
    jitter(delay)
  end

  defp jitter(ms) do
    delta = trunc(ms * @jitter_ratio)
    offset = :rand.uniform(2 * delta + 1) - delta - 1
    max(ms + offset, 1_000)
  end

  # Retourne `{result, new_state}` — rescue-wrappé. Partagé par le tick (qui jette le
  # result) ET force_poll (qui le renvoie) : F184, force_poll ne bypasse plus le rescue.
  defp safe_poll(state) do
    do_poll(state)
  rescue
    exception ->
      Logger.error(
        "fleet_pilot Poller unexpected crash in do_poll: #{inspect(exception)} — state preserved"
      )

      {%{dispatched: 0, skipped: 0, errors: 1},
       %{
         state
         | error_count: state.error_count + 1,
           err_streak: state.err_streak + 1,
           last_error: inspect(exception)
       }}
  end

  # ============================================================
  # Internals — GenServer poll orchestration
  # ============================================================

  # Mode STAGE uniquement (le legacy `do_poll`/Executor RAM a été retiré, ②.3). Le scan est dans
  # `stage_do_poll/1` ; ce wrapper conserve le point d'entrée unique (jitter/backoff/safety-net partagés).
  defp do_poll(state), do: stage_do_poll(state)

  defp handle_poll_error(state, reason, started, _err) do
    new_streak = state.err_streak + 1

    Logger.warning(
      "fleet_pilot Poller error repo=#{state.repo} reason=#{inspect(reason)} streak=#{new_streak}"
    )

    :telemetry.execute(
      [:fleet_pilot, :poller, :poll],
      %{duration_ms: elapsed_ms(started)},
      %{
        status: :error,
        repo: state.repo,
        error: inspect(reason),
        err_streak: new_streak
      }
    )

    {%{dispatched: 0, skipped: 0, errors: 1},
     %{
       state
       | error_count: state.error_count + 1,
         err_streak: new_streak,
         last_error: inspect(reason)
     }}
  end

  defp wrap_issue_as_payload(issue, repo) do
    %{
      "issue" => issue,
      "repository" => %{"full_name" => repo}
    }
  end

  # ============================================================
  # Mode STAGE — réacteur assignee-driven (DN forge-state-machine §3/§6)
  # Découplé du legacy AutoDispatcher : pas de routes, pas d'Executor.
  # ============================================================

  defp stage_do_poll(state) do
    started = System.monotonic_time()
    forge = stage_forge_client(state)

    # Bail repo-serialise : on liste TOUS les ouverts (in-flight inclus) pour compter les
    # pipelines actifs. Corr.3 4-C : on liste AUSSI les PR ouvertes -> les JUGES sont dispatches
    # via les requested_reviewers de la PR (plus l'assignee issue). decide skip les in-flight.
    with {:ok, issues} <- forge.list_open_issues(state.repo, state.forge_opts),
         {:ok, pulls} <- forge.list_open_pulls(state.repo, state.forge_opts) do
      pr_issue_ids = pulls_issue_ids(pulls)

      tally =
        merge_tally(
          stage_process_issues(issues, pr_issue_ids, state),
          stage_process_pulls(pulls, state)
        )

      duration_ms = elapsed_ms(started)

      :telemetry.execute(
        [:fleet_pilot, :poller, :poll],
        %{duration_ms: duration_ms},
        Map.merge(tally, %{status: :ok, mode: :stage, repo: state.repo})
      )

      Logger.info(
        "fleet_pilot Poller tick mode=stage repo=#{state.repo} " <>
          "dispatched=#{tally.dispatched} skipped=#{tally.skipped} errors=#{tally.errors} " <>
          "duration_ms=#{duration_ms}"
      )

      {tally, %{state | poll_count: state.poll_count + 1, err_streak: 0, last_error: nil}}
    else
      {:error, reason} = err ->
        handle_poll_error(state, reason, started, err)
    end
  end

  # Issues portant une PR fleet ouverte (`lcars/issue-N-role`) = pipelines en phase JUGE :
  # le producteur a fini, la suite est dispatchee via les pulls -> le chemin issue les SKIP
  # (sinon le poller re-spawnerait le producteur, encore assigne).
  defp pulls_issue_ids(pulls) do
    pulls
    |> Enum.flat_map(fn pr ->
      case Fleet.Pilot.ForgeClient.parse_feature_branch(get_in(pr, ["head", "ref"]) || "") do
        {:ok, {n, _role}} -> [n]
        :error -> []
      end
    end)
    |> MapSet.new()
  end

  defp merge_tally(a, b) do
    %{
      dispatched: a.dispatched + b.dispatched,
      skipped: a.skipped + b.skipped,
      errors: a.errors + b.errors
    }
  end

  # Chemin PR-driven (Corr.3 4-C) : chaque PR ouverte avec une review demandee -> dispatch le juge.
  # Non garde par le bail (les juges d'un pipeline DEJA actif doivent avancer ; le bail ne borne
  # que l'ENTREE de nouveaux pipelines, cote issues).
  defp stage_process_pulls(pulls, state) do
    opts = stage_dispatch_opts(state)

    Enum.reduce(pulls, %{dispatched: 0, skipped: 0, errors: 0}, fn pr, acc ->
      case StageDispatcher.dispatch_review(pr, opts) do
        # ②.1d : `:ok` couvre `{:spawned, _, _}` (juge/rework spawné) ET `{:merged, _}` (PR scellée).
        {:ok, _} -> %{acc | dispatched: acc.dispatched + 1}
        {:skipped, _reason} -> %{acc | skipped: acc.skipped + 1}
        {:error, _reason} -> %{acc | errors: acc.errors + 1}
      end
    end)
  end

  defp stage_process_issues(issues, pr_issue_ids, state) do
    opts = stage_dispatch_opts(state)
    entry_opts = stage_entry_opts(state)

    # Bail repo-serialise (incrément 3) : au plus 1 pipeline actif par repo. Un ticket deja
    # engage (assigne a un role, in-flight ou entre deux hops) tient le bail -> aucun ticket
    # NEUF n'entre tant qu'il n'est pas fini (merge -> close). Les feature-branches sont donc
    # creees sequentiellement (chacune descend du main a jour) -> merge FF garanti. Le dispatch
    # des hops du ticket en cours n'est PAS bloque (seule l'entree d'un neuf l'est). Parallele-
    # disjoint (1 pipeline/repo distinct) = optimisation differee.
    lease_held0 = Enum.any?(issues, &repo_lease_held?/1)

    {tally, _lease} =
      Enum.reduce(issues, {%{dispatched: 0, skipped: 0, errors: 0}, lease_held0}, fn issue,
                                                                                     {acc, lease} ->
        payload = wrap_issue_as_payload(issue, state.repo)

        cond do
          # Corr.3 4-C : l'issue porte une PR fleet ouverte -> phase JUGE (le producteur a fini,
          # dispatchee via les pulls). SKIP cote issue, sinon le poller re-spawnerait le producteur
          # (encore assigne). L'issue garde son assignee => le bail repo reste tenu (via les pulls).
          MapSet.member?(pr_issue_ids, Map.get(issue, "number")) ->
            {%{acc | skipped: acc.skipped + 1}, lease}

          true ->
            stage_dispatch_one(payload, opts, entry_opts, acc, lease)
        end
      end)

    tally
  end

  defp stage_dispatch_one(payload, opts, entry_opts, acc, lease) do
    case StageDispatcher.dispatch_issue(payload, opts) do
      {:ok, {:spawned, _pod_id, _role}} ->
        {%{acc | dispatched: acc.dispatched + 1}, lease}

      # Pas d'assignee : peut-etre un ticket NEUF a ENTRER dans une carte (type:->carte, A2.1).
      # Entry est idempotent (deja route -> skip). L'entree n'est permise QUE si le bail repo est
      # libre (sinon le neuf attend le prochain tick, apres la fin du pipeline en cours).
      {:skipped, :no_assignee} ->
        stage_try_enter(payload, entry_opts, acc, lease)

      {:skipped, _reason} ->
        {%{acc | skipped: acc.skipped + 1}, lease}

      {:error, _reason} ->
        {%{acc | errors: acc.errors + 1}, lease}
    end
  end

  # Entree d'un ticket neuf, gardee par le bail repo. Bail tenu -> skip (:repo_leased, le neuf
  # attend). Bail libre -> Entry ; une entree reussie PREND le bail (les neufs suivants du meme
  # tick attendent).
  defp stage_try_enter(_payload, _entry_opts, acc, true),
    do: {%{acc | skipped: acc.skipped + 1}, true}

  defp stage_try_enter(payload, entry_opts, acc, false) do
    case Entry.enter(payload, entry_opts) do
      {:ok, {:entered, _role}} -> {%{acc | dispatched: acc.dispatched + 1}, true}
      {:skip, _} -> {%{acc | skipped: acc.skipped + 1}, false}
      {:error, _} -> {%{acc | errors: acc.errors + 1}, false}
    end
  end

  # Un ticket "tient le bail repo" s'il est deja engage dans un pipeline = assigne a un role
  # (in-flight ou entre deux hops : les deux portent un assignee ; un ticket neuf type:X non).
  defp repo_lease_held?(issue) do
    (Map.get(issue, "assignees") || []) != []
  end

  defp stage_entry_opts(state) do
    [
      repo: state.repo,
      routing: state.routing,
      forge_client: stage_forge_client(state),
      forge_opts: state.forge_opts
    ]
    # `:carte_loader` (Loader de pipeline, load!/1) ≠ `:loader` de StageDispatcher (CapProfile,
    # load/1). Entry navigue la carte → il lui faut le loader de carte, pas celui des cap-profiles.
    |> maybe_put_seam(:loader, state.carte_loader)
  end

  # Construit les opts de StageDispatcher.dispatch_issue. Les seams
  # (loader/spawner/clock) ne sont injectés QUE s'ils sont set sur le
  # state — sinon StageDispatcher applique ses défauts réels (passer nil
  # écraserait le défaut).
  defp stage_dispatch_opts(state) do
    [
      repo: state.repo,
      forge_client: stage_forge_client(state),
      forge_opts: state.forge_opts
    ]
    |> maybe_put_seam(:loader, state.loader)
    |> maybe_put_seam(:spawner, state.spawner)
    |> maybe_put_seam(:clock, state.clock)
  end

  defp maybe_put_seam(opts, _key, nil), do: opts
  defp maybe_put_seam(opts, key, value), do: Keyword.put(opts, key, value)

  defp stage_forge_client(%__MODULE__{forge_client_override: nil}), do: Fleet.Pilot.ForgeClient
  defp stage_forge_client(%__MODULE__{forge_client_override: fc}), do: fc

  defp elapsed_ms(started_native) do
    System.convert_time_unit(
      System.monotonic_time() - started_native,
      :native,
      :millisecond
    )
  end
end
