defmodule Fleet.Pilot.IncidentConsumer do
  @moduledoc """
  Consumes Bus events whose events.yaml route has `action: incident`. The route
  supplies the operation, subject key, diagnostic fields and escalation kind.
  Recurrence routes note first and escalate later; immediate routes attempt an
  issue on the first occurrence, then use the registry's cooldown.

  This mailbox is separate from step completion. Production injects `offload_async/1`;
  without a `:runner`, registry calls run synchronously. Refused task admission falls
  back inline; task death is logged, without replay here.

  Successful or suppressed recurrence escalation can brake a pod result timeout:
  add awaits-arch on its work ticket, then attempt to clear in-flight. Failed
  escalation does not brake. The default brake logs returned errors and rescues
  exceptions; injected callbacks and synchronous recording can still raise.

  Seams: `:subscribe` (default true), `:routing_fun` (Bus routing), `:record_fun`
  (record_or_escalate/4), `:escalate_fun` (escalate_gated/5), `:brake_fun`
  (default_brake/3) and `:runner` (a function accepting the work closure).
  """

  use GenServer
  require Logger

  alias Fleet.EventRouter.Bus

  # Separate from the completion pool; started by Pilot.Application.
  @task_supervisor Fleet.Pilot.IncidentConsumer.TaskSupervisor

  defstruct record_fun: nil, escalate_fun: nil, runner: nil, routing_fun: nil, brake_fun: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gs_opts, init_opts} = Keyword.split(opts, [:name])
    name = Keyword.get(gs_opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, init_opts, name: name)
  end

  @doc false
  @spec task_supervisor() :: module()
  def task_supervisor, do: @task_supervisor

  # Refused task admission runs inline; this does not guarantee recording succeeds.
  @doc false
  @spec offload_async((-> any())) ::
          {:ok, :inline | :offloaded} | {:error, :inline_crashed}
  def offload_async(fun) do
    Fleet.Pilot.Offload.async_or_inline(
      @task_supervisor,
      fun,
      {"IncidentConsumer", "incident NOT recorded"}
    )
  end

  @impl GenServer
  def init(opts) do
    if Keyword.get(opts, :subscribe, true), do: :ok = Bus.subscribe()

    state = %__MODULE__{
      record_fun:
        Keyword.get(opts, :record_fun, &Fleet.Pilot.IncidentRegistry.record_or_escalate/4),
      escalate_fun:
        Keyword.get(opts, :escalate_fun, &Fleet.Pilot.IncidentRegistry.escalate_gated/5),
      runner: Keyword.get(opts, :runner),
      brake_fun: Keyword.get(opts, :brake_fun, &__MODULE__.default_brake/3),
      # Inject the table in tests without mutating global published routing.
      routing_fun: Keyword.get(opts, :routing_fun, &Bus.event_routing/0)
    }

    {:ok, state}
  end

  @impl GenServer
  # Classification comes from routing data; unrelated events are ignored.
  def handle_info(%Fleet.Event{source: source, type: type, payload: p} = ev, state) do
    case Map.get(state.routing_fun.(), {source, type}) do
      %{action: :incident, incident: inc} ->
        handle_incident(state, inc, p, ev)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # Handle monitored task deaths before the catch-all so failures are logged.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    _ = Fleet.Pilot.Offload.handle_down(ref, pid, reason)
    {:noreply, state}
  end

  # Any other message (non-failure events we also see via the Bus, or non-Fleet.Event) → no-op.
  def handle_info(_other, state), do: {:noreply, state}

  # Missing or non-binary subjects are rejected: nil would collapse dedup keys.
  # Stable reason and variable diagnostic detail travel separately.
  defp handle_incident(state, inc, payload, ev) do
    case Map.get(payload, inc.subject) do
      subject when is_binary(subject) ->
        reg_opts =
          [
            reason_detail: payload["reason_detail"],
            correlation_id: ev.correlation_id
          ] ++
            if(inc.escalate_kind, do: [escalate_kind: inc.escalate_kind], else: []) ++
            for key <- inc.forward, do: {key, payload[Atom.to_string(key)]}

        # Hand-written routing seams may omit :gate; use the YAML recurrence default.
        case Map.get(inc, :gate, :recurrence) do
          :immediate ->
            escalate_immediate(state, inc, subject, payload["reason"], reg_opts)

          _recurrence ->
            record(state, inc.op, subject, payload["reason"], reg_opts, payload)
        end

      _ ->
        Logger.warning(
          "IncidentConsumer: routed incident #{ev.type} carries no #{inspect(inc.subject)} " <>
            "subject — producer bug, NOT recorded (a nil subject would collapse the dedup signature)"
        )
    end
  end

  # Immediate signatures use op:subject, without recurrence-key normalization.
  defp escalate_immediate(state, inc, subject, reason, reg_opts) do
    sig = "#{inc.op}:#{subject}"

    exec = fn ->
      case state.escalate_fun.(inc.escalate_kind, subject, reason, sig, reg_opts) do
        {:ok, number} ->
          Logger.warning(
            "IncidentConsumer: #{inc.op} #{subject} → sysadmin issue ##{number} " <>
              "(gate=immediate, 1re occurrence)"
          )

        {:suppressed, issue} ->
          Logger.debug(
            "IncidentConsumer: #{inc.op} #{subject} sous cooldown — l'issue ouverte " <>
              "#{inspect(issue)} porte l'alarme"
          )

        {:error, e} ->
          Logger.error(
            "IncidentConsumer: #{inc.op} #{subject} gate=immediate mais l'escalade a ECHOUE — " <>
              "AUCUNE issue sysadmin (forge down ?) : #{inspect(e)}"
          )
      end
    end

    (state.runner || (&run_sync/1)).(exec)
  end

  defp record(state, op, pod_id, reason, reg_opts, payload) do
    exec = fn ->
      case state.record_fun.(op, pod_id, reason, reg_opts) do
        :recorded ->
          Logger.info(
            "IncidentConsumer: #{op}.failed #{pod_id} → incident recorded (#{inspect(reason)})"
          )

        {:escalated, _} ->
          Logger.warning(
            "IncidentConsumer: #{op}.failed #{pod_id} RECURRENT → escalated (#{inspect(reason)})"
          )

          maybe_brake(state, op, reason, payload)

        {:escalation_failed, e} ->
          Logger.error(
            "IncidentConsumer: #{op}.failed #{pod_id} RECURRENT but escalation FAILED — NO sysadmin " <>
              "issue created (forge down?): #{inspect(e)}"
          )

        {:recorded_volatile, e} ->
          Logger.error(
            "IncidentConsumer: #{op}.failed #{pod_id}: incident in MEMORY only — WAL write FAILED " <>
              "(#{inspect(e)}): NOT durable cross-session until the async forge sync absorbs it " <>
              "(a crash before the sync would lose the recurrence)"
          )

        {:record_failed, e} ->
          Logger.error(
            "IncidentConsumer: #{op}.failed #{pod_id}: incident NOT recorded (registry unavailable): #{inspect(e)}"
          )

        {:escalation_suppressed, issue} ->
          # Count/last_seen still advance under cooldown; log repeats at debug level.
          Logger.debug(
            "IncidentConsumer: #{op}.failed #{pod_id} recurrent under cooldown — noted, " <>
              "existing issue #{inspect(issue)} carries the alarm"
          )

          # Cooldown suppresses sysadmin issue creation, not the work-ticket brake.
          maybe_brake(state, op, reason, payload)

        other ->
          Logger.warning(
            "IncidentConsumer: #{op}.failed #{pod_id} → unexpected outcome #{inspect(other)}"
          )
      end
    end

    (state.runner || (&run_sync/1)).(exec)
  end

  # Restrict braking to pod result timeouts: other recurrent failures may be
  # recoverable through rework. A sysadmin issue alone does not stop redispatch.
  defp maybe_brake(state, "pod", reason, payload) when is_map(payload) do
    with true <- timeout_reason?(reason),
         repo when is_binary(repo) <- payload["repo"],
         {:ok, number} <- Fleet.Pilot.IssueId.parse(payload["issue_id"] || "") do
      state.brake_fun.(repo, number, reason)
    else
      _ -> :ok
    end
  end

  defp maybe_brake(_state, _op, _reason, _payload), do: :ok

  # Match the bus reason's textual category by substring.
  defp timeout_reason?(reason), do: to_string(reason) =~ "result_timeout"

  @doc false
  # Returned errors and exceptions are logged; throws and exits are not caught.
  @spec default_brake(String.t(), integer(), term()) :: :ok
  # The brake callback is injectable at the consumer; its default uses Forge.Client.
  # Unlike MCP boundary indirection, another configurable client adds no boundary here.
  def default_brake(repo, number, reason) do
    forge = Fleet.Forge.Client

    case forge.add_label(repo, number, Fleet.Labels.awaits_arch(), []) do
      {:ok, _} ->
        Logger.warning(
          "IncidentConsumer: FREIN — #{repo}##{number} sort du dispatch (#{inspect(reason)} " <>
            "recurrent) : `#{Fleet.Labels.awaits_arch()}` pose, l'arch tranche"
        )

        clear_in_flight(forge, repo, number)
        :ok

      {:error, e} ->
        Logger.error(
          "IncidentConsumer: FREIN NON POSE sur #{repo}##{number} (#{inspect(e)}) — le ticket " <>
            "reste dans la boucle de re-dispatch"
        )

        :ok
    end
  rescue
    e ->
      Logger.error("IncidentConsumer: FREIN a leve sur #{repo}##{number} : #{inspect(e)}")
      :ok
  end

  # Clear in-flight after awaits-arch to avoid orphan-lock reconciliation.
  # This is best effort: a failed removal can leave both labels present.
  # Do not use StepRunCompleter.unlock: the incident has no locking-role identity.
  # Consequently its stopwatch is not stopped and no step.unlocked feed event is emitted.
  defp clear_in_flight(forge, repo, number) do
    case forge.remove_label(repo, number, Fleet.Labels.in_flight(), []) do
      {:ok, _} ->
        :ok

      {:error, e} ->
        Logger.error(
          "IncidentConsumer: FREIN pose mais `#{Fleet.Labels.in_flight()}` NON retire sur " <>
            "#{repo}##{number} (#{inspect(e)}) — le verrou orphelin sera repris par la " <>
            "reconciliation et le ticket re-dispatche malgre le frein"
        )

        :ok
    end
  end

  defp run_sync(fun), do: fun.()
end
