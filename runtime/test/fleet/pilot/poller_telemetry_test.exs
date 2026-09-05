defmodule Fleet.Pilot.PollerTelemetryTest do
  # async: false — `:telemetry.attach` is a NODE-GLOBAL registration; two of these running
  # concurrently would fight over the same handler id.
  use ExUnit.Case, async: false

  @moduledoc """
  BL-6-40 Phase 0 — the poller emitted `[:lcars_fleet, :pilot_poller, :poll]` from three sites and
  nothing in `lib/` ever attached: every measurement computed, then dropped.

  What these tests pin is not "the numbers are right" but the three properties that make the
  instrument survivable in the poller's own process: a nominal tick stays SILENT (the observed
  module removed that noise deliberately), a raising handler would be detached by telemetry for
  the lifetime of the node, and the summary must describe the WINDOW rather than all time.
  """

  alias Fleet.Pilot.PollerTelemetry

  @event [:lcars_fleet, :pilot_poller, :poll]

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

    # The warning names the leads that exist TODAY (the resolver's ls-remote, the per-tick
    # list_pods, the forge listings): a slow tick with no lead is a fact nobody can act on.
    assert log =~ "ls-remote"
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

  describe "l'echelle du CYCLE, distincte de celle du depot" do
    # Ce bloc existe parce que la confusion a REELLEMENT eu lieu : `[:poller, :poll]` est emis par
    # DEPOT, la clef de readiness qui l'exposait s'appelait `tick`, et une mesure a ete lue comme
    # une duree de passage. Ces tests tombent si les deux echelles se remelangent.
    @cycle [:lcars_fleet, :pilot_poller, :cycle]

    defp emit_cycle(duration_ms, repos, meta \\ %{status: :ok, mode: :tick}) do
      :telemetry.execute(@cycle, %{duration_ms: duration_ms, repos: repos}, meta)
      PollerTelemetry.cycle_stats()
    end

    test "avant le premier passage, la reponse honnete est :no_data" do
      assert :no_data = PollerTelemetry.cycle_stats()
    end

    test "DES POLLS DE DEPOT NE FONT PAS UN CYCLE — c'est tout l'objet de la separation" do
      # Le specimen exact du defaut : douze depots replies dans UN passage. Si les deux echelles
      # partageaient un anneau, `cycle_stats` rendrait douze entrees de 80 ms et un operateur
      # lirait « un passage coute 80 ms » alors qu'il en coute 960.
      for _ <- 1..12, do: emit(80)

      assert %{count: 12} = PollerTelemetry.stats()
      assert :no_data = PollerTelemetry.cycle_stats()

      assert %{count: 1, last_ms: 960, last_repos: 12} = emit_cycle(960, 12)
      # Et le passage n'a pas pollue l'anneau des depots.
      assert %{count: 12} = PollerTelemetry.stats()
    end

    test "le nombre de depots voyage AVEC la duree — sinon le chiffre n'est pas lisible" do
      # Une duree de passage sans la taille de l'org qui l'a produite ne dit rien : 900 ms sur
      # 2 depots est une alerte, sur 300 depots c'est nominal.
      assert %{last_ms: 150, last_repos: 2} = emit_cycle(150, 2)
      assert %{last_ms: 900, last_repos: 60} = emit_cycle(900, 60)
    end

    test "un passage qui echoue a la decouverte est COMPTE, avec zero depot replie" do
      # L'omettre embellirait le p95 exactement sur le cas qu'un operateur surveille.
      stats = emit_cycle(4_000, 0, %{status: :error, mode: :tick})

      assert %{count: 1, errors: 1, last_repos: 0, max_ms: 4_000} = stats
    end

    test "un passage LONG ne warn PAS — le seuil est calibre sur un depot, pas sur R" do
      # Decision deliberee, pas un oubli : reutiliser `slow_tick_ms` (500 ms ici) ferait crier a
      # chaque passage des que l'org depasse quelques depots. On mesure sans alerter plutot que
      # d'alerter sur un seuil invente.
      log = ExUnit.CaptureLog.capture_log(fn -> emit_cycle(30_000, 40) end)

      assert log == ""
      assert %{count: 1, max_ms: 30_000} = PollerTelemetry.cycle_stats()
    end
  end
end
