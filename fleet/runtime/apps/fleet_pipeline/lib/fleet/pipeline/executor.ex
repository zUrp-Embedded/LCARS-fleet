defmodule Fleet.Pipeline.Executor do
  @moduledoc """
  GenServer per-pipeline-run.

  ## State

      %__MODULE__{
        pipeline_id: term(),
        pipeline: map(),                # YAML déclaratif loaded
        stages_status: %{stage => :pending | :running | :completed},
        current_stage: String.t() | nil,
        outputs: %{stage => map()},
        mandate_context: map()
      }

  ## Cycle de vie

  1. `init/1` → load pipeline via `Loader`, subscribe `fleet.events`,
     `{:continue, :start_first_stage}`
  2. `handle_continue(:start_first_stage, _)` → toposort + run first stage
  3. `handle_info` filtre `event_type == "pipeline.stage.completed"`
     pour le `pipeline_id` courant → store outputs → dispatch gate :
     - `:pass` → stage suivant ou `pipeline.completed` broadcast + stop
     - `{:fail, reason}` → `pipeline.failed` broadcast + stop
     - `:retry` → ré-exécute stage courant

  ## Process raison runtime

  GenServer = state machine async pipeline + collect events PubSub.
  Plain function impossible (events PubSub asynchrones, stages spawn
  pod async). Cohérent OTP Iron Law.
  """

  use GenServer

  alias Fleet.EventRouter.Bus
  alias Fleet.Pipeline.{Gates, Loader, StageRunner, Toposort}

  require Logger

  defstruct pipeline_id: nil,
            pipeline: nil,
            stages_status: %{},
            current_stage: nil,
            outputs: %{},
            mandate_context: %{}

  @type t :: %__MODULE__{
          pipeline_id: term(),
          pipeline: map() | nil,
          stages_status: %{optional(String.t()) => atom()},
          current_stage: String.t() | nil,
          outputs: %{optional(String.t()) => map()},
          mandate_context: map()
        }

  # ============================================================
  # Public API
  # ============================================================

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    pipeline_id = Keyword.fetch!(opts, :pipeline_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(pipeline_id))
  end

  @doc """
  Tuple `:via` Registry pour lookup process par pipeline_id.
  """
  @spec via_tuple(term()) :: {:via, Registry, {Fleet.Pipeline.Registry, term()}}
  def via_tuple(pipeline_id) do
    {:via, Registry, {Fleet.Pipeline.Registry, pipeline_id}}
  end

  # ============================================================
  # GenServer callbacks
  # ============================================================

  @impl GenServer
  def init(opts) do
    pipeline_name = Keyword.fetch!(opts, :pipeline_name)
    pipeline_id = Keyword.fetch!(opts, :pipeline_id)
    mandate_context = Keyword.get(opts, :mandate_context, %{})

    pipeline = Loader.load!(pipeline_name)
    Bus.subscribe()

    state = %__MODULE__{
      pipeline_id: pipeline_id,
      pipeline: pipeline,
      mandate_context: mandate_context,
      stages_status: pipeline["stages"] |> Map.keys() |> Map.new(fn s -> {s, :pending} end)
    }

    {:ok, state, {:continue, :start_first_stage}}
  end

  @impl GenServer
  def handle_continue(:start_first_stage, state) do
    case Toposort.sort(state.pipeline["stages"]) do
      [] ->
        {:stop, :empty_pipeline, state}

      [first | _] ->
        do_run_stage(first, state)
    end
  end

  @impl GenServer
  def handle_info(
        {_atom, %{"event_type" => "pipeline.stage.completed", "payload" => payload}},
        state
      ) do
    if payload["pipeline_id"] == state.pipeline_id do
      stage = payload["stage"]
      outputs = payload["outputs"] || %{}
      handle_stage_completed(stage, outputs, state)
    else
      {:noreply, state}
    end
  end

  def handle_info({_atom, %{"event_type" => _other}}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  # ============================================================
  # Internal
  # ============================================================

  defp handle_stage_completed(stage, outputs, state) do
    state = %{
      state
      | outputs: Map.put(state.outputs, stage, outputs),
        stages_status: Map.put(state.stages_status, stage, :completed)
    }

    stage_spec = state.pipeline["stages"][stage]

    case Gates.dispatch(stage_spec, outputs, state.mandate_context) do
      :pass ->
        next_stage_or_done(state)

      {:fail, reason} ->
        Logger.warning(
          "fleet_pipeline gate fail: pipeline=#{inspect(state.pipeline_id)} stage=#{stage} reason=#{reason}"
        )

        Bus.broadcast(
          "pipeline.failed",
          %{"pipeline_id" => state.pipeline_id, "stage" => stage, "reason" => reason},
          ticket_id: state.mandate_context[:ticket_id]
        )

        {:stop, :gate_fail, state}

      :retry ->
        Logger.info(
          "fleet_pipeline gate retry: pipeline=#{inspect(state.pipeline_id)} stage=#{stage}"
        )

        do_run_stage(stage, state)
    end
  end

  defp next_stage_or_done(state) do
    sorted = Toposort.sort(state.pipeline["stages"])

    pending = Enum.filter(sorted, fn s -> Map.get(state.stages_status, s) != :completed end)

    case pending do
      [next | _] ->
        do_run_stage(next, state)

      [] ->
        Bus.broadcast(
          "pipeline.completed",
          %{"pipeline_id" => state.pipeline_id, "outputs" => state.outputs},
          ticket_id: state.mandate_context[:ticket_id]
        )

        {:stop, :normal, state}
    end
  end

  defp do_run_stage(stage_name, state) do
    stage_spec = state.pipeline["stages"][stage_name]

    case StageRunner.run(
           stage_name,
           stage_spec,
           state.mandate_context,
           state.outputs,
           state.pipeline_id
         ) do
      {:ok, _pod_id} ->
        new_state = %{
          state
          | current_stage: stage_name,
            stages_status: Map.put(state.stages_status, stage_name, :running)
        }

        {:noreply, new_state}

      {:error, reason} ->
        Bus.broadcast(
          "pipeline.failed",
          %{
            "pipeline_id" => state.pipeline_id,
            "stage" => stage_name,
            "reason" => "spawn fail: #{inspect(reason)}"
          },
          ticket_id: state.mandate_context[:ticket_id]
        )

        {:stop, :spawn_fail, state}
    end
  end
end
