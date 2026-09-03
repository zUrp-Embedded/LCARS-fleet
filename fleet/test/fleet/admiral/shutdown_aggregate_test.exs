defmodule Fleet.Admiral.Shutdown.AggregateDispatcherTest do
  @moduledoc """
  REAL backend of the `:shutdown_dispatcher` seam. async: false: `refuse_new_jobs` mutates the global
  `Fleet.Shutdown.Quiesce` flag (on_exit `resume!` mandatory).

  CI-02: the drain count is now `TaskQueue.list_active/0` (queued + worked work-items — residents with
  NO active work-item are inherently excluded) + the completion offloads (seam `:completion_inflight_fun`),
  NOT a live-pod scan. Fail-closed on the broker (present-but-unreachable → sentinel > 0), honest 0 on a
  dead completion supervisor (its Tasks are already dead).
  """
  use ExUnit.Case, async: false
  import Fleet.Test.Barrier, only: [settle: 1]

  alias Fleet.Admiral.Shutdown.AggregateDispatcher
  alias Fleet.Shutdown.Quiesce

  # Broker stubs injected via `:lcars_fleet, :admiral_task_queue_mod`. The REAL broker IS present in the test
  # env (so `task_queue_running?` is true) — these induce specific `list_active` returns/failures.
  defmodule TwoActiveBroker do
    def list_active, do: [%{id: "a"}, %{id: "b"}]
  end

  defmodule EmptyBroker do
    def list_active, do: []
  end

  defmodule RaisingBroker do
    def list_active, do: raise("broker unreachable (test)")
  end

  defmodule ExitingBroker do
    def list_active, do: exit(:noproc)
  end

  setup do
    on_exit(&Quiesce.resume!/0)
    :ok
  end

  defp inject_broker(mod),
    do: Fleet.TestEnv.put_env_restoring(:lcars_fleet, :admiral_task_queue_mod, mod)

  defp inject_completion(fun),
    do: Fleet.TestEnv.put_env_restoring(:lcars_fleet, :admiral_completion_inflight_fun, fun)

  # ⚠ CE QUE CE FICHIER PEUT ASSERTER EST UNE CONTRIBUTION, JAMAIS UN TOTAL.
  #
  # `in_flight_count/0` somme TROIS termes : le broker et les complétions, que ces tests injectent —
  # et `Quiesce.busy_count/0`, qu'ils ne contrôlent pas. Ce troisième est un compteur `:atomics`
  # GLOBAL au nœud, incrémenté par `busy/1` et décrémenté dans son `after`. Un processus TUÉ saute
  # l'`after` : le compteur garde son +1 pour tout le reste du run, définitivement.
  #
  # `async: false` n'y change rien — les porteurs de `busy/1` sont des GenServers de longue vie
  # (`StepRunConsumer`, `Poller`) qui survivent aux suites qui les ont démarrés. Comparer à une
  # valeur ABSOLUE, c'est supposer que la machine est vierge, et ce fichier a rougi trois fois le
  # 2026-08-21 pour cette seule raison.
  #
  # Les deux lectures sont ADJACENTES pour que la fenêtre entre elles soit la plus courte possible :
  # ce qui doit être neutralisé est un décalage PERMANENT, pas une course.
  defp controlled_in_flight do
    total = AggregateDispatcher.in_flight_count()
    total - Quiesce.busy_count()
  end

  test "refuse_new_jobs/1 activates quiescence" do
    Quiesce.resume!()
    refute Quiesce.quiescing?()
    assert :ok = AggregateDispatcher.refuse_new_jobs(reason: :shutdown)
    assert Quiesce.quiescing?()
  end

  test "in_flight_count/0 = active work-items + completion offloads (work-items, NEVER a pod scan → residents excluded)" do
    # The count is the broker's ACTIVE work-items, not live pods: a resident arch/pipe-eng (no active
    # work-item) is inherently absent — the CI-02 fix for "one open project ⇒ in_flight > 0 forever".
    inject_broker(TwoActiveBroker)
    inject_completion(fn -> 3 end)
    assert controlled_in_flight() == 5
  end

  test "in_flight_count/0 also sums the synchronous finalizers inside Quiesce.busy/1" do
    # A poller tick's merge or a completion handler pre-offload is neither a work-item
    # nor an offload: without this term, three zero reads could conclude :drained while
    # a merge was in flight inside a singleton.
    inject_broker(EmptyBroker)
    inject_completion(fn -> 0 end)

    # LE DELTA EST LE FAIT : `busy/1` ajoute EXACTEMENT un, et le rend en sortant. Un total absolu
    # dirait la meme chose sur une machine vierge et mentirait sur toutes les autres.
    base = AggregateDispatcher.in_flight_count()

    Quiesce.busy(fn ->
      assert AggregateDispatcher.in_flight_count() == base + 1
    end)

    assert AggregateDispatcher.in_flight_count() == base
    assert controlled_in_flight() == 0
  end

  test "list_active that RAISES → in_flight_count > 0 (fail-closed: broker present but unreachable)" do
    inject_broker(RaisingBroker)
    inject_completion(fn -> 0 end)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "list_active that EXITs (:noproc) → in_flight_count > 0 (no undercount)" do
    inject_broker(ExitingBroker)
    inject_completion(fn -> 0 end)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "completion count 0 (supervisor genuinely absent) → contributes an honest 0" do
    # The kept asymmetry: a DOWN completion supervisor ⇒ its Tasks are dead with it ⇒ honest 0 (the seam
    # returns 0), so step-off does not make every stop time out.
    inject_broker(EmptyBroker)
    inject_completion(fn -> 0 end)
    assert controlled_in_flight() == 0
  end

  test "completion count that RAISES → in_flight_count > 0 (fail-closed: present-but-uncountable, not a fake 0)" do
    # A RAISING count is NOT a dead supervisor: the Tasks may be alive (completions mid-push) and we just
    # could not count them → fail-closed, never a fake 0 that would cut a live completion.
    inject_broker(EmptyBroker)
    inject_completion(fn -> raise "count boom" end)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "completion count :unknown (supervisor present but uncountable) → in_flight_count > 0 (fail-closed)" do
    inject_broker(EmptyBroker)
    inject_completion(fn -> :unknown end)
    assert AggregateDispatcher.in_flight_count() > 0
  end

  test "drain with a RAISING broker → does NOT conclude :drained (fail-closed sentinel → timeout)" do
    inject_broker(RaisingBroker)
    inject_completion(fn -> 0 end)
    name = :"sd_ci02_#{System.unique_integer([:positive])}"

    {:ok, _} =
      start_supervised(
        {Fleet.Admiral.Shutdown, name: name, dispatcher: AggregateDispatcher, poll_ms: 10}
      )

    assert :ok = Fleet.Admiral.Shutdown.drain_in_flight(name: name, grace_ms: 200)
    assert %{status: :timeout} = settle(name)
  end
end
