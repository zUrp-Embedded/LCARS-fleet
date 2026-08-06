defmodule Fleet.Pilot.OffloadTest do
  @moduledoc """
  The offloaded task's DEATH is observed: the monitor is created in the
  CALLING consumer, the `:DOWN` is routed to `handle_down/3`, and a mid-work death leaves the LOUD
  trace this mechanism exists for — before it, the consumer's catch-all swallowed the only witness
  of a lost completion.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Offload

  setup do
    sup =
      start_supervised!(
        {Task.Supervisor, name: :"offload_sup_#{System.unique_integer([:positive])}"}
      )

    %{sup: sup}
  end

  defp sup_name(sup), do: sup |> Process.info(:registered_name) |> elem(1)

  test "a task that DIES mid-work → :DOWN routed, LOUD error naming consumer + consequence", %{
    sup: sup
  } do
    test = self()

    # Go-signal (same rationale as the NORMALLY test below): the task waits before dying, so the
    # monitor is attached deterministically and the :DOWN carries :boom, never a racy :noproc.
    {:ok, :offloaded} =
      Offload.async(
        sup_name(sup),
        fn ->
          send(test, {:task_pid, self()})

          receive do
            :go -> exit(:boom)
          end
        end,
        {"StepRunConsumer", "completion lost"}
      )

    assert_receive {:task_pid, task_pid}, 1_000
    send(task_pid, :go)
    assert_receive {:DOWN, ref, :process, pid, :boom}, 1_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # 2-tuple label → empty meta (the meta-less consumers keep their shape).
        assert {:handled, {:died, :boom, %{}}} = Offload.handle_down(ref, pid, :boom)
      end)

    assert log =~ "StepRunConsumer"
    assert log =~ "DIED mid-work"
    assert log =~ "completion lost"

    # The label entry is CONSUMED at :DOWN (no pdict leak): a replay is no longer ours.
    assert :not_mine = Offload.handle_down(ref, pid, :boom)
  end

  test "a 3-tuple label hands its META back on an abnormal death (BL-6-03 S2)", %{sup: sup} do
    test = self()

    {:ok, :offloaded} =
      Offload.async(
        sup_name(sup),
        fn ->
          send(test, {:task_pid, self()})

          receive do
            :go -> exit(:boom)
          end
        end,
        {"StepRunConsumer", "completion lost", %{pod_id: "pod-x", issue: 7}}
      )

    assert_receive {:task_pid, task_pid}, 1_000
    send(task_pid, :go)
    assert_receive {:DOWN, ref, :process, pid, :boom}, 1_000

    ExUnit.CaptureLog.capture_log(fn ->
      # The consumer gets the business context back — the pod whose confirmation will never come.
      assert {:handled, {:died, :boom, %{pod_id: "pod-x", issue: 7}}} =
               Offload.handle_down(ref, pid, :boom)
    end)
  end

  test "a task that ends NORMALLY → :DOWN routed silently (nominal end, entry consumed)", %{
    sup: sup
  } do
    test = self()

    # The task waits for the go-signal: the monitor is attached BEFORE it can finish, so the
    # :DOWN carries :normal deterministically (a free-running fn -> :ok can beat the monitor
    # and yield :noproc — the fast-exit case, covered below).
    {:ok, :offloaded} =
      Offload.async(
        sup_name(sup),
        fn ->
          receive do
            :go -> :ok
          end
        end,
        {"C", "x"}
      )
      |> tap(fn _ ->
        send(test, :armed)
      end)

    assert_receive :armed, 1_000
    # Find the task pid via the :DOWN after releasing it — release EVERY task child.
    for {_, child, _, _} <-
          Task.Supervisor.children(sup_name(sup)) |> Enum.map(&{nil, &1, nil, nil}),
        is_pid(child),
        do: send(child, :go)

    assert_receive {:DOWN, ref, :process, pid, :normal}, 1_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:handled, :nominal} = Offload.handle_down(ref, pid, :normal)
      end)

    refute log =~ "DIED"
  end

  test "a task faster than the monitor (:noproc) → LOUD mid-work DIED error, never silent", %{
    sup: _
  } do
    ref = make_ref()
    pid = spawn(fn -> :ok end)
    Process.put({Fleet.Pilot.Offload, ref}, {"OffloadConsumer", "work lost"})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:handled, {:died, :noproc, %{}}} = Offload.handle_down(ref, pid, :noproc)
      end)

    assert log =~ "DIED mid-work"
    assert log =~ ":noproc"
    assert log =~ "work lost"
    # The label entry is consumed: a second call is not ours.
    assert :not_mine = Offload.handle_down(ref, pid, :noproc)
  end

  describe "async_or_inline — saturation runs the work, never drops it" do
    test "offload REFUSED (max_children 0) → the work runs INLINE, {:ok, :inline}" do
      # A saturated pool was the exact hole: the completion was dropped with a log — the ONE
      # moment (burst) where losing work hurts most. The shared policy runs it inline instead.
      sup =
        start_supervised!(
          Supervisor.child_spec(
            {Task.Supervisor,
             name: :"sat_sup_#{System.unique_integer([:positive])}", max_children: 0},
            id: :sat
          )
        )

      test = self()

      assert {:ok, :inline} =
               Fleet.Pilot.Offload.async_or_inline(
                 sup_name(sup),
                 fn -> send(test, :ran_inline) end,
                 {"StepRunConsumer", "completion lost"}
               )

      assert_received :ran_inline
    end

    test "inline fallback CRASHES → typed {:error, :inline_crashed} + LOUD, the caller survives" do
      sup =
        start_supervised!(
          Supervisor.child_spec(
            {Task.Supervisor,
             name: :"sat2_#{System.unique_integer([:positive])}", max_children: 0},
            id: :sat2
          )
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :inline_crashed} =
                   Fleet.Pilot.Offload.async_or_inline(
                     sup_name(sup),
                     fn -> raise "poison" end,
                     {"IncidentConsumer", "incident NOT recorded"}
                   )
        end)

      assert log =~ "INLINE fallback crashed"
      assert log =~ "incident NOT recorded"
    end

    test "inline fallback EXIT (exit/throw) → typed {:error, :inline_crashed} + LOUD, caller survives" do
      sup =
        start_supervised!(
          Supervisor.child_spec(
            {Task.Supervisor,
             name: :"sat3_#{System.unique_integer([:positive])}", max_children: 0},
            id: :sat3
          )
        )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :inline_crashed} =
                   Fleet.Pilot.Offload.async_or_inline(
                     sup_name(sup),
                     fn -> exit(:boom) end,
                     {"StepRunConsumer", "completion lost"}
                   )
        end)

      assert log =~ "INLINE fallback crashed"
      assert log =~ "completion lost"
    end

    test "pool available → offloaded normally ({:ok, :offloaded})", %{sup: _} = ctx do
      assert {:ok, :offloaded} =
               Fleet.Pilot.Offload.async_or_inline(sup_name(ctx.sup), fn -> :ok end, {"C", "x"})
    end
  end

  test "a :DOWN that is NOT an offloaded task → :not_mine (the consumer's catch-all takes over)" do
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert :not_mine = Offload.handle_down(ref, pid, :normal)
  end
end
