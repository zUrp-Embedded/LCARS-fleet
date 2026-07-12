defmodule Fleet.API.ReadinessTest do
  # async: false — les probes lisent la config Application globale ; certains
  # tests la mutent via put_env (puis restaurent). Séquentialiser évite la
  # pollution cross-test (même raison que RestTest).
  use ExUnit.Case, async: false

  alias Fleet.API.Readiness

  @mutated [
    {:fleet_starfleet, :coord_backend},
    {:fleet_starfleet, :shutdown_dispatcher},
    {:fleet_spawner, :launch_backend}
  ]

  setup do
    # Snapshot des clés mutées pour restaurer l'ambient test exact (ex.
    # launch_backend=StubBackend posé par config/test.exs, à NE PAS supprimer).
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

  describe "deep/0 — forme" do
    test "verdict global + liste dégradés + 7 sous-systèmes + ts" do
      assert %{status: status, degraded: degraded, subsystems: subsystems, ts: ts} =
               Readiness.deep()

      assert status in ["operational", "degraded"]
      assert is_list(degraded)

      # 7 sous-systèmes : event.registry, coord.backend, shutdown.dispatcher, launch.backend,
      # mcp.pod_facing, pilot.step (rail forge-state-machine), + spawn.dispatch (acte3 vague C :
      # PublishConsumer = unique abonné de admin.spawn.request, ex-vert-creux du 202).
      assert length(subsystems) == 7
      assert is_binary(ts)

      # chaque sous-système : id/state/detail, state dans le vocab
      Enum.each(subsystems, fn s ->
        assert %{id: id, state: state, detail: detail} = s
        assert is_binary(id)
        assert state in [:operational, :inactive, :degraded]
        assert is_map(detail)
      end)
    end

    test "verdict global = degraded ssi au moins un sous-système :degraded" do
      result = Readiness.deep()
      any_degraded? = Enum.any?(result.subsystems, &(&1.state == :degraded))
      assert result.status == if(any_degraded?, do: "degraded", else: "operational")
      # la liste degraded nomme exactement les sous-systèmes :degraded
      assert result.degraded ==
               result.subsystems |> Enum.filter(&(&1.state == :degraded)) |> Enum.map(& &1.id)
    end
  end

  describe "coord.backend" do
    test "operational quand backend réel câblé" do
      Application.put_env(:fleet_starfleet, :coord_backend, Fleet.Coord)
      assert %{state: :operational} = sub(Readiness.deep(), "coord.backend")
    end

    test "degraded quand NotWiredYet" do
      Application.put_env(
        :fleet_starfleet,
        :coord_backend,
        Fleet.Starfleet.CoordBackend.NotWiredYet
      )

      assert %{state: :degraded} = sub(Readiness.deep(), "coord.backend")
    end
  end

  describe "shutdown.dispatcher" do
    test "degraded sur NoOpDispatcher (Fleet.Dispatcher absent)" do
      Application.put_env(
        :fleet_starfleet,
        :shutdown_dispatcher,
        Fleet.Starfleet.Shutdown.NoOpDispatcher
      )

      assert %{state: :degraded, detail: %{backend: "NoOpDispatcher"}} =
               sub(Readiness.deep(), "shutdown.dispatcher")
    end

    test "operational quand vrai backend câblé" do
      Application.put_env(:fleet_starfleet, :shutdown_dispatcher, Fleet.Coord)
      assert %{state: :operational} = sub(Readiness.deep(), "shutdown.dispatcher")
    end

    # Drift-kill : clé non posée → readiness lit le défaut canon du PROPRIÉTAIRE
    # (`Fleet.Starfleet.Shutdown.configured_dispatcher/0` → NoOpDispatcher), pas un défaut re-déclaré.
    test "clé absente → défaut canon partagé (NoOpDispatcher) → degraded" do
      Application.delete_env(:fleet_starfleet, :shutdown_dispatcher)

      assert %{state: :degraded, detail: %{backend: "NoOpDispatcher"}} =
               sub(Readiness.deep(), "shutdown.dispatcher")

      assert Fleet.Starfleet.Shutdown.configured_dispatcher() ==
               Fleet.Starfleet.Shutdown.NoOpDispatcher
    end
  end

  describe "launch.backend" do
    test "degraded sur StubBackend (inerte)" do
      Application.put_env(
        :fleet_spawner,
        :launch_backend,
        Fleet.Spawner.LaunchBackend.StubBackend
      )

      assert %{state: :degraded, detail: %{backend: "StubBackend"}} =
               sub(Readiness.deep(), "launch.backend")
    end

    test "operational sur backend réel" do
      Application.put_env(
        :fleet_spawner,
        :launch_backend,
        Fleet.Spawner.LaunchBackend.LauncherPortBackend
      )

      assert %{state: :operational} = sub(Readiness.deep(), "launch.backend")
    end

    # Drift-kill : clé non posée → readiness lit le défaut canon du PROPRIÉTAIRE
    # (`Fleet.Spawner.LaunchBackend.resolved/0` → LauncherPortBackend, ce qui lance vraiment les pods),
    # donc operational, PAS un `:degraded` fantôme dû à un `nil` ou un défaut re-copié périmé.
    test "clé absente → défaut canon partagé (LauncherPortBackend) → operational" do
      Application.delete_env(:fleet_spawner, :launch_backend)

      assert %{state: :operational} = sub(Readiness.deep(), "launch.backend")

      assert Fleet.Spawner.LaunchBackend.resolved() ==
               Fleet.Spawner.LaunchBackend.LauncherPortBackend
    end
  end

  # describe "pilot.dispatcher" RETIRÉ (②.3 / BL-050) : la probe sondait l'AutoDispatcher legacy, supprimé.

  describe "event.registry (B2 — escape-hatch visible)" do
    test "degraded quand registry vide (ambient test, load_event_registry false)" do
      assert %{state: :degraded, detail: %{authorized_types: 0}} =
               sub(Readiness.deep(), "event.registry")
    end
  end

  describe "mcp.pod_facing (sonde le PROCESS — le DynamicSupervisor d'accepteurs de socket)" do
    # Substrat socket per-pod vivant (booté host-side dans l'umbrella) + spec injecté AUX pods présent
    # → operational. On pose le spec (absent en ambient) pour isoler ce cas.
    test "operational quand le substrat socket tourne ET mcp_server_spec présent" do
      Application.put_env(:fleet_spawner, :mcp_server_spec, %{"some" => "spec"})
      on_exit(fn -> Application.delete_env(:fleet_spawner, :mcp_server_spec) end)

      assert %{state: :operational, detail: %{acceptor_supervisor: true}} =
               sub(Readiness.deep(), "mcp.pod_facing")
    end

    # Ambient test : substrat vivant MAIS mcp_server_spec absent (pods non câblés) → la probe dégrade
    # (anti-vert-creux : le substrat tourne mais rien n'est injecté aux pods).
    test "degraded quand substrat vivant mais mcp_server_spec absent (pods non câblés)" do
      Application.delete_env(:fleet_spawner, :mcp_server_spec)

      assert %{state: :degraded, detail: detail} = sub(Readiness.deep(), "mcp.pod_facing")
      assert detail.mcp_server_spec == false
      assert detail.note =~ "mcp_server_spec absent"
    end
  end

  describe "deep/1 — agrégation (probes injectées)" do
    defp op(id), do: {id, fn -> %{id: id, state: :operational, detail: %{}} end}
    defp deg(id), do: {id, fn -> %{id: id, state: :degraded, detail: %{}} end}
    defp ina(id), do: {id, fn -> %{id: id, state: :inactive, detail: %{}} end}

    test "tout operational (+ inactive) → status operational, degraded vide" do
      assert %{status: "operational", degraded: []} =
               Readiness.deep([op("a"), op("b"), ina("c")])
    end

    test "un sous-système degraded → status degraded, nommé dans la liste" do
      assert %{status: "degraded", degraded: ["b"]} =
               Readiness.deep([op("a"), deg("b"), ina("c")])
    end

    test "inactive seul ne dégrade PAS le verdict global (R21)" do
      assert %{status: "operational", degraded: []} = Readiness.deep([ina("a"), ina("b")])
    end

    test "probe qui crash → degraded avec id préservé + detail.error (safe_probe)" do
      probes = [op("a"), {"boom", fn -> raise "kaboom" end}]
      result = Readiness.deep(probes)

      assert %{status: "degraded", degraded: ["boom"]} = result
      assert %{state: :degraded, detail: %{error: msg}} = sub(result, "boom")
      assert msg =~ "kaboom"
    end
  end

  describe "spawn.dispatch (sonde le PROCESS — l'unique abonné de admin.spawn.request)" do
    # Acte3 vague C : le 202 de POST /api/admin/spawn mentait quand PublishConsumer était off
    # (Bus lossy → broadcast perdu → 0 pod) alors que /readiness/deep disait operational.
    test "degraded quand PublishConsumer absent (start_publish_consumer off — ambient test)" do
      # config/test.exs pose start_publish_consumer=false → le consumer n'est jamais démarré.
      refute is_pid(Process.whereis(Fleet.Spawner.PublishConsumer))
      assert %{state: :degraded, detail: %{consumer: false}} = sub(Readiness.deep(), "spawn.dispatch")
    end

    test "operational quand PublishConsumer vivant ET abonné" do
      start_supervised!({Fleet.Spawner.PublishConsumer, [subscribe: true]})

      assert %{state: :operational, detail: %{consumer: true, subscribed: true}} =
               sub(Readiness.deep(), "spawn.dispatch")
    end

    test "degraded quand PublishConsumer vivant mais NON abonné (seam subscribe:false)" do
      start_supervised!({Fleet.Spawner.PublishConsumer, [subscribe: false]})

      assert %{state: :degraded, detail: %{consumer: true, subscribed: false}} =
               sub(Readiness.deep(), "spawn.dispatch")
    end
  end
end
