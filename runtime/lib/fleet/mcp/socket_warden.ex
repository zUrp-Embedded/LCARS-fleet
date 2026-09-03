defmodule Fleet.MCP.SocketWarden do
  @moduledoc """
  Runtime reaper for sockets whose pod disappeared without release, and detector of the SYMMETRIC
  failure: pods whose acceptor disappeared without them.

  Two reconciliations on the same tick, and they are not the same question:

    * **acceptor without pod** — we own a live acceptor whose pod is gone (brutal teardown). The
      socket is ours to close, so this one is REAPED.
    * **pod without acceptor** — a socket file on disk with no acceptor behind it, after a
      `:one_for_one` cascade. The pod is alive and holds that path; reaping the file would only
      hide it. This one is a DEAF POD: it keeps writing into a socket nobody listens on, reports
      nothing, and looks exactly like an agent with nothing to say. It is raised as an incident.

  Both carry two-tick grace, because both have a legitimate transient: a pod being torn down passes
  through "acceptor alive, pod gone", and a release passes through "file present, acceptor gone".
  Enumeration failure reaps nothing, raises nothing, and preserves suspects — an unreadable
  directory is not an empty one.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @impl GenServer
  def init(opts) do
    tick_ms = Keyword.get(opts, :tick_ms, 60_000)

    state = %{
      tick_ms: tick_ms,
      live_pods_fun: Keyword.get(opts, :live_pods_fun, &default_live_pods/0),
      owned_fun: Keyword.get(opts, :owned_fun, &Fleet.MCP.PodSocketSupervisor.live_pod_ids/0),
      release_fun:
        Keyword.get(opts, :release_fun, &Fleet.MCP.PodSocketSupervisor.release_pod_socket/1),
      deaf_fun: Keyword.get(opts, :deaf_fun, &Fleet.MCP.Supervisor.deaf_pods/0),
      emit_fun: Keyword.get(opts, :emit_fun, &Bus.safe_emit/4),
      suspects: MapSet.new(),
      deaf_suspects: MapSet.new(),
      # Deja signale : un pod sourd le reste jusqu'a ce qu'un humain agisse, et le tick repasse
      # toutes les 60 s. Sans cette memoire, la chaine d'incident recevrait le meme sujet en boucle
      # et son propre compteur de recurrence — celui qui decide « note » ou « issue sysadmin » —
      # mesurerait le tick du warden au lieu de mesurer le probleme.
      deaf_reported: MapSet.new()
    }

    Process.send_after(self(), :reap, tick_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:reap, state) do
    Process.send_after(self(), :reap, state.tick_ms)

    # LES DEUX RECONCILIATIONS SONT INDEPENDANTES, ET C'EST POUR CA QU'ELLES SONT SEPAREES ICI. La
    # detection des sourds ne lit PAS la liste des pods vivants — elle compare le disque au registre
    # des acceptors. La ranger dans la branche qui reussit aurait fait qu'une panne d'enumeration des
    # pods aveugle une detection qui n'en depend pas : une panne cachant l'autre, en silence.
    state = report_deaf_pods(state)

    case live_pod_ids(state) do
      :error ->
        # Unknown is not an empty live set.
        {:noreply, state}

      live ->
        orphans = state.owned_fun.() |> MapSet.new() |> MapSet.difference(live)
        confirmed = MapSet.intersection(orphans, state.suspects)

        for pod_id <- confirmed do
          Logger.warning(
            "SocketWarden: MCP socket of pod #{pod_id} ORPHANED (pod gone without releasing — " <>
              "brutal teardown?) → released"
          )

          _ = state.release_fun.(pod_id)
        end

        {:noreply, %{state | suspects: MapSet.difference(orphans, confirmed)}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # UN POD SOURD NE SE REPARE PAS ICI, ET C'EST DELIBERE. Le fichier appartient a un pod VIVANT qui
  # ecrit dedans ; le supprimer ne rendrait pas l'oreille, ça retirerait la seule trace. Redemarrer
  # un acceptor sous un pod deja lance est une decision de cycle de vie qui appartient au spawner,
  # pas au balayeur de sockets. Ce que ce module doit a la fleet, c'est de le rendre AUDIBLE — et
  # `pod.deaf` porte `action: incident`, donc note a la 1re occurrence, issue sysadmin a la
  # recurrence. C'est la moitie durable ; le log ci-dessous n'est que la moitie immediate.
  defp report_deaf_pods(state) do
    case safe_deaf(state) do
      :error ->
        # On ne sait pas : on ne blanchit personne. `deaf_reported` est conserve tel quel, sinon la
        # prochaine lecture reussie re-signalerait des sujets deja ouverts.
        state

      deaf ->
        confirmed = MapSet.intersection(deaf, state.deaf_suspects)
        fresh = MapSet.difference(confirmed, state.deaf_reported)

        for pod_id <- fresh do
          Logger.error(
            "SocketWarden: pod #{pod_id} is DEAF — socket file present, NO acceptor behind it " <>
              "(cascade?). The pod keeps writing into it and reports nothing."
          )

          _ =
            state.emit_fun.(
              :mcp,
              :"pod.deaf",
              [payload: %{"pod_id" => pod_id, "reason" => "acceptor_absent"}],
              context: "SocketWarden"
            )
        end

        %{
          state
          | deaf_suspects: MapSet.difference(deaf, confirmed),
            # Un pod qui n'est plus sourd sort du registre : s'il le redevient, c'est un fait neuf
            # et il doit se redire. Garder la marque a vie transformerait « signale une fois » en
            # « ne le dira plus jamais ».
            deaf_reported: MapSet.intersection(MapSet.union(state.deaf_reported, fresh), deaf)
        }
    end
  end

  defp safe_deaf(state) do
    case state.deaf_fun.() do
      {:ok, ids} ->
        MapSet.new(ids)

      {:error, reason} ->
        Logger.warning(
          "SocketWarden: deaf-pod cross-check could not run (#{inspect(reason)}) — nothing raised " <>
            "this tick; an unreadable socket dir is NOT an empty one"
        )

        :error
    end
  rescue
    e ->
      Logger.warning("SocketWarden: deaf-pod cross-check raised (#{inspect(e)}) — nothing raised")
      :error
  catch
    _, _ -> :error
  end

  defp live_pod_ids(state) do
    MapSet.new(state.live_pods_fun.())
  rescue
    e ->
      Logger.warning(
        "SocketWarden: live-pod enumeration failed (#{inspect(e)}) — nothing reaped this tick"
      )

      :error
  catch
    _, _ -> :error
  end

  defp default_live_pods do
    Enum.map(Fleet.Spawner.list_pods(), & &1[:pod_id])
  end
end
