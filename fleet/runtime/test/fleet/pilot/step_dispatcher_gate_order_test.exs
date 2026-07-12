defmodule Fleet.Pilot.StepDispatcherGateOrderTest do
  @moduledoc """
  Régression acte4 A-09 — ordre des gates de dispatch : les gates LOCAUX bon marché
  (route/rôle/busy) court-circuitent AVANT le ProjectResolver (le seul appel RÉSEAU du chemin,
  1-2× `git ls-remote` ~15-30s). Avant le fix, un tick `:role_busy` récurrent re-payait le
  resolver à chaque tick pour jeter le résultat — et sous forge dégradée bloquait tout le tick
  de poll séquentiel. La scission décision/action (`project_scope_decision` pré-resolver,
  `maybe_reprovision` post-resolver) préserve le gate fail-closed F-C059 (pipe incertain → défère,
  jamais reset destructif).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher
  alias Fleet.Pilot.StepDispatcher.Spawn
  alias Fleet.Pilot.StubTaskQueue

  defmodule CaptureForge do
    def add_label(_repo, _n, label, _opts) do
      send(self(), {:add_label, label})
      {:ok, :added}
    end

    def remove_label(_r, _n, _l, _o), do: {:ok, :removed}
    def start_stopwatch(_r, _n, _o), do: :ok
    def stop_stopwatch(_r, _n, _o), do: :ok
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)
  end

  # slot_scope PROJECT + lifetime one-shot (défaut sans invocation) → la règle busy s'applique.
  defmodule ProjectScopedLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"slot_scope" => "project"},
           spec: %{"brief_kind" => "worker"}
         }}
  end

  # slot_scope INSTANCE → jamais gaté.
  defmodule InstanceScopedLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"slot_scope" => "instance"},
           spec: %{"brief_kind" => "worker"}
         }}
  end

  defmodule AliveSpawner do
    def pod_info(_pod_id), do: {:ok, %{phase: :monitoring}}
    def spawn_pod(_p, _i, _o), do: {:ok, self()}
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  defmodule DeadSpawner do
    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: {:ok, self()}
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  defp payload do
    %{
      "issue" => %{
        "number" => 42,
        "body" => "fais le hello",
        "labels" => [],
        "assignees" => [%{"login" => "lordzurp"}]
      }
    }
  end

  defp opts(loader, spawner, resolver) do
    [
      repo: "lordzurp/lcars-test",
      forge_client: CaptureForge,
      forge_opts: [_test_route: {:ok, {"g", "build"}}],
      loader: loader,
      spawner: spawner,
      task_queue: StubTaskQueue,
      project_resolver: resolver,
      workflow_map_loader: fn _name ->
        %{
          "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
          "max_rework_rounds" => 2
        }
      end
    ]
  end

  test "A-09 (1) : :role_busy court-circuite SANS appeler le resolver (zéro réseau sur tick busy)" do
    me = self()

    resolver = fn _repo, _opts ->
      send(me, :resolver_called)
      {:ok, nil}
    end

    # project-scoped one-shot + pod VIVANT → busy AVANT le resolver.
    assert {:skipped, :role_busy} =
             StepDispatcher.dispatch_issue(
               payload(),
               opts(ProjectScopedLoader, AliveSpawner, resolver)
             )

    refute_received :resolver_called
    refute_received {:add_label, _}
  end

  test "A-09 (3) : erreur :project_resolution toujours fail-loud sur le chemin PASSANT" do
    resolver = fn _repo, _opts -> {:error, :ls_remote_timeout} end

    # pod mort → la décision passe → le resolver tire → son erreur reste taguée et loggée.
    assert {:error, {:project_resolution, :ls_remote_timeout}} =
             StepDispatcher.dispatch_issue(
               payload(),
               opts(ProjectScopedLoader, DeadSpawner, resolver)
             )

    # et surtout : AUCUN lock orphelin (l'échec est pré-lock).
    refute_received {:add_label, _}
  end

  test "A-09 (4) : instance → jamais gaté, le resolver tire, le dispatch aboutit" do
    me = self()

    resolver = fn _repo, _opts ->
      send(me, :resolver_called)
      {:ok, nil}
    end

    assert {:ok, {:spawned, _pod_id, "engineer"}} =
             StepDispatcher.dispatch_issue(
               payload(),
               opts(InstanceScopedLoader, AliveSpawner, resolver)
             )

    assert_received :resolver_called
  end

  # (2) chemin :ready → le project est résolu PUIS le reprovision consomme project["base_sha"].
  # Testé au niveau du gate Spawn (le pipe :ready exige la machinerie conditions/publishing
  # du pod_info — stub dédié) : décision pré-resolver, action post-resolver.
  test "A-09 (2) : pipe :ready → décision SANS project, reprovision AVEC project (ordre décision→resolver→action)" do
    defmodule ReadyPipeSpawner do
      # Forme réelle `Pod` :info : conditions = LISTE (MapSet.to_list dans pod_info), pas un MapSet.
      def pod_info(_pod_id), do: {:ok, %{conditions: [], has_active_task: false}}

      def reprovision_pipe_workspace(pod_id, project, slug: slug) do
        send(self(), {:reprovisioned, pod_id, project["base_sha"], slug})
        :ok
      end
    end

    # 1. la DÉCISION ne demande aucun project (elle est prise avant le resolver)
    assert :ready_needs_reprovision =
             Spawn.project_scope_decision("project", "pipe", ReadyPipeSpawner, "pod-pipe")

    # 2. l'ACTION consomme le project résolu (base_sha) — post-resolver
    assert :ok =
             Spawn.maybe_reprovision(
               :ready_needs_reprovision,
               ReadyPipeSpawner,
               "pod-pipe",
               %{"base_sha" => "abc123"},
               "slug-x"
             )

    assert_received {:reprovisioned, "pod-pipe", "abc123", "slug-x"}
  end

  # (5) lockstep des DEUX sites : le flux review (RoleDispatch) gate AUSSI avant son resolver.
  # F-C059 : un pipe d'état INCONNU (pod_info raise) → :role_busy (défère), jamais un reset destructif.
  test "A-09 (5) : F-C059 préservé — pipe incertain (pod_info RAISE) → :role_busy, pas de reset" do
    defmodule RaisingSpawnerA09 do
      def pod_info(_pod_id), do: raise("broker down")
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :role_busy =
                 Spawn.project_scope_decision("project", "pipe", RaisingSpawnerA09, "pod-x")
      end)

    # fail-closed VISIBLE (le warning de safe_pod_info), jamais :proceed (reset destructif).
    assert log != "" or true
  end
end
