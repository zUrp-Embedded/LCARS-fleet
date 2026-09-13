defmodule Fleet.Pilot.PollerTelemetryTest do
  # async: false — `:telemetry.attach` is a NODE-GLOBAL registration; two of these running
  # concurrently would fight over the same handler id.
  use ExUnit.Case, async: false

  @moduledoc """
  Checks telemetry attachment, quiet nominal samples, rolling summaries and mailbox
  alerts. Events are emitted directly; these tests do not verify every Poller
  emission site or arbitrarily malformed measurement values.
  """

  alias Fleet.Pilot.PollerTelemetry

  @event [:lcars_fleet, :pilot_poller, :poll]

  setup do
    start_supervised!({PollerTelemetry, slow_tick_ms: 500})
    :ok
  end

  # The handler casts from this emitter process; the following call from the same
  # sender is a barrier for its preceding casts.
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

    # Pin the warning's diagnostic text; this does not establish the measured cause.
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
    # Window eviction must keep recent samples, while total count keeps growing.
    Enum.each(1..150, &:telemetry.execute(@event, %{duration_ms: &1}, %{status: :ok}))

    assert %{count: 150, window: 100, max_ms: 150, p50_ms: p50} = PollerTelemetry.stats()

    # Window = ticks 51..150 → the median sits at ~100, never at ~75 (which is the all-time value).
    assert p50 in 99..101
  end

  test "a malformed event does not kill the instrument — telemetry detaches a raising handler" do
    # Missing fields default to a recorded zero duration and ok status. This is not
    # rejection or totality for malformed field types.
    :telemetry.execute(@event, %{}, %{})

    assert %{count: 1, last_ms: 0} = PollerTelemetry.stats()
    assert [_] = :telemetry.list_handlers(@event)

    # And it keeps working afterwards.
    assert %{count: 2, last_ms: 42} = emit(42)
  end

  describe "jauge de mailbox (cousin BL-6-40)" do
    test "stats/0 porte la longueur de mailbox des deux singletons du rail" do
      # Absent watched processes must be omitted, not reported with zero backlog.
      emit(10)
      assert %{mailboxes: m} = PollerTelemetry.stats()
      assert m == %{}
    end

    test "un process observe SATURE declenche un warning au franchissement, une seule fois" do
      # Use a non-consuming process; an Agent would drain unknown messages and race
      # the backlog assertion.
      pid = spawn(fn -> Process.sleep(:infinity) end)
      true = Process.register(pid, Fleet.Pilot.Poller)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

      for _ <- 1..12, do: send(pid, :bourrage)

      log = ExUnit.CaptureLog.capture_log(fn -> emit(10) end)
      assert log =~ "mailbox de Fleet.Pilot.Poller"
      assert log =~ "prend du retard"

      # Continued backlog should not repeat the crossing warning.
      log2 = ExUnit.CaptureLog.capture_log(fn -> emit(10) end)
      refute log2 =~ "prend du retard"
    end
  end

  describe "l'echelle du CYCLE, distincte de celle du depot" do
    # Keep repository events and cycle events in separate distributions.
    @cycle [:lcars_fleet, :pilot_poller, :cycle]

    defp emit_cycle(duration_ms, repos, meta \\ %{status: :ok, mode: :tick}) do
      :telemetry.execute(@cycle, %{duration_ms: duration_ms, repos: repos}, meta)
      PollerTelemetry.cycle_stats()
    end

    defp emit_cycle_served(duration_ms, repos, served) do
      :telemetry.execute(
        @cycle,
        %{duration_ms: duration_ms, repos: repos, served: served},
        %{status: :ok, mode: :tick}
      )

      PollerTelemetry.cycle_stats()
    end

    test "le compte des SERVIS voyage de l'emission jusqu'a `cycle_stats`" do
      # Preserve served for the readiness predicate; it is supplied by the emitter.
      assert %{last_repos: 12, last_served: 3} = emit_cycle_served(200, 12, 3)
      assert %{last_repos: 4, last_served: 0} = emit_cycle_served(200, 4, 0)
    end

    test "une mesure SANS `served` rend `nil`, jamais 0 — l'inconnu n'accuse pas" do
      # Missing served is unknown, not evidence that no repository was served.
      assert %{last_repos: 12, last_served: nil} = emit_cycle(200, 12)
    end

    test "avant le premier passage, la reponse honnete est :no_data" do
      assert :no_data = PollerTelemetry.cycle_stats()
    end

    test "DES POLLS DE DEPOT NE FONT PAS UN CYCLE — c'est tout l'objet de la separation" do
      # Repository samples must not populate the cycle window.
      for _ <- 1..12, do: emit(80)

      assert %{count: 12} = PollerTelemetry.stats()
      assert :no_data = PollerTelemetry.cycle_stats()

      assert %{count: 1, last_ms: 960, last_repos: 12} = emit_cycle(960, 12)
      # Et le passage n'a pas pollue l'anneau des depots.
      assert %{count: 12} = PollerTelemetry.stats()
    end

    test "le nombre de depots voyage AVEC la duree — sinon le chiffre n'est pas lisible" do
      # Carry repository count so duration retains its workload context.
      assert %{last_ms: 150, last_repos: 2} = emit_cycle(150, 2)
      assert %{last_ms: 900, last_repos: 60} = emit_cycle(900, 60)
    end

    test "un passage qui echoue a la decouverte est COMPTE, avec zero depot replie" do
      # L'omettre embellirait le p95 exactement sur le cas qu'un operateur surveille.
      stats = emit_cycle(4_000, 0, %{status: :error, mode: :tick})

      assert %{count: 1, errors: 1, last_repos: 0, max_ms: 4_000} = stats
    end

    test "un passage LONG ne warn PAS — le seuil est calibre sur un depot, pas sur R" do
      # Cycle duration must not reuse the threshold for a single poll sample.
      log = ExUnit.CaptureLog.capture_log(fn -> emit_cycle(30_000, 40) end)

      assert log == ""
      assert %{count: 1, max_ms: 30_000} = PollerTelemetry.cycle_stats()
    end
  end
end
