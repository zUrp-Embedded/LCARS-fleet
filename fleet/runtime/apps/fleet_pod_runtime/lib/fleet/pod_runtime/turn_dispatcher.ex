defmodule Fleet.PodRuntime.TurnDispatcher do
  @moduledoc """
  GenServer queue+ack PoC-20 PROVEN.

  Pattern obligatoire : stdin claude -p **NON FIFO** multi-message
  → 3/5 messages perdus en rafale sans queue Elixir intermédiaire.
  Une seule frame `dispatched` à la fois ; les suivantes sont
  enqueued jusqu'à `:result_received`.

  ## State

      %{
        status: :idle | :awaiting_result,
        queue: :queue.queue(),
        current_turn_id: nil | String.t(),
        port_ref: term(),
        port_backend: module()
      }

  ## API

    * `start_link/1` — démarre la GenServer, opts `:port_ref`
      obligatoire, `:port_backend` (default Application config), `:name`
      (optionnel).
    * `dispatch/2` — `call`, retourne `{:ok, turn_id}` (idle, write
      Port immédiat) ou `{:ok, turn_id, :pending}` (busy, enqueued).
    * `result_received/3` — `cast`, signale fin du turn courant et
      déclenche le suivant en queue.
    * `state/1` — `call`, snapshot lecture pour tests / introspection.

  ## Surface SDK isolée

  Les Port write opérations sont déléguées à un module backend
  implémentant `Fleet.PodRuntime.PortBackend`. Le default
  `NotWiredYet` retourne `:not_wired_yet` (cf moduledoc Application).
  """

  use GenServer

  defstruct [:status, :queue, :current_turn_id, :port_ref, :port_backend]

  @type t :: %__MODULE__{
          status: :idle | :awaiting_result,
          queue: :queue.queue(),
          current_turn_id: nil | String.t(),
          port_ref: term(),
          port_backend: module()
        }

  @doc """
  Démarre une instance TurnDispatcher.

  ## Inputs

    * `:port_ref` (obligatoire) — référence Port BEAM (term opaque)
    * `:port_backend` (optionnel) — module backend Port. Default :
      Application config `:fleet_pod_runtime, :port_backend` (sinon
      `PortBackend.NotWiredYet`)
    * `:name` (optionnel) — nom OTP enregistré
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gs_opts)
  end

  @doc """
  Dispatch un message turn.

  Retourne `{:ok, turn_id}` si la GenServer est `:idle` (write Port
  immédiat) ou `{:ok, turn_id, :pending}` si `:awaiting_result` (le
  message est enqueued, sera dispatché après le prochain ack).

  Retourne `{:error, reason}` si le backend Port échoue lors d'un
  write immédiat — l'état reste `:idle`.
  """
  @spec dispatch(GenServer.server(), map()) ::
          {:ok, String.t()} | {:ok, String.t(), :pending} | {:error, term()}
  def dispatch(server, message) when is_map(message) do
    GenServer.call(server, {:dispatch, message})
  end

  @doc """
  Signale la réception du résultat du turn courant.

  Cast async — si `turn_id` correspond à `current_turn_id`, transitionne
  vers `:idle` ou dispatch le suivant en queue. Si `turn_id` ne
  correspond pas, no-op (ack obsolète ignoré).
  """
  @spec result_received(GenServer.server(), String.t(), term()) :: :ok
  def result_received(server, turn_id, result) when is_binary(turn_id) do
    GenServer.cast(server, {:result_received, turn_id, result})
  end

  @doc """
  Snapshot lecture de l'état GenServer (pour tests et introspection).
  """
  @spec state(GenServer.server()) :: t()
  def state(server), do: GenServer.call(server, :state)

  @impl true
  def init(opts) do
    port_ref = Keyword.fetch!(opts, :port_ref)
    port_backend = Keyword.get(opts, :port_backend) || default_backend()

    state = %__MODULE__{
      status: :idle,
      queue: :queue.new(),
      current_turn_id: nil,
      port_ref: port_ref,
      port_backend: port_backend
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:dispatch, message}, _from, %__MODULE__{status: :idle} = state) do
    turn_id = generate_turn_id()
    payload = encode_message(message, turn_id)

    case state.port_backend.write(state.port_ref, payload) do
      :ok ->
        new_state = %{state | status: :awaiting_result, current_turn_id: turn_id}
        {:reply, {:ok, turn_id}, new_state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:dispatch, message}, _from, %__MODULE__{status: :awaiting_result} = state) do
    turn_id = generate_turn_id()
    new_queue = :queue.in({turn_id, message}, state.queue)
    {:reply, {:ok, turn_id, :pending}, %{state | queue: new_queue}}
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(
        {:result_received, turn_id, _result},
        %__MODULE__{current_turn_id: turn_id} = state
      ) do
    case :queue.out(state.queue) do
      {{:value, {next_id, next_message}}, rest} ->
        payload = encode_message(next_message, next_id)

        case state.port_backend.write(state.port_ref, payload) do
          :ok ->
            {:noreply, %{state | queue: rest, current_turn_id: next_id, status: :awaiting_result}}

          {:error, reason} ->
            require Logger

            Logger.error(
              "TurnDispatcher write-fail post-ack on turn #{next_id}: #{inspect(reason)} — re-enqueue head"
            )

            requeued = :queue.in_r({next_id, next_message}, rest)
            {:noreply, %{state | queue: requeued, current_turn_id: nil, status: :idle}}
        end

      {:empty, _} ->
        {:noreply, %{state | status: :idle, current_turn_id: nil}}
    end
  end

  def handle_cast({:result_received, _wrong_id, _result}, state), do: {:noreply, state}

  defp generate_turn_id do
    "turn-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp encode_message(message, turn_id) do
    Jason.encode!(Map.put(message, "turn_id", turn_id)) <> "\n"
  end

  defp default_backend do
    Application.get_env(
      :fleet_pod_runtime,
      :port_backend,
      Fleet.PodRuntime.PortBackend.NotWiredYet
    )
  end
end
