defmodule Fleet.Starfleet.AuditConsumerResubscribeTest do
  @moduledoc """
  Bus re-subscribe contract after restart: a killed event consumer restarts and RE-SUBSCRIBES,
  so it receives the NEXT events. The guarantee holds by construction (the subscribe lives in
  `init/1`, which OTP calls again on EVERY restart), but it MUST be proven end to end — otherwise
  a regression (subscribe moved out of init, or a one-shot subscribe at supervisor boot) would
  leave a restarted consumer silently DEAF: alive, supervised green, but consuming nothing.
  That is the worst failure mode of a pub/sub bus, and it is invisible without this test.

  Scope, TWO proofs: the minimal `Counter` pins the init-subscribe contract SHARED by every
  such consumer (StepRunConsumer, ReadModel, …), reduced to its OTP primitive; and the REAL
  `AuditConsumer` is restarted under an isolated supervisor and proven to consume
  post-restart — a substitute's green would survive a regression of the subject itself.

  Non-async + DEDICATED topic: we really broadcast on the global Bus; a topic owned by this test
  (`@topic`) isolates the counter from any other stray `fleet.events` broadcast → exact assertion,
  no flake.
  """
  use ExUnit.Case, async: false

  alias Fleet.EventRouter.Bus

  # Minimal consumer that subscribes IN init (the contract under test) and counts what it receives.
  # Dedicated topic passed as an opt → isolated from other broadcasts. EXACT model of the real
  # pattern (AuditConsumer/StepRunConsumer/ReadModel/…: all subscribe in init/1).
  defmodule Counter do
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

    @impl true
    def init(opts) do
      # THE contract: subscription IN init → replayed on every (re)init by OTP.
      :ok = Bus.subscribe(Keyword.fetch!(opts, :topic))
      {:ok, %{count: 0}}
    end

    @impl true
    def handle_info(%Fleet.Event{}, state), do: {:noreply, %{state | count: state.count + 1}}
    def handle_info(_other, state), do: {:noreply, state}
  end

  @topic "fleet.events.resubscribe_test"

  defp ev, do: Fleet.Event.new(:spawner, :"pod.completed")

  # The Counter below proves the OTP primitive; THIS proves the REAL subject — a substitute's
  # green survives any regression of the subject itself (subscribe moved out of init, a
  # one-shot supervisor-boot subscribe): the exact deaf-but-green failure this file warns about.
  @tag :resubscribe
  test "the REAL AuditConsumer, killed under its supervisor, resubscribes and consumes post-restart" do
    name = :"resub_real_audit_#{System.unique_integer([:positive])}"

    {:ok, sup} =
      Supervisor.start_link(
        [
          Supervisor.child_spec({Fleet.Starfleet.AuditConsumer, name: name, subscribe: true},
            id: :real_audit
          )
        ],
        strategy: :one_for_one
      )

    pid1 = Process.whereis(name)
    assert is_pid(pid1)

    # Pre-restart consumption (baseline: the subject hears the Bus at all).
    ExUnit.CaptureLog.capture_log(fn ->
      Bus.broadcast_main(ev())
      assert wait_count(name, 1)
    end)

    # Kill → OTP restarts → init/1 replays the subscribe (the contract under proof).
    Process.exit(pid1, :kill)

    assert Enum.reduce_while(1..50, false, fn _, _ ->
             case Process.whereis(name) do
               pid when is_pid(pid) and pid != pid1 -> {:halt, true}
               _ -> Process.sleep(20) && {:cont, false}
             end
           end),
           "supervisor did not restart the real consumer"

    # POST-restart consumption on the FRESH pid: a deaf restart fails here.
    ExUnit.CaptureLog.capture_log(fn ->
      Bus.broadcast_main(ev())
      assert wait_count(name, 1), "restarted AuditConsumer consumed NOTHING (deaf-but-green)"
    end)

    Supervisor.stop(sup)
  end

  defp wait_count(name, min) do
    Enum.reduce_while(1..50, false, fn _, _ ->
      case Process.whereis(name) do
        pid when is_pid(pid) ->
          if :sys.get_state(pid).events_count >= min,
            do: {:halt, true},
            else: Process.sleep(20) && {:cont, false}

        _ ->
          Process.sleep(20) && {:cont, false}
      end
    end)
  end

  @tag :resubscribe
  test "killed consumer → restarted by the supervisor → receives POST-restart events" do
    name = :"resub_counter_#{System.unique_integer([:positive])}"

    # restart: :permanent (GenServer default) → OTP restarts on crash. The supervisor itself
    # subscribes to NOTHING: everything goes through the child's init/1 (the only legitimate place).
    {:ok, sup} =
      Supervisor.start_link(
        [Supervisor.child_spec({Counter, name: name, topic: @topic}, id: :resub)],
        strategy: :one_for_one
      )

    pid1 = Process.whereis(name)
    assert is_pid(pid1)

    # 1) Initial subscription OK: the event is consumed.
    Bus.broadcast(@topic, ev())
    assert %{count: 1} = :sys.get_state(name)

    # 2) Brutal kill → OTP restarts → new init/1 → new Bus.subscribe.
    ref = Process.monitor(pid1)
    Process.exit(pid1, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid1, :killed}

    pid2 = wait_for_restart(name, pid1)
    assert pid2 != pid1, "the supervisor must have restarted a NEW instance"

    # 3) PROOF: a POST-restart event is received by the NEW instance. Its count restarts at 0
    # (fresh instance), so the 1 attests that THIS instance re-subscribed and consumed — not a
    # leftover of the old one. Without re-subscribe we would stay at 0 (deaf consumer).
    Bus.broadcast(@topic, ev())
    assert %{count: 1} = :sys.get_state(name)

    Supervisor.stop(sup)
  end

  # Waits (bounded) for a NEW pid (≠ old one) registered under `name` = the effective OTP restart.
  defp wait_for_restart(name, old_pid, tries \\ 200)
  defp wait_for_restart(_name, _old, 0), do: flunk("consumer never restarted under its name")

  defp wait_for_restart(name, old_pid, tries) do
    case Process.whereis(name) do
      pid when is_pid(pid) and pid != old_pid -> pid
      _ -> Process.sleep(5) && wait_for_restart(name, old_pid, tries - 1)
    end
  end
end
