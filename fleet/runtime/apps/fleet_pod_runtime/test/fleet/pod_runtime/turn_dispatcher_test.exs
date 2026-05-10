defmodule Fleet.PodRuntime.TurnDispatcherTest do
  use ExUnit.Case, async: false

  alias Fleet.PodRuntime.TurnDispatcher
  alias Fleet.PodRuntime.StubBackends

  setup do
    original_backend = Application.get_env(:fleet_pod_runtime, :port_backend)
    original_target = Application.get_env(:fleet_pod_runtime, :port_capture_target)

    Application.put_env(:fleet_pod_runtime, :port_backend, StubBackends.PortCapture)
    Application.put_env(:fleet_pod_runtime, :port_capture_target, self())

    on_exit(fn ->
      restore(:port_backend, original_backend)
      restore(:port_capture_target, original_target)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fleet_pod_runtime, key)
  defp restore(key, value), do: Application.put_env(:fleet_pod_runtime, key, value)

  defp start_dispatcher(opts \\ []) do
    opts = Keyword.put_new(opts, :port_ref, :fake_port)
    {:ok, pid} = TurnDispatcher.start_link(opts)
    pid
  end

  describe "start_link/1 + init/1" do
    test "init :idle avec queue vide" do
      pid = start_dispatcher()
      state = TurnDispatcher.state(pid)
      assert state.status == :idle
      assert :queue.is_empty(state.queue)
      assert state.current_turn_id == nil
    end

    test "raise si :port_ref manquant" do
      Process.flag(:trap_exit, true)
      assert {:error, _} = TurnDispatcher.start_link(port_backend: StubBackends.PortCapture)
    end
  end

  describe "dispatch/2 — état :idle" do
    test "1er dispatch écrit Port + retourne {:ok, turn_id} + status :awaiting_result" do
      pid = start_dispatcher()
      assert {:ok, turn_id} = TurnDispatcher.dispatch(pid, %{"text" => "hello"})
      assert is_binary(turn_id)
      assert String.starts_with?(turn_id, "turn-")

      assert_received {:port_write, payload}
      assert {:ok, decoded} = Jason.decode(payload)
      assert decoded["turn_id"] == turn_id
      assert decoded["text"] == "hello"

      state = TurnDispatcher.state(pid)
      assert state.status == :awaiting_result
      assert state.current_turn_id == turn_id
    end
  end

  describe "dispatch/2 — état :awaiting_result (queue+ack PoC-20)" do
    test "dispatch en rafale enqueue les messages au lieu de les perdre" do
      pid = start_dispatcher()
      assert {:ok, _t1} = TurnDispatcher.dispatch(pid, %{"text" => "msg1"})
      assert {:ok, t2, :pending} = TurnDispatcher.dispatch(pid, %{"text" => "msg2"})
      assert {:ok, t3, :pending} = TurnDispatcher.dispatch(pid, %{"text" => "msg3"})

      assert_received {:port_write, _msg1_payload}

      state = TurnDispatcher.state(pid)
      assert state.status == :awaiting_result
      assert :queue.len(state.queue) == 2
      [{queued_t2, _}, {queued_t3, _}] = :queue.to_list(state.queue)
      assert queued_t2 == t2
      assert queued_t3 == t3
    end
  end

  describe "result_received/3 — ack + dequeue" do
    test "ack du turn courant transitionne :idle si queue vide" do
      pid = start_dispatcher()
      {:ok, turn_id} = TurnDispatcher.dispatch(pid, %{"text" => "msg"})
      :ok = TurnDispatcher.result_received(pid, turn_id, %{"result" => "ok"})
      Process.sleep(10)

      state = TurnDispatcher.state(pid)
      assert state.status == :idle
      assert state.current_turn_id == nil
    end

    test "ack avec queue non-vide dispatch le suivant + reste :awaiting_result" do
      pid = start_dispatcher()
      {:ok, t1} = TurnDispatcher.dispatch(pid, %{"text" => "msg1"})
      {:ok, t2, :pending} = TurnDispatcher.dispatch(pid, %{"text" => "msg2"})
      assert_received {:port_write, _msg1_payload}

      :ok = TurnDispatcher.result_received(pid, t1, %{"result" => "ok"})
      Process.sleep(10)

      assert_received {:port_write, msg2_payload}
      assert {:ok, decoded} = Jason.decode(msg2_payload)
      assert decoded["turn_id"] == t2

      state = TurnDispatcher.state(pid)
      assert state.status == :awaiting_result
      assert state.current_turn_id == t2
      assert :queue.is_empty(state.queue)
    end

    test "ack d'un turn_id qui ne correspond pas au current → no-op" do
      pid = start_dispatcher()
      {:ok, _t1} = TurnDispatcher.dispatch(pid, %{"text" => "msg"})
      :ok = TurnDispatcher.result_received(pid, "turn-bogus", %{"result" => "ok"})
      Process.sleep(10)

      state = TurnDispatcher.state(pid)
      assert state.status == :awaiting_result
    end
  end

  describe "PoC-20 reproduction — pas de perte multi-message" do
    test "5 dispatches en rafale → 1 write immédiat + 4 enqueued, drain via 5 acks successifs" do
      pid = start_dispatcher()

      ids =
        for i <- 1..5 do
          case TurnDispatcher.dispatch(pid, %{"text" => "msg#{i}"}) do
            {:ok, id} -> id
            {:ok, id, :pending} -> id
          end
        end

      assert length(ids) == 5
      assert_received {:port_write, _first_payload}
      state = TurnDispatcher.state(pid)
      assert :queue.len(state.queue) == 4

      Enum.each(ids, fn id ->
        :ok = TurnDispatcher.result_received(pid, id, %{"result" => "ok"})
        Process.sleep(5)
      end)

      dequeue_writes = collect_port_writes()
      assert length(dequeue_writes) == 4

      dequeue_ids =
        Enum.map(dequeue_writes, fn payload ->
          {:ok, decoded} = Jason.decode(payload)
          decoded["turn_id"]
        end)

      assert dequeue_ids == Enum.drop(ids, 1)
    end
  end

  describe "erreurs Port backend" do
    test "1er dispatch backend write fails → reply {:error, _} + state :idle" do
      Application.put_env(:fleet_pod_runtime, :port_backend, StubBackends.PortFailing)
      pid = start_dispatcher()

      assert {:error, :stub_port_fail} = TurnDispatcher.dispatch(pid, %{"text" => "msg"})
      state = TurnDispatcher.state(pid)
      assert state.status == :idle
    end

    test "F-MIN-3 — write-fail post-ack re-enqueue head + reste recoverable" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      Application.put_env(:fleet_pod_runtime, :flaky_counter_pid, counter)
      Application.put_env(:fleet_pod_runtime, :flaky_n, 1)
      Application.put_env(:fleet_pod_runtime, :port_backend, StubBackends.PortFlakyAfterN)

      on_exit(fn ->
        if Process.alive?(counter), do: Agent.stop(counter)
        Application.delete_env(:fleet_pod_runtime, :flaky_counter_pid)
        Application.delete_env(:fleet_pod_runtime, :flaky_n)
      end)

      pid = start_dispatcher()
      {:ok, t1} = TurnDispatcher.dispatch(pid, %{"text" => "msg1"})
      {:ok, t2, :pending} = TurnDispatcher.dispatch(pid, %{"text" => "msg2"})
      assert_received {:port_write, _msg1}

      :ok = TurnDispatcher.result_received(pid, t1, %{"result" => "ok"})
      Process.sleep(20)

      state = TurnDispatcher.state(pid)
      assert state.status == :idle
      assert state.current_turn_id == nil
      assert :queue.len(state.queue) == 1

      [{requeued_id, requeued_msg}] = :queue.to_list(state.queue)
      assert requeued_id == t2
      assert requeued_msg == %{"text" => "msg2"}
    end
  end

  defp collect_port_writes(acc \\ []) do
    receive do
      {:port_write, payload} -> collect_port_writes([payload | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end
end
