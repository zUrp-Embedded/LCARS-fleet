defmodule Fleet.Pilot.HopConsumer do
  @moduledoc """
  Consumer Bus de la **fin-de-hop** (DN `orchestration/forge-state-machine.md`).
  Subscribe `Fleet.EventRouter.Bus` (topic `fleet.events`) ; sur chaque
  `%Fleet.Event{source: :spawner, type: :"pod.completed"}` d'un pod
  **stage-dispatch** (assignee-driven), traduit l'event en `hop` et délègue la
  séquence §5 à `Fleet.Pilot.HopCompleter`.

  ## Pourquoi un consumer séparé de l'Executor

  Deux stacks cohabitent (dual-run, le temps que l'Executor RAM soit retiré) :

    * **Pipeline pods** — payload porte `pipeline_id` → l'`Executor` les corrèle
      à leur stage. **Ce consumer les IGNORE** (`pipeline_id` présent → skip).
    * **Stage-dispatch pods** — pas de `pipeline_id`, mais (s'ils portent un
      projet) le payload embarque `workspace` + `base_sha` + `role` (enrichi à la
      source, `Fleet.Spawner.Pod.pod_completed_payload`). **Ce consumer les
      traite.** L'event porte tout l'état → consumer stateless, pas de query
      `pod_info` racy (le pod termine juste après l'event).

  ## Traduction event → hop

    * `issue_number` ← `ticket_id` (`"issue-N"` → `N`)
    * `repo` ← config `:repo`
    * `deliverable_opts` ← `{mode: :git_native, workspace, base_sha,
      allowed_emails(role), remote, target_branch}` ; le SYSTÈME pousse
      (barrière §4, F-04) sur une branche système `lcars/issue-N-role`
      (merge-vers-main = BL-044/A2, pas ici).
    * `next_assignee: nil` → **1-stage terminal** (close). Le multi-stage
      (lookup du suivant dans la carte) = **A2**.

  ## Config / seams

    * `:repo` — `"owner/name"` (obligatoire)
    * `:remote` — URL/nom du remote où le système pousse (obligatoire)
    * `:forge_opts` — passé au ForgeClient via HopCompleter
    * `:role_emails` — `fn role -> [email] end` (défaut `"<role>@lcars.local"`),
      doit matcher l'identité git injectée au pod (gate F-01)
    * `:hop_completer` — seam (défaut `Fleet.Pilot.HopCompleter`)
    * `:subscribe` — bool défaut `true` (tests : `false` + envoi manuel)
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  defstruct [
    :repo,
    :remote,
    :forge_opts,
    :role_emails,
    :hop_completer,
    :forge_client,
    :loader,
    :deliverable,
    :max_rework_rounds
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    with {:ok, repo} <- require_opt(opts, :repo),
         {:ok, remote} <- require_opt(opts, :remote) do
      if Keyword.get(opts, :subscribe, true), do: Bus.subscribe()

      state = %__MODULE__{
        repo: repo,
        remote: remote,
        forge_opts: Keyword.get(opts, :forge_opts, []),
        role_emails: Keyword.get(opts, :role_emails, &default_role_emails/1),
        hop_completer: Keyword.get(opts, :hop_completer, Fleet.Pilot.HopCompleter),
        # nil → HopCompleter applique son défaut (Fleet.Pilot.ForgeClient). Injectable
        # pour un backend forge alternatif (ou un sim en dogfood bare).
        forge_client: Keyword.get(opts, :forge_client),
        # Loader de carte (A2 multi-stage) : résout le stage suivant. Défaut = Loader réel.
        loader: Keyword.get(opts, :loader, Fleet.Pipeline.Loader),
        # nil → HopCompleter applique son défaut (Fleet.Pipeline.Deliverable). Injectable (sim/test).
        deliverable: Keyword.get(opts, :deliverable),
        # A2.3 : bound anti-runaway du rebond de gate. Budget de hops = nb_stages *
        # (max_rework_rounds + 1) : la 1re passe + N rounds de rework. Au-delà → stuck
        # surfacé (pas de boucle). Défaut 2 rounds.
        max_rework_rounds: Keyword.get(opts, :max_rework_rounds, 2)
      }

      Logger.info("fleet_pilot HopConsumer start repo=#{repo} remote=#{remote}")
      {:ok, state}
    else
      {:error, missing} -> {:stop, {:missing_required_opt, missing}}
    end
  end

  @impl GenServer
  def handle_info(%Fleet.Event{source: :spawner, type: :"pod.completed", payload: p}, state) do
    case maybe_complete(p, state) do
      {:ok, outcome} ->
        Logger.info("HopConsumer: #{p["ticket_id"]} → #{inspect(outcome)}")

      {:skip, reason} ->
        Logger.debug("HopConsumer skip #{p["ticket_id"]} (#{reason})")

      {:error, reason} ->
        Logger.warning("HopConsumer fin-de-hop FAIL #{p["ticket_id"]}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info(%Fleet.Event{}, state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  # ============================================================
  # Traduction event → hop (pure sauf l'appel HopCompleter)
  # ============================================================

  @doc false
  # Exposé pour test : décide skip/complete sans passer par le GenServer.
  def maybe_complete(payload, state) do
    cond do
      Map.has_key?(payload, "pipeline_id") ->
        {:skip, :pipeline_pod}

      not project_payload?(payload) ->
        {:skip, :no_project}

      true ->
        case parse_issue_number(payload["ticket_id"]) do
          {:ok, n} -> run_hop(payload, n, state)
          :error -> {:skip, {:bad_ticket_id, payload["ticket_id"]}}
        end
    end
  end

  defp run_hop(payload, n, state) do
    role = payload["role"]

    # A2 : si le payload porte le contexte carte (pipeline+stage), le stage suivant
    # est calculé par CarteNav (reassign vers le rôle suivant, ou close si terminal).
    # Sans contexte carte (A1 1-stage) → next_assignee nil → close. Une erreur de carte
    # (DAG, stage inconnu) NE misroute PAS : elle remonte (le système n'avance pas à l'aveugle).
    case resolve_next(payload, n, state) do
      {:error, reason} ->
        {:error, reason}

      {:ok, {next_assignee, next_stage}} ->
        hop = %{
          repo: state.repo,
          issue_number: n,
          role: role,
          deliverable_opts: %{
            mode: :git_native,
            workspace: payload["workspace"],
            base_sha: payload["base_sha"],
            allowed_emails: state.role_emails.(role),
            remote: state.remote,
            target_branch: "lcars/issue-#{n}-#{role}",
            push?: true,
            local_ref: "HEAD"
          },
          next_assignee: next_assignee,
          # A2.1 : pipeline + stage suivant → HopCompleter grave la route avant le reassign.
          # nil/nil pour terminal ou 1-stage (pas de route, close).
          next_stage: next_stage,
          pipeline: payload["pipeline"],
          state_label: "state:delivered"
        }

        hc_opts =
          [forge_opts: state.forge_opts]
          |> maybe_put(:forge_client, state.forge_client)
          |> maybe_put(:deliverable, state.deliverable)

        state.hop_completer.complete(hop, hc_opts)
    end
  end

  # Résout le prochain assignee depuis la carte (A2.4). Le contexte carte arrive dans le
  # payload `pod.completed` : `pipeline` (nom de carte) + `stage` (nom du stage courant —
  # le NOM, pas le rôle, cf. CarteNav wrinkle DN §8). Absent → 1-stage terminal (A1).
  defp resolve_next(payload, n, state) do
    case {payload["pipeline"], payload["stage"]} do
      {pipeline, stage} when is_binary(pipeline) and is_binary(stage) ->
        with {:ok, carte} <- load_carte(state, pipeline) do
          gate_decide(carte, stage, payload, n, state)
        end

      _ ->
        # pas de contexte carte → pod 1-stage (A1) → terminal close
        {:ok, {nil, nil}}
    end
  end

  # A2.3 — la gate du stage FINI décide AVANT d'avancer (DN forge-state-machine §9).
  # `Gates.evaluate/3` est PUR (gate nil/absente → :pass) ; on lui passe la spec du
  # stage qui vient de finir + le `result` du pod (outputs → prédicats hard).
  #
  #   :pass                     → avance dans la carte (next_stage)
  #   {:fail, _}                → REBOND vers le 1er stage (rework), BORNÉ (anti-runaway,
  #                               I-CBC : une boucle de rework infinie ne doit pas être
  #                               représentable).
  #   {:dispatch_gatekeeper, i} → jugement async — A2.3b, pas encore câblé → différé
  #                               explicite {:error, {:gate_pending, i}} (pas d'avance à l'aveugle).
  defp gate_decide(carte, stage, payload, n, state) do
    spec =
      case Fleet.Pilot.CarteNav.stage_spec(carte, stage) do
        {:ok, s} -> s
        # stage inconnu : pas de gate → next_stage tranchera ({:error,:unknown_stage}),
        # pas de misroute silencieux.
        :error -> %{}
      end

    case Fleet.Pipeline.Gates.evaluate(spec, payload["result"] || %{}, %{}) do
      :pass ->
        advance(carte, stage)

      {:fail, reason} ->
        Logger.info("HopConsumer gate FAIL repo=#{state.repo}##{n} stage=#{stage}: #{reason}")
        rebound(carte, n, state)

      {:dispatch_gatekeeper, info} ->
        {:error, {:gate_pending, info}}
    end
  end

  defp advance(carte, stage) do
    case Fleet.Pilot.CarteNav.next_stage(carte, stage) do
      {:ok, {next_stage, next_role}} -> {:ok, {next_role, next_stage}}
      :terminal -> {:ok, {nil, nil}}
      {:error, reason} -> {:error, {:carte_nav, reason}}
    end
  end

  # Rebond borné. Budget = nb_stages * (max_rework_rounds + 1) hops signés. Le compteur
  # forge-natif = les comments `[hop:role:sha]` déjà postés (monotone). Lu UNIQUEMENT ici
  # (branche fail) → zéro I/O sur le happy path. Budget illisible → on NE rebondit PAS à
  # l'aveugle (un rebond non vérifiable pourrait boucler) : on surface.
  defp rebound(carte, n, state) do
    budget = stage_count(carte) * (state.max_rework_rounds + 1)

    case count_hops(state, n) do
      {:ok, hops} when hops >= budget ->
        {:error, {:rework_exhausted, %{hops: hops, budget: budget}}}

      {:ok, _hops} ->
        case Fleet.Pilot.CarteNav.first_stage(carte) do
          {:ok, {first_stage, first_role}} -> {:ok, {first_role, first_stage}}
          {:error, reason} -> {:error, {:carte_nav, reason}}
        end

      {:error, reason} ->
        {:error, {:rework_budget_unreadable, reason}}
    end
  end

  defp stage_count(carte), do: carte |> Map.get("stages", %{}) |> map_size()

  defp count_hops(state, n) do
    forge = state.forge_client || Fleet.Pilot.ForgeClient
    forge.count_signed_hops(state.repo, n, state.forge_opts)
  end

  defp load_carte(state, pipeline) do
    {:ok, state.loader.load!(pipeline)}
  rescue
    e -> {:error, {:carte_load, Exception.message(e)}}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp project_payload?(p) do
    is_binary(p["workspace"]) and is_binary(p["base_sha"]) and p["base_sha"] != "" and
      is_binary(p["role"])
  end

  @doc false
  def parse_issue_number("issue-" <> rest) do
    case Integer.parse(rest) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  def parse_issue_number(_), do: :error

  defp default_role_emails(role), do: ["#{role}@lcars.local"]

  defp require_opt(opts, key) do
    case Keyword.get(opts, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, key}
    end
  end
end
