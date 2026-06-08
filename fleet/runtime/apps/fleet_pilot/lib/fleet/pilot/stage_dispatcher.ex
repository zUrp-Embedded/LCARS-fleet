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

    case decide(payload, &role_loadable?(loader, &1)) do
      {:skip, reason} ->
        {:skipped, reason}

      {:spawn, role} ->
        issue = Map.get(payload, "issue", payload)
        number = issue["number"]
        repo = Keyword.fetch!(opts, :repo)
        forge_opts = Keyword.get(opts, :forge_opts, [])
        ts = clock.(:second)

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
             {:ok, pod_id} <-
               spawner.spawn_pod(profile, "issue-#{number}", mandate: issue["body"] || "") do
          Logger.info(
            "StageDispatcher: spawned role=#{role} pod=#{pod_id} issue=#{repo}##{number}"
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

  # ============================================================
  # Internals
  # ============================================================

  defp role_loadable?(loader, role) do
    match?({:ok, _}, loader.load(role))
  end

  defp default_known_role?(role), do: role_loadable?(Fleet.CapProfile, role)
end
