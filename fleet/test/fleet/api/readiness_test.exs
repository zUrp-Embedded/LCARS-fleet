defmodule Fleet.API.ReadinessTest do
  # async: false — the probes read the global Application config; some tests
  # mutate it via put_env (then restore). Serializing avoids cross-test
  # pollution (same reason as RestTest).
  use ExUnit.Case, async: false

  alias Fleet.API.Readiness

  @mutated [
    {:lcars_fleet, :admiral_shutdown_dispatcher},
    {:lcars_fleet, :spawner_launch_backend}
  ]

  setup do
    # Snapshot of the mutated keys to restore the exact test ambient (e.g.
    # launch_backend=StubBackend set by config/test.exs, must NOT be deleted).
    snapshot =
      Map.new(@mutated, fn {app, key} ->
        {{app, key}, Application.fetch_env(app, key)}
      end)

    on_exit(fn ->
      Enum.each(snapshot, fn
        {{app, key}, {:ok, val}} -> Application.put_env(app, key, val)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)
    end)

    :ok
  end

  defp sub(result, id), do: Enum.find(result.subsystems, &(&1.id == id))

  describe "deep/0 — shape" do
    test "global verdict + degraded list + 6 subsystems + ts" do
      assert %{status: status, degraded: degraded, subsystems: subsystems, ts: ts} =
               Readiness.deep()

      assert status in ["operational", "degraded"]
      assert is_list(degraded)

      # 6 subsystems: event.registry, shutdown.dispatcher, launch.backend, mcp.pod_facing,
      # pilot.step (forge-state-machine rail), + spawn.dispatch (PublishConsumer = the sole
      # subscriber of admin.spawn.request — the probe kills the hollow-green 202).
      # (coord.backend est parti avec Fleet.Coord — brouette 2026-08-19.)
      assert length(subsystems) == 6
      assert is_binary(ts)

      # each subsystem: id/state/detail, state within the vocabulary
      Enum.each(subsystems, fn s ->
        assert %{id: id, state: state, detail: detail} = s
        assert is_binary(id)
        assert state in [:operational, :inactive, :degraded]
        assert is_map(detail)
      end)
    end

    test "global verdict = degraded iff at least one :degraded subsystem" do
      result = Readiness.deep()
      any_degraded? = Enum.any?(result.subsystems, &(&1.state == :degraded))
      assert result.status == if(any_degraded?, do: "degraded", else: "operational")
      # the degraded list names exactly the :degraded subsystems
      assert result.degraded ==
               result.subsystems |> Enum.filter(&(&1.state == :degraded)) |> Enum.map(& &1.id)
    end
  end

  describe "shutdown.dispatcher" do
    test "degraded on NoOpDispatcher (Fleet.Dispatcher missing)" do
      Application.put_env(
        :lcars_fleet,
        :admiral_shutdown_dispatcher,
        Fleet.Admiral.Shutdown.NoOpDispatcher
      )

      assert %{state: :degraded, detail: %{backend: "NoOpDispatcher"}} =
               sub(Readiness.deep(), "shutdown.dispatcher")
    end

    test "operational when real backend wired" do
      # ⚠ CE TEST CABLAIT `Fleet.Coord`, SUPPRIME LE 2026-08-19 — et il passait quand meme, parce que
      # la sonde ne teste qu'une INEGALITE (`backend == NoOpDispatcher`, `readiness.ex:77`).
      # N'importe quel atome le rendait vert. Un test dont le nom promet « real backend wired » et
      # qui accepte un module inexistant ne prouve pas ce qu'il annonce.
      #
      # Le fichier le SAVAIT : il ecrit trente lignes plus haut « coord.backend est parti avec
      # Fleet.Coord — brouette 2026-08-19 », puis continuait de le cabler ici.
      #
      # Cable sur le vrai backend, et on assert le NOM en plus de l'etat : la sonde doit rapporter
      # CE QUI TOURNE, pas seulement « pas le NoOp ».
      Application.put_env(
        :lcars_fleet,
        :admiral_shutdown_dispatcher,
        Fleet.Admiral.Shutdown.AggregateDispatcher
      )

      assert %{state: :operational, detail: %{backend: backend}} =
               sub(Readiness.deep(), "shutdown.dispatcher")

      assert backend =~ "AggregateDispatcher"
    end

    @tag :skip
    test "un module INEXISTANT ne doit pas se lire comme operationnel — TROU CONNU" do
      # La contre-epreuve que le test ci-dessus laissait passer, ecrite et MARQUEE plutot
      # qu'omise : elle echoue aujourd'hui, parce que la sonde ne sait dire que « ce n'est pas le
      # NoOp ». Un trou nomme vaut mieux qu'un trou vert.
      #
      # Le geste qui la leverait est cote PRODUCTION (`readiness.ex:77`) : verifier que le backend
      # exporte le contrat attendu (`in_flight_count/0`, `refuse_new_jobs/1`) au lieu de le comparer
      # a un module. C'est un changement de sonde, pas de test — hors de ce lot.
      Application.put_env(:lcars_fleet, :admiral_shutdown_dispatcher, Fleet.NExistePas)
      assert %{state: :degraded} = sub(Readiness.deep(), "shutdown.dispatcher")
    end

    # Drift-kill: key unset → readiness reads the OWNER's canonical default
    # (`Fleet.Admiral.Shutdown.configured_dispatcher/0` → NoOpDispatcher), not a re-declared default.
    test "missing key → shared canonical default (NoOpDispatcher) → degraded" do
      Application.delete_env(:lcars_fleet, :admiral_shutdown_dispatcher)

      assert %{state: :degraded, detail: %{backend: "NoOpDispatcher"}} =
               sub(Readiness.deep(), "shutdown.dispatcher")

      assert Fleet.Admiral.Shutdown.configured_dispatcher() ==
               Fleet.Admiral.Shutdown.NoOpDispatcher
    end
  end

  describe "launch.backend" do
    test "degraded on StubBackend (inert)" do
      Application.put_env(
        :lcars_fleet,
        :spawner_launch_backend,
        Fleet.Spawner.LaunchBackend.StubBackend
      )

      assert %{state: :degraded, detail: %{backend: "StubBackend"}} =
               sub(Readiness.deep(), "launch.backend")
    end

    test "operational on real backend" do
      Application.put_env(
        :lcars_fleet,
        :spawner_launch_backend,
        Fleet.Spawner.LaunchBackend.LauncherPortBackend
      )

      assert %{state: :operational} = sub(Readiness.deep(), "launch.backend")
    end

    # Drift-kill: key unset → readiness reads the OWNER's canonical default
    # (`Fleet.Spawner.LaunchBackend.resolved/0` → LauncherPortBackend, which actually launches pods),
    # hence operational, NOT a phantom `:degraded` due to a `nil` or a stale re-copied default.
    test "missing key → shared canonical default (LauncherPortBackend) → operational" do
      Application.delete_env(:lcars_fleet, :spawner_launch_backend)

      assert %{state: :operational} = sub(Readiness.deep(), "launch.backend")

      assert Fleet.Spawner.LaunchBackend.resolved() ==
               Fleet.Spawner.LaunchBackend.LauncherPortBackend
    end
  end

  # describe "pilot.dispatcher" REMOVED (②.3 / BL-050): the probe was sensing the legacy AutoDispatcher, deleted.

  describe "event.registry (B2 — visible escape-hatch)" do
    test "degraded when registry empty (test ambient, load_event_registry false)" do
      assert %{state: :degraded, detail: %{authorized_types: 0}} =
               sub(Readiness.deep(), "event.registry")
    end
  end

  describe "mcp.pod_facing (probes the PROCESS — the socket-acceptor DynamicSupervisor)" do
    # Per-pod socket substrate alive (booted host-side in the umbrella) + spec injected INTO pods present
    # → operational. We set the spec (absent in ambient) to isolate this case.
    test "operational when the socket substrate runs AND mcp_server_spec present" do
      Application.put_env(:lcars_fleet, :spawner_mcp_server_spec, %{"some" => "spec"})
      on_exit(fn -> Application.delete_env(:lcars_fleet, :spawner_mcp_server_spec) end)

      assert %{state: :operational, detail: %{acceptor_supervisor: true}} =
               sub(Readiness.deep(), "mcp.pod_facing")
    end

    # Test ambient: substrate alive BUT mcp_server_spec absent (pods not wired) → the probe degrades
    # (anti-hollow-green: the substrate runs but nothing is injected into the pods).
    test "degraded when substrate alive but mcp_server_spec absent (pods not wired)" do
      Application.delete_env(:lcars_fleet, :spawner_mcp_server_spec)

      assert %{state: :degraded, detail: detail} = sub(Readiness.deep(), "mcp.pod_facing")
      assert detail.mcp_server_spec == false
      assert detail.note =~ "mcp_server_spec absent"
    end
  end

  describe "deep/1 — aggregation (injected probes)" do
    defp op(id), do: {id, fn -> %{id: id, state: :operational, detail: %{}} end}
    defp deg(id), do: {id, fn -> %{id: id, state: :degraded, detail: %{}} end}
    defp ina(id), do: {id, fn -> %{id: id, state: :inactive, detail: %{}} end}

    test "all operational (+ inactive) → status operational, degraded empty" do
      assert %{status: "operational", degraded: []} =
               Readiness.deep([op("a"), op("b"), ina("c")])
    end

    test "one degraded subsystem → status degraded, named in the list" do
      assert %{status: "degraded", degraded: ["b"]} =
               Readiness.deep([op("a"), deg("b"), ina("c")])
    end

    test "inactive alone does NOT degrade the global verdict (R21)" do
      assert %{status: "operational", degraded: []} = Readiness.deep([ina("a"), ina("b")])
    end

    test "crashing probe → degraded with preserved id + detail.error (safe_probe)" do
      probes = [op("a"), {"boom", fn -> raise "kaboom" end}]
      result = Readiness.deep(probes)

      assert %{status: "degraded", degraded: ["boom"]} = result
      assert %{state: :degraded, detail: %{error: msg}} = sub(result, "boom")
      assert msg =~ "kaboom"
    end
  end

  describe "spawn.dispatch (probes the PROCESS — the sole subscriber of admin.spawn.request)" do
    # The 202 of POST /api/admin/spawn lies when the PublishConsumer is off (lossy Bus →
    # broadcast lost → 0 pod) while /readiness/deep says operational — this probe kills that.
    test "degraded when PublishConsumer absent (start_publish_consumer off — test ambient)" do
      # config/test.exs sets start_publish_consumer=false → the consumer is never started.
      refute is_pid(Process.whereis(Fleet.Spawner.PublishConsumer))

      assert %{state: :degraded, detail: %{consumer: false}} =
               sub(Readiness.deep(), "spawn.dispatch")
    end

    test "operational when PublishConsumer alive AND subscribed" do
      start_supervised!({Fleet.Spawner.PublishConsumer, [subscribe: true]})

      assert %{state: :operational, detail: %{consumer: true, subscribed: true}} =
               sub(Readiness.deep(), "spawn.dispatch")
    end

    test "degraded when PublishConsumer alive but NOT subscribed (subscribe:false seam)" do
      start_supervised!({Fleet.Spawner.PublishConsumer, [subscribe: false]})

      assert %{state: :degraded, detail: %{consumer: true, subscribed: false}} =
               sub(Readiness.deep(), "spawn.dispatch")
    end
  end
end
