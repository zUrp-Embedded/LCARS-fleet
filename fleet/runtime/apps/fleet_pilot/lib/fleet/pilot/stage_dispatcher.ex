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
        case resolver.(repo, opts) do
          {:error, reason} ->
            Logger.warning(
              "StageDispatcher: project resolution role=#{role} issue=#{repo}##{number} → #{inspect(reason)} (skip, pas de verrou)"
            )

            {:error, {:project_resolution, reason}}

          {:ok, project} ->
            # pod_id DÉTERMINISTE (string connue AVANT spawn) : `Spawner.spawn_pod/3` retourne le
            # `pid` du GenServer, pas l'identifiant ; on impose donc le pod_id via `:pod_id` (sinon
            # UUID interne). Utile au diagnostic (lock comment) + recovery (lookup issue/role). `ts`
            # le rend unique par hop (respawn = nouveau ts).
            pod_id = "issue-#{number}-#{role}-#{ts}"

            spawn_opts =
              [mandate: issue["body"] || "", pod_id: pod_id]
              |> maybe_put_project(project)

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
                 {:ok, _pid} <- spawner.spawn_pod(profile, "issue-#{number}", spawn_opts) do
              Logger.info(
                "StageDispatcher: spawned role=#{role} pod=#{pod_id} issue=#{repo}##{number} " <>
                  "project=#{if(project, do: project["base_sha"], else: "none")}"
              )

              {:ok, {:spawned, pod_id, role}}
            else
              {:error, _} = err ->
                Logger.warning(
                  "StageDispatcher: spawn role=#{role} issue=#{repo}##{number} → #{inspect(err)}"
                )

                err
            end
        end
    end
  end

  defp maybe_put_project(spawn_opts, nil), do: spawn_opts
  defp maybe_put_project(spawn_opts, project), do: Keyword.put(spawn_opts, :project, project)

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
