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

    {:ok, :offloaded} =
      Offload.async(
        sup_name(sup),
        fn ->
          send(test, :task_started)
          exit(:boom)
        end,
        {"StepRunConsumer", "completion lost"}
      )

    assert_receive :task_started, 1_000
    assert_receive {:DOWN, ref, :process, pid, :boom}, 1_000

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :handled = Offload.handle_down(ref, pid, :boom)
      end)

    assert log =~ "StepRunConsumer"
    assert log =~ "DIED mid-work"
    assert log =~ "completion lost"

    # The label entry is CONSUMED at :DOWN (no pdict leak): a replay is no longer ours.
    assert :not_mine = Offload.handle_down(ref, pid, :boom)
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
        assert :handled = Offload.handle_down(ref, pid, :normal)
      end)

    refute log =~ "DIED"
  end

  test "a task faster than the monitor (:noproc) → silent nominal, never a false DIED alarm", %{
    sup: sup
  } do
    {:ok, :offloaded} = Offload.async(sup_name(sup), fn -> :ok end, {"C", "x"})
    assert_receive {:DOWN, ref, :process, pid, reason}, 1_000
    assert reason in [:normal, :noproc]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :handled = Offload.handle_down(ref, pid, reason)
      end)

    refute log =~ "DIED"
  end

  test "a :DOWN that is NOT an offloaded task → :not_mine (the consumer's catch-all takes over)" do
    {pid, ref} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    assert :not_mine = Offload.handle_down(ref, pid, :normal)
  end
end
