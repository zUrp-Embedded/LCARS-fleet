defmodule Fleet.Admiral.AuditConsumerResubscribeTest do
  @moduledoc """
  Exercises consumer restart and subsequent Bus reception. Counter uses a dedicated
  topic and exact counts; real AuditConsumer uses the shared topic and minimum counts,
  so unrelated audited events could satisfy that observation. Events during downtime
  are not replayed. The substitute alone cannot prove another consumer's subscription.
  """
  use ExUnit.Case, async: false
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.EventRouter.Bus

  # Counter subscribes in init; it does not model consumers subscribing in handle_continue.
  defmodule Counter do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts) do
      :ok = Bus.subscribe(Keyword.fetch!(opts, :topic))
      {:ok, %{count: 0}}
    end

    @impl true
    def handle_info(%Fleet.Event{}, state), do: {:noreply, %{state | count: state.count + 1}}
    def handle_info(_other, state), do: {:noreply, state}
  end

  @topic "fleet.events.resubscribe_test"

  defp ev, do: Fleet.Event.new(:spawner, :"pod.completed")

  @tag :resubscribe
  test "the REAL AuditConsumer, killed under its supervisor, resubscribes and consumes post-restart" do
    name = :"resub_real_audit_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({Fleet.Admiral.AuditConsumer, name: name, subscribe: true},
            id: :real_audit
          )
        ],
        strategy: :one_for_one
      )

    pid1 = Process.whereis(name)
    assert is_pid(pid1)

    ExUnit.CaptureLog.capture_log(fn ->
      Bus.broadcast_main(ev())
      assert wait_count(name, 1)
    end)

    Process.exit(pid1, :kill)

    assert Enum.reduce_while(1..50, false, fn _, _ ->
             case Process.whereis(name) do
               pid when is_pid(pid) and pid != pid1 -> {:halt, true}
               _ -> Process.sleep(20) && {:cont, false}
             end
           end),
           "supervisor did not restart the real consumer"

    ExUnit.CaptureLog.capture_log(fn ->
      Bus.broadcast_main(ev())
      assert wait_count(name, 1), "restarted AuditConsumer consumed NOTHING (deaf-but-green)"
    end)

    Supervisor.stop(sup)
  end

  defp wait_count(name, min) do
    Enum.reduce_while(1..50, false, fn _, _ -> count_reached?(Process.whereis(name), min) end)
  end

  defp count_reached?(pid, min) when is_pid(pid) do
    if settle(pid).events_count >= min,
      do: {:halt, true},
      else: Process.sleep(20) && {:cont, false}
  end

  defp count_reached?(_absent, _min), do: Process.sleep(20) && {:cont, false}

  @tag :resubscribe
  test "killed consumer → restarted by the supervisor → receives POST-restart events" do
    name = :"resub_counter_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      Supervisor.start_link(
        [Supervisor.child_spec({Counter, name: name, topic: @topic}, id: :resub)],
        strategy: :one_for_one
      )

    pid1 = Process.whereis(name)
    assert is_pid(pid1)

    Bus.broadcast(@topic, ev())
    assert %{count: 1} = settle(name)

    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}

    pid2 = wait_for_restart(name, pid1)
    assert pid2 != pid1, "the supervisor must have restarted a NEW instance"

    # Fresh Counter state starts at zero; one event after restart must reach the new instance.
    Bus.broadcast(@topic, ev())
    assert %{count: 1} = settle(name)

    Supervisor.stop(sup)
  end

  defp wait_for_restart(name, old_pid, tries \\ 200)
  defp wait_for_restart(_name, _old, 0), do: flunk("consumer never restarted under its name")

  defp wait_for_restart(name, old_pid, tries) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _ -> Process.sleep(5) && wait_for_restart(name, old_pid, tries - 1)
    end
  end
end
