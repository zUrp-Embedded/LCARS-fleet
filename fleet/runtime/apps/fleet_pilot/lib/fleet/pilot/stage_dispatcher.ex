defmodule Fleet.Pilot.StageDispatcher do
  @moduledoc """
  Dispatch `assignee → spawn` du modèle forge-state-machine (DN
  `orchestration/forge-state-machine.md` §3/§6). Distinct du `Fleet.Pilot.Dispatcher`
  legacy (route → pipeline nommé) : ici le poller voit un ticket **assigné à un rôle**
  et **spawn ce rôle** (= stage courant), sans table de routes.

  ## Décision (pure, `decide/1`)

  À partir du payload d'une issue Gitea, décide :
    * `{:spawn, role}` — assignee = un rôle connu (login forge → cap-profile), pas de
      verrou `lcars-in-flight` → spawner le rôle.
    * `{:skip, reason}` — `:no_role` (assignee humain / inconnu), `:in_flight` (verrou
      posé, pod déjà en vol), `:no_assignee`.

  `decide/1` ne fait **aucune** I/O — elle lit le payload (labels + assignees) déjà
  fourni par le poller. Testable sans réseau ni forge.

  ## Effets (`dispatch_issue/2`)

  Sur `{:spawn, role}`, applique l'**ordre canonique du spawn** (DN §6, label AVANT pod,
  sinon double-spawn) :
    1. PUT label `lcars-in-flight` (verrou)
    2. POST comment `[lock:<role>:<ts>]` (TTL / diagnostic recovery)
    3. spawn le pod (`CapProfile.load(role)` → `Spawner.spawn_pod(profile, ticket_id,
       mandate: issue.body)`)

  Les modules `:forge_client`, `:loader`, `:spawner` sont des **seams** (défauts =
  modules réels) pour tester sans toucher forge ni spawner.
  """

  require Logger

  @in_flight_label "lcars-in-flight"
  @awaits_human_label "lcars-awaits-human"

  @type decision :: {:spawn, role :: String.t()} | {:skip, atom()}

  @doc """
  Décision pure : payload issue Gitea → `{:spawn, role}` | `{:skip, reason}`.
  `known_role?` (fun arité 1) injectable pour les tests ; défaut = `CapProfile.load/1` réussit.
  """
  @spec decide(map(), (String.t() -> boolean())) :: decision()
  def decide(payload, known_role? \\ &default_known_role?/1) when is_map(payload) do
    issue = Map.get(payload, "issue", payload)
    labels = Enum.map(Map.get(issue, "labels", []), & &1["name"])
    assignees = Map.get(issue, "assignees") || []

    cond do
      @in_flight_label in labels ->
        {:skip, :in_flight}

      # A2.3b : verrou HUMAIN (verdict gatekeeper escalate/halt/redirect, ou anomalie A2.6).
      # L'issue attend une action via l'arch ; le poller NE re-dispatche PAS (sinon, après
      # l'unlock de `await_human`, l'assignee=gatekeeper relancerait un jugement en boucle).
      @awaits_human_label in labels ->
        {:skip, :awaits_human}

      assignees == [] ->
        {:skip, :no_assignee}

      true ->
        # 1-assignee strict (DN §10) : on prend le 1er login, role = login downcasé.
        login = assignees |> hd() |> Map.get("login", "")
        role = String.downcase(login)

        if role != "" and known_role?.(role),
          do: {:spawn, role},
          else: {:skip, :no_role}
    end
  end

  @doc """
  Dispatch effectif d'une issue : `decide/1` puis, sur `{:spawn, role}`, l'ordre
  canonique du spawn (verrou → comment → pod). Idempotent via les write-ops ForgeClient.

  `opts` : `:repo` (obligatoire), `:forge_opts` (passé au ForgeClient), + seams
  `:forge_client` / `:loader` / `:spawner` / `:clock` (défauts = modules réels).
  """
  @spec dispatch_issue(map(), keyword()) ::
          {:ok, {:spawned, pod_id :: String.t(), role :: String.t()}}
          | {:skipped, atom()}
          | {:error, term()}
  def dispatch_issue(payload, opts) do
    forge = Keyword.get(opts, :forge_client, Fleet.Pilot.ForgeClient)
    loader = Keyword.get(opts, :loader, Fleet.CapProfile)
    spawner = Keyword.get(opts, :spawner, Fleet.Spawner)
    task_queue = Keyword.get(opts, :task_queue, Fleet.TaskQueue)
    clock = Keyword.get(opts, :clock, &System.os_time/1)
    resolver = Keyword.get(opts, :project_resolver, &default_project_resolver/2)

    case decide(payload, &role_loadable?(loader, &1)) do
      {:skip, reason} ->
        {:skipped, reason}

      {:spawn, role} ->
        issue = Map.get(payload, "issue", payload)
        number = issue["number"]
        repo = Keyword.fetch!(opts, :repo)
        forge_opts = Keyword.get(opts, :forge_opts, [])
        ts = clock.(:second)

        # PROJET résolu AVANT toute écriture forge (read-only ls-remote) : un échec
        # transitoire ne laisse pas de verrou orphelin. base_sha pinné HORS-pod (F-03 R1,
        # symétrique de l'Executor) → injecté au clone du pod (project.base_sha).
        # PROJET + ROUTE résolus AVANT toute écriture forge (read-only) : un échec transitoire
        # ne laisse pas de verrou orphelin. project = base_sha pinné (F-03) ; route = (pipeline,
        # stage) gravé sur la forge (A2.1) → identifie le stage (l'assignee=rôle ne suffit pas).
        # `:none` (hors-carte / 1-stage) → route nil → comportement A1.
        with {:ok, project} <- tag_err(resolver.(repo, opts), :project_resolution),
             {:ok, route} <-
               tag_err(route_for(forge, repo, number, forge_opts), :route_resolution) do
          # pod_id DÉTERMINISTE (string connue AVANT spawn) : `Spawner.spawn_pod/3` retourne le
          # `pid` du GenServer ; on impose le pod_id via `:pod_id`. `ts` le rend unique par hop.
          pod_id = "issue-#{number}-#{role}-#{ts}"

          # F078 : le mandat role-aware (GateBrief I-CBC pour gatekeeper, body d'issue pour worker)
          # est calculé UNE fois et sert au spawn-file ET au brief TaskQueue (que le pod pull via
          # get_task). Sans ça, enqueue_mandate ré-enqueuait `issue["body"]` brut → le gatekeeper
          # pullait le mandat BUILD exécutable au lieu du GateBrief → PASSE-9 recréé.
          mandate = build_mandate(forge, repo, number, role, issue, forge_opts, route)

          spawn_opts =
            [
              mandate: mandate,
              pod_id: pod_id
            ]
            |> maybe_put_project(project)
            |> maybe_put_route(route)

          # Ordre canonique du SPAWN (DN §6) : label AVANT pod.
          with {:ok, _} <- forge.add_label(repo, number, @in_flight_label, forge_opts),
               {:ok, _} <-
                 forge.post_comment(
                   repo,
                   number,
                   "[lock:#{role}:#{ts}]",
                   Keyword.put(forge_opts, :dedup_signature, "[lock:#{role}:")
                 ),
               {:ok, profile} <- loader.load(role),
               {:ok, _pid} <- spawner.spawn_pod(profile, "issue-#{number}", spawn_opts),
               :ok <- enqueue_mandate(task_queue, pod_id, role, number, mandate) do
            # Kick best-effort : le pod auto-kicke les workers ; le wake accélère le 1er get_task.
            _ = safe_wake(spawner, pod_id)

            Logger.info(
              "StageDispatcher: spawned role=#{role} pod=#{pod_id} issue=#{repo}##{number} " <>
                "project=#{if(project, do: project["base_sha"], else: "none")} route=#{inspect(route)}"
            )

            {:ok, {:spawned, pod_id, role}}
          else
            {:error, _} = err ->
              Logger.warning(
                "StageDispatcher: spawn role=#{role} issue=#{repo}##{number} → #{inspect(err)}"
              )

              err
          end
        else
          {:error, {phase, reason}} ->
            Logger.warning(
              "StageDispatcher: #{phase} role=#{role} issue=#{repo}##{number} → #{inspect(reason)} (skip, pas de verrou)"
            )

            {:error, {phase, reason}}
        end
    end
  end

  defp maybe_put_project(spawn_opts, nil), do: spawn_opts
  defp maybe_put_project(spawn_opts, project), do: Keyword.put(spawn_opts, :project, project)

  defp maybe_put_route(spawn_opts, nil), do: spawn_opts

  defp maybe_put_route(spawn_opts, {pipeline, stage}),
    do: spawn_opts |> Keyword.put(:pipeline, pipeline) |> Keyword.put(:stage, stage)

  # A2.3b item 5 (option B, DN gatekeeper-forge-encoding-v2 §5) : un pod **gatekeeper**
  # doit savoir QUOI juger ET comment rendre son verdict. On réutilise le brief canonique
  # `Fleet.Pipeline.GateBrief` (contexte + livrable + question + **contrat
  # `gate-decision-v1.json` + options canon**) — le même que le modèle RAM. Le `result_K`
  # à juger est lu du comment du hop précédent (gravé par HopCompleter, N-04) ; le pod reste
  # forge-aveugle (c'est le runtime qui lit le comment, option B, pas de clone F-08).
  # Rôle ordinaire → mandat = corps de l'issue (inchangé).
  defp build_mandate(forge, repo, number, "gatekeeper", _issue, forge_opts, route) do
    outputs =
      case forge.get_predecessor_result(repo, number, forge_opts) do
        {:ok, result} -> result
        _ -> %{}
      end

    {pipeline, stage} =
      case route do
        {p, s} -> {p, s}
        _ -> {nil, "gatekeeper"}
      end

    # I-CBC (bug PASSE-9, prouvé live #11 ET #12) : le mandat du juge ne contient
    # AUCUNE instruction exécutable. Le body de l'issue (= mandat du BUILD :
    # « crée X, commit ») n'est PAS injecté — même quoté en contexte « NE PAS
    # exécuter », un pod base-worker (profile noop) l'exécute (il est amorcé pour
    # FAIRE) : sur #11 et #12 le gatekeeper a recommité SMOKE.md + soumis un
    # "status ok" sans `decision`. Le seul contexte fourni = les `outputs` du
    # prédécesseur (descriptifs : commit + summary, non-exécutables). Si un jour le
    # gatekeeper a une vraie persona de juge, GateBrief sait rendre `request` en
    # contexte désamorcé — mais pas pour un base-worker.
    Fleet.Pipeline.GateBrief.build(%{
      stage: stage,
      pipeline_id: pipeline,
      gate: nil,
      outputs: outputs
    })
  end

  defp build_mandate(_forge, _repo, _number, _role, issue, _forge_opts, _route),
    do: issue["body"] || ""

  # Tag l'erreur d'une étape de résolution (préserve {:project_resolution, _} attendu).
  defp tag_err({:ok, _} = ok, _tag), do: ok
  defp tag_err({:error, reason}, tag), do: {:error, {tag, reason}}

  # Lit la position carte (pipeline, stage) gravée sur la forge (A2.1). `:none` (hors-carte /
  # 1-stage) → `{:ok, nil}` (comportement A1). Erreur HTTP → propagée (skip sans verrou).
  defp route_for(forge, repo, number, forge_opts) do
    case forge.get_route(repo, number, forge_opts) do
      {:ok, {_p, _s} = route} -> {:ok, route}
      :none -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  # Enqueue le mandat dans le broker `Fleet.TaskQueue` ciblé pod_id — le claude REPL le pull via
  # `mcp__fleet__get_task` → `PodTools.get_task` → `TaskQueue.get_for_pod` (PAS un Read fichier).
  # MÊME mécanisme que `StageRunner.push_task_for_pod` (DN §8 « réutilise StageRunner ») : sans cet
  # enqueue, `TaskQueue.pod_status(pod_id) == nil` → le pod se croit bootstrap (rien à puller) → idle.
  # Le `brief` = le MANDAT role-aware déjà construit (build_mandate) : GateBrief I-CBC pour le
  # gatekeeper, corps de l'issue pour un worker. F078 : c'était `issue["body"]` brut → le juge
  # pullait le mandat BUILD exécutable (PASSE-9). `metadata.issue` corrèle au ticket.
  defp enqueue_mandate(task_queue, pod_id, role, number, mandate) do
    attrs = %{
      ticket_id: "issue-#{number}",
      role: role,
      brief: mandate,
      metadata: %{"issue" => number}
    }

    case task_queue.enqueue(pod_id, attrs) do
      {:ok, _task} -> :ok
      {:error, reason} -> {:error, {:enqueue_failed, reason}}
    end
  end

  defp safe_wake(spawner, pod_id) do
    if function_exported?(spawner, :wake_pod, 1), do: spawner.wake_pod(pod_id), else: :ok
  rescue
    _ -> :ok
  end

  # ============================================================
  # Internals
  # ============================================================

  defp role_loadable?(loader, role) do
    match?({:ok, _}, loader.load(role))
  end

  defp default_known_role?(role), do: role_loadable?(Fleet.CapProfile, role)

  # ============================================================
  # Résolution projet (base_sha pinné hors-pod, F-03 R1)
  # ============================================================

  # Construit `%{repo_path, base_branch, base_sha}` pour le repo du ticket.
  # `base_url` ← `:forge_opts[:base_url]` ou config app ; `base_branch` ← `:base_branch`
  # (défaut "main"). Pas de forge configurée → `{:ok, nil}` (pod sans repo, ex. tests
  # locaux). L'auth de clone/ls-remote est portée par le runtime (`forge_auth_args`),
  # jamais par le pod (barrière §4).
  @spec default_project_resolver(String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def default_project_resolver(repo, opts) do
    forge_opts = Keyword.get(opts, :forge_opts, [])
    base_branch = Keyword.get(opts, :base_branch, "main")

    case forge_base_url(forge_opts) do
      nil ->
        {:ok, nil}

      base_url ->
        repo_url = "#{String.trim_trailing(base_url, "/")}/#{repo}.git"

        case ls_remote_sha(repo_url, base_branch) do
          {:ok, sha} ->
            {:ok, %{"repo_path" => repo_url, "base_branch" => base_branch, "base_sha" => sha}}

          {:error, _} = err ->
            err
        end
    end
  end

  defp forge_base_url(forge_opts) do
    Keyword.get(forge_opts, :base_url) ||
      get_in(Application.get_env(:fleet_pilot, :forge, []), [:base_url])
  end

  # `git ls-remote <repo_url> <branch>` borné + auth runtime → SHA du tip (hors-pod).
  # Symétrique de `Fleet.Pipeline.Executor.ls_remote_sha` (même rôle F-03 R1).
  defp ls_remote_sha(repo_url, branch) do
    args = Fleet.Pipeline.Git.forge_auth_args() ++ ["ls-remote", repo_url, branch]

    task = Task.async(fn -> System.cmd("git", args, stderr_to_stdout: true) end)

    case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        case out |> String.split("\n", trim: true) |> List.first() do
          nil -> {:error, :no_ref}
          line -> {:ok, line |> String.split() |> List.first()}
        end

      {:ok, {out, rc}} ->
        {:error, {rc, String.trim(out)}}

      nil ->
        {:error, :timeout}

      {:exit, reason} ->
        {:error, {:exit, reason}}
    end
  end
end
