defmodule Fleet.Starfleet.BootOrchestratorTest do
  @moduledoc """
  B10/#583 Sprint 1 — BootOrchestrator pur (run/1 testable hors Task).
  `async: false` : subscribe Bus global singleton. boot_permanent_pods
  mocké via opt → preuve dispatch correct selon issue.
  """
  use ExUnit.Case, async: false

  alias Fleet.Starfleet.BootOrchestrator
  alias Fleet.EventRouter.Bus

  setup do
    :ok = Bus.subscribe()
    on_exit(fn -> Bus.unsubscribe() end)
    :ok
  end

  test "boot OK (liste de :ok) → broadcast fleet.boot_complete" do
    BootOrchestrator.run(boot_permanent_pods: fn -> [{:ok, :pod1}, {:ok, :pod2}] end)

    assert_receive %Fleet.Event{
                     source: :starfleet,
                     type: :"fleet.boot_complete",
                     payload: %{"permanent_pods" => 2}
                   },
                   1_000
  end

  test "R2-14 : boot_fn qui EXIT → boot_failed (Task :transient PAS crashée → pas de reboot loop)" do
    # un boot_fn qui exit (ex. GenServer.call vers un process mort) échapperait au `rescue` (exceptions
    # seulement) → exit anormal du Task :transient → restart → reboot loop. Le `catch` le classe :failed.
    assert :ok = BootOrchestrator.run(boot_permanent_pods: fn -> exit(:simulated_boot_crash) end)

    assert_receive %Fleet.Event{source: :starfleet, type: :"fleet.boot_failed"}, 1_000
  end

  test "R2-14 : boot_fn qui THROW → boot_failed (idem exit)" do
    assert :ok = BootOrchestrator.run(boot_permanent_pods: fn -> throw(:simulated_throw) end)

    assert_receive %Fleet.Event{source: :starfleet, type: :"fleet.boot_failed"}, 1_000
  end

  test "BL-028 : boot_permanent désactivé → boot_complete avec 0 pod, boot_fn PAS appelé" do
    parent = self()

    BootOrchestrator.run(
      boot_permanent_enabled: false,
      boot_permanent_pods: fn ->
        send(parent, :boot_fn_called)
        [{:ok, :pod1}]
      end
    )

    assert_receive %Fleet.Event{
                     source: :starfleet,
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
                     source: :starfleet,
                     type: :"fleet.boot_partial",
                     payload: %{"permanent_pods" => 2, "failed_pods" => failed}
                   },
                   1_000

    assert is_list(failed) and length(failed) == 1
  end

  test "élément malformé (ni :ok ni :error) → boot_partial, PAS boot_complete (finding Vulcan)" do
    BootOrchestrator.run(boot_permanent_pods: fn -> [{:ok, :pod1}, :garbage] end)

    assert_receive %Fleet.Event{
                     source: :starfleet,
                     type: :"fleet.boot_partial",
                     payload: %{"permanent_pods" => 1, "failed_pods" => failed}
                   },
                   1_000

    assert is_list(failed) and length(failed) == 1
  end

  test "boot raise → broadcast fleet.boot_failed (daemon reste up)" do
    BootOrchestrator.run(boot_permanent_pods: fn -> raise "boom" end)

    assert_receive %Fleet.Event{
                     source: :starfleet,
                     type: :"fleet.boot_failed",
                     payload: %{"reason" => reason}
                   },
                   1_000

    assert reason =~ "boom"
  end

  test "boot {:error, reason} → fleet.boot_failed" do
    BootOrchestrator.run(boot_permanent_pods: fn -> {:error, :enoent} end)

    assert_receive %Fleet.Event{
                     source: :starfleet,
                     type: :"fleet.boot_failed",
                     payload: %{"reason" => r}
                   },
                   1_000

    assert r =~ "enoent"
  end
end
