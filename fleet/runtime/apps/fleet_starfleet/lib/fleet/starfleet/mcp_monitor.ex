defmodule Fleet.Starfleet.MCPMonitor do
  @moduledoc """
  Health check passif du **substrat MCP pod-facing** (le DynamicSupervisor des
  sockets per-pod, `Fleet.MCP.PodSocketSupervisor`).

  DN 13 `orchestration/fleet_starfleet.md` §Extensions V2 (BL-021 chantier 8).

  ## Mécanique

  GenServer + `Process.send_after/3` récursif. À chaque tick (default 60s),
  vérifie la liveness de la cible :

    * cible vivante → status `:ok`
    * absente / morte → status `:crashed`

  Détecte la transition `:ok → :crashed` (PAS `:unknown → :crashed` au boot,
  PAS `:crashed → :crashed` pour ne pas spammer) et broadcast un event canon.
  Le retour `:crashed → :ok` log juste (recovery silencieuse, pas d'event
  dédié dans la DN MVP).

  ## Cible

  Le substrat pod-facing (`get_task`/`submit_result`) est servi par une socket
  AF_UNIX par pod, fan-out par le DynamicSupervisor `Fleet.MCP.PodSocketSupervisor`.
  On vérifie sa liveness par l'**arbre de supervision** : cible
  `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}` →
  `Supervisor.which_children/1` cherche l'enfant et teste que son pid est vivant.
  Robuste (OTP pur) et sémantiquement juste : substrat absent → `:crashed`
  silencieux (aucun broadcast depuis `:unknown`, rien à monitorer). Une cible
  **atome** reste supportée (`Process.whereis`, pour les tests + tout process nommé).

  ## Event broadcast

  Schema canon `%Fleet.Event{source: :starfleet, type: :mcp_server_crashed,
  payload: %{previous_status, new_status, target}, correlation_id: nil}`.

  ## Configuration

    * `:fleet_starfleet, :mcp_monitor_check_interval_ms` — default `60_000` (1 min)
    * `:fleet_starfleet, :mcp_monitor_target` — cible (default
      `{:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}`). Accepte un
      atome (process nommé) OU `{:supervised, sup, child_id}`. Les tests injectent une cible factice.
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  @default_interval_ms 60_000
  # On monitore le substrat pod-facing (le DynamicSupervisor d'accepteurs de socket
  # per-pod) via l'arbre de supervision (`which_children`) : enfant
  # `Fleet.MCP.PodSocketSupervisor` vivant sous `Fleet.MCP.Supervisor` → :ok.
  # Cf. moduledoc §Cible + `check_target/1`.
  @default_target {:supervised, Fleet.MCP.Supervisor, Fleet.MCP.PodSocketSupervisor}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    state = %{
      target: Keyword.get(opts, :target) || config_target(),
      interval_ms: Keyword.get(opts, :interval_ms) || config_interval_ms(),
      status: :unknown,
      last_check: nil
    }

    schedule_check(state.interval_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:health_check, state) do
    new_state = do_check(state)
    schedule_check(new_state.interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Hook test : déclenche un check immédiat sync (équivalent au timer).
  @impl GenServer
  def handle_call(:check_now, _from, state) do
    new_state = do_check(state)
    {:reply, {:ok, new_state.status}, new_state}
  end

  defp do_check(state) do
    new_status = check_target(state.target)
    new_state = %{state | status: new_status, last_check: DateTime.utc_now()}

    case {state.status, new_status} do
      {:ok, :crashed} ->
        Logger.error("MCPMonitor: target=#{inspect(state.target)} transition :ok → :crashed")

        broadcast_crashed(state.target, :ok, :crashed)

      {:crashed, :ok} ->
        Logger.info("MCPMonitor: target=#{inspect(state.target)} recovered :crashed → :ok")

      {previous, ^new_status} when previous == new_status ->
        :ok

      {previous, current} ->
        Logger.debug(
          "MCPMonitor: target=#{inspect(state.target)} transition #{inspect(previous)} → #{inspect(current)} (no broadcast)"
        )
    end

    new_state
  end

  # F049 — cible supervisée : on lit l'arbre de supervision (OTP pur). L'enfant
  # `child_id` vivant (pid) → :ok ; absent / :restarting / :undefined → :crashed.
  defp check_target({:supervised, sup, child_id}) do
    case List.keyfind(Supervisor.which_children(sup), child_id, 0) do
      {^child_id, pid, _type, _modules} when is_pid(pid) -> :ok
      _ -> :crashed
    end
  rescue
    _ -> :crashed
  catch
    # `which_children` sur un superviseur non démarré (fleet_mcp absent du nœud)
    # fait un `exit :noproc` (pas une exception) → :crashed silencieux (depuis
    # :unknown = aucun broadcast, rien à monitorer).
    :exit, _ -> :crashed
  end

  defp check_target(target) when is_atom(target) do
    case Process.whereis(target) do
      nil -> :crashed
      pid when is_pid(pid) -> :ok
    end
  end

  defp broadcast_crashed(target, previous, new) do
    event =
      Fleet.Event.new(:starfleet, :mcp_server_crashed,
        payload: %{
          "target" => inspect(target),
          "previous_status" => Atom.to_string(previous),
          "new_status" => Atom.to_string(new)
        }
      )

    Bus.broadcast("fleet.events", event)
  rescue
    # UnregisteredError = boot-order toléré : registry pas encore peuplé, broadcast
    # rejeté, pas une alarme — silencieux.
    _e in Fleet.Event.UnregisteredError ->
      :ok

    # ArgumentError/FunctionClauseError = bug de CONSTRUCTION de l'event, PAS du boot.
    # Ne JAMAIS l'avaler en :ok muet : ça masquerait l'alerte « MCP a crashé ». On la
    # rend VISIBLE puis on neutralise — ce broadcast tourne DANS le GenServer lui-même ;
    # le laisser crasher redémarrerait le moniteur avec status remis à :unknown, perdant
    # la détection de transition :ok → :crashed (sa raison d'être), et bouclerait à chaque tick.
    e in [ArgumentError, FunctionClauseError] ->
      Logger.error(
        "MCPMonitor: alerte mcp_server_crashed NON émise — event malformé (bug de construction) : #{inspect(e)}"
      )

      :ok
  end

  defp schedule_check(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :health_check, interval_ms)
  end

  defp config_interval_ms do
    Application.get_env(:fleet_starfleet, :mcp_monitor_check_interval_ms, @default_interval_ms)
  end

  defp config_target do
    Application.get_env(:fleet_starfleet, :mcp_monitor_target, @default_target)
  end
end
