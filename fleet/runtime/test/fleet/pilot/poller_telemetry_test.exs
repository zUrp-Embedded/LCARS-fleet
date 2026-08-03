defmodule Fleet.Pilot.PollerTelemetryTest do
  # async: false — `:telemetry.attach` is a NODE-GLOBAL registration; two of these running
  # concurrently would fight over the same handler id.
  use ExUnit.Case, async: false

  @moduledoc """
  BL-6-40 Phase 0 — the poller emitted `[:fleet_pilot, :poller, :poll]` from three sites and
  nothing in `lib/` ever attached: every measurement computed, then dropped.

  What these tests pin is not "the numbers are right" but the three properties that make the
  instrument survivable in the poller's own process: a nominal tick stays SILENT (the observed
  module removed that noise deliberately), a raising handler would be detached by telemetry for
  the lifetime of the node, and the summary must describe the WINDOW rather than all time.
  """

  alias Fleet.Pilot.PollerTelemetry

  @event [:fleet_pilot, :poller, :poll]

  setup do
    start_supervised!({PollerTelemetry, slow_tick_ms: 500})
    :ok
  end

  # The emission is a cast; `stats/0` is a call on the same process, so a completed call proves
  # every prior cast was handled (no sleep, no polling — mailbox ordering IS the barrier).
  defp emit(duration_ms, meta \\ %{status: :ok}) do
    :telemetry.execute(@event, %{duration_ms: duration_ms}, meta)
    PollerTelemetry.stats()
  end

  test "before the first tick, the honest answer is :no_data — never a zeroed summary" do
    assert :no_data = PollerTelemetry.stats()
  end

  test "a nominal tick is recorded and stays SILENT" do
    log = ExUnit.CaptureLog.capture_log(fn -> emit(80) end)

    assert log == ""
    assert %{count: 1, last_ms: 80, p50_ms: 80, max_ms: 80} = PollerTelemetry.stats()
  end

  test "a SLOW tick warns, and names what to look at" do
    log = ExUnit.CaptureLog.capture_log(fn -> emit(900, %{status: :ok, repo: "fleet/demo"}) end)

    assert log =~ "SLOW tick 900ms"
    assert log =~ "fleet/demo"

    # The warning carries the three amplifiers: a slow tick with no lead is a fact nobody can act on.
    assert log =~ "list_pods"
  end

  test "an error tick warns and is tallied BY SCOPE (discovery and per-repo are distinct paths)" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        emit(10, %{status: :error, scope: :repo_list, repo: "fleet/demo"})
        # The discovery path carries no `scope` key — it must not collapse into the same bucket.
        emit(10, %{status: :error, repo: "fleet/demo"})
      end)

    assert log =~ "tick in ERROR"
    assert %{errors: %{repo_list: 1, discovery: 1}} = PollerTelemetry.stats()
  end

  test "the summary describes the WINDOW, while count keeps the whole history" do
    # 150 ticks over a 100-wide window: the 50 first must fall out. An all-time average would hide
    # a rail that started degrading behind the thousands of fast ticks before it.
    Enum.each(1..150, &:telemetry.execute(@event, %{duration_ms: &1}, %{status: :ok}))

    assert %{count: 150, window: 100, max_ms: 150, p50_ms: p50} = PollerTelemetry.stats()

    # Window = ticks 51..150 → the median sits at ~100, never at ~75 (which is the all-time value).
    assert p50 in 99..101
  end

  test "a malformed event does not kill the instrument — telemetry detaches a raising handler" do
    # No `duration_ms`, no `status`: the shape a future emitter could get wrong. The contract is
    # that we lose ONE metric, never the attachment (a detached handler restores the blindness
    # silently, and later than the change that caused it).
    :telemetry.execute(@event, %{}, %{})

    assert %{count: 1, last_ms: 0} = PollerTelemetry.stats()
    assert [_] = :telemetry.list_handlers(@event)

    # And it keeps working afterwards.
    assert %{count: 2, last_ms: 42} = emit(42)
  end

  describe "jauge de mailbox (cousin BL-6-40)" do
    test "stats/0 porte la longueur de mailbox des deux singletons du rail" do
      # Le module s'echantillonne LUI-MEME quand il est le seul des trois a tourner ? Non : il
      # observe le Poller et le StepRunConsumer, absents ici — donc la carte est VIDE, et c'est le
      # comportement voulu. Un nom non enregistre sort de la mesure au lieu d'y entrer comme un
      # zero, qui ressemblerait a « sain ».
      emit(10)
      assert %{mailboxes: m} = PollerTelemetry.stats()
      assert m == %{}
    end

    test "un process observe SATURE declenche un warning au franchissement, une seule fois" do
      # Un process qui ne RECOIT JAMAIS : sa mailbox ne peut que croitre. Premiere version de ce
      # test : un `Agent`, qui DRAINE ses messages inconnus en les loggant — la mailbox se vidait,
      # le test passait en isolation et tombait au gate. Un test dont le verdict depend de qui a
      # draine en premier n'est pas un test, c'est un tirage.
      pid = spawn(fn -> Process.sleep(:infinity) end)
      true = Process.register(pid, Fleet.Pilot.Poller)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      for _ <- 1..12, do: send(pid, :bourrage)

      log = ExUnit.CaptureLog.capture_log(fn -> emit(10) end)
      assert log =~ "mailbox de Fleet.Pilot.Poller"
      assert log =~ "prend du retard"

      # Deuxieme tick au-dessus du seuil : SILENCE. Repeter le meme fait toutes les 30 s noierait
      # la trace — meme discipline que le silence du tick nominal.
      log2 = ExUnit.CaptureLog.capture_log(fn -> emit(10) end)
      refute log2 =~ "prend du retard"
    end
  end
end
