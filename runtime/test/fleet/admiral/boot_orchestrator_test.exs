defmodule Fleet.Admiral.BootOrchestratorTest do
  @moduledoc """
  Calls run directly with boot stubs and observes the real Bus. Checks outcome
  classification, not actual pod launches, daemon readiness or Task supervision.
  """
  use ExUnit.Case, async: false

  alias Fleet.Admiral.BootOrchestrator
  alias Fleet.EventRouter.Bus

  setup do
    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    :ok
  end

  test "boot OK (list of :ok) → broadcast fleet.boot_complete" do
    BootOrchestrator.run(boot_permanent_pods: fn -> [{:ok, :pod1}, {:ok, :pod2}] end)

    assert_receive %Fleet.Event{
                     source: :admiral,
                     type: :"fleet.boot_complete",
                     payload: %{"permanent_pods" => 2}
                   },
                   1_000
  end

  test "R2-14: boot_fn that EXITs → boot_failed (Task :transient NOT crashed → no reboot loop)" do
    # rescue alone misses exits; the boot wrapper must catch them as failed outcomes.
    assert :ok = BootOrchestrator.run(boot_permanent_pods: fn -> exit(:simulated_boot_crash) end)

    assert_receive %Fleet.Event{source: :admiral, type: :"fleet.boot_failed"}, 1_000
  end

  test "R2-14: boot_fn that THROWs → boot_failed (same as exit)" do
    assert :ok = BootOrchestrator.run(boot_permanent_pods: fn -> throw(:simulated_throw) end)

    assert_receive %Fleet.Event{source: :admiral, type: :"fleet.boot_failed"}, 1_000
  end

  test "BL-028: boot_permanent disabled → boot_complete with 0 pods, boot_fn NOT called" do
    parent = self()

    BootOrchestrator.run(
      boot_permanent_enabled: false,
      boot_permanent_pods: fn ->
        send(parent, :boot_fn_called)
        [{:ok, :pod1}]
      end
    )

    assert_receive %Fleet.Event{
                     source: :admiral,
                     type: :"fleet.boot_complete",
                     payload: %{"permanent_pods" => 0}
                   },
                   1_000

    refute_received :boot_fn_called
  end

  test "boot partial (mix :ok + :error) → broadcast fleet.boot_partial" do
    BootOrchestrator.run(
      boot_permanent_pods: fn -> [{:ok, :pod1}, {:error, :nope}, {:ok, :pod2}] end
    )

    assert_receive %Fleet.Event{
                     source: :admiral,
                     type: :"fleet.boot_partial",
                     payload: %{"permanent_pods" => 2, "failed_pods" => failed}
                   },
                   1_000

    assert is_list(failed) and length(failed) == 1
  end

  test "malformed element (neither :ok nor :error) → boot_partial, NOT boot_complete (Vulcan finding)" do
    BootOrchestrator.run(boot_permanent_pods: fn -> [{:ok, :pod1}, :garbage] end)

    assert_receive %Fleet.Event{
                     source: :admiral,
                     type: :"fleet.boot_partial",
                     payload: %{"permanent_pods" => 1, "failed_pods" => failed}
                   },
                   1_000

    assert is_list(failed) and length(failed) == 1
  end

  test "boot raise → broadcast fleet.boot_failed (daemon stays up)" do
    BootOrchestrator.run(boot_permanent_pods: fn -> raise "boom" end)

    assert_receive %Fleet.Event{
                     source: :admiral,
                     type: :"fleet.boot_failed",
                     payload: %{"reason" => reason}
                   },
                   1_000

    assert reason =~ "boom"
  end

  test "boot {:error, reason} → fleet.boot_failed" do
    BootOrchestrator.run(boot_permanent_pods: fn -> {:error, :enoent} end)

    assert_receive %Fleet.Event{
                     source: :admiral,
                     type: :"fleet.boot_failed",
                     payload: %{"reason" => r}
                   },
                   1_000

    assert r =~ "enoent"
  end
end
