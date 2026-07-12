defmodule Fleet.Pilot.StepDispatcherCapacityTest do
  @moduledoc """
  Régression acte4 A-11 — gate capacité PRE-FLIGHT (avant le lock forge). À saturation
  (`max_pods`), l'ancien flux prenait le lock, découvrait `:max_children` au spawn, puis
  compensait (unlock) À CHAQUE tick : ~4 écritures forge/issue/30s polluant le timeline, et
  « plein » comptabilisé en ERREUR (backoff du poller comme si la forge lâchait). Le gate
  pre-flight défère SANS écriture (`{:skipped, :at_capacity}`) ; le TOCTOU résiduel reste
  couvert par `max_children` + la compensation (désormais l'exception rare).
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

    def remove_label(_repo, _n, label, _opts) do
      send(self(), {:remove_label, label})
      {:ok, :removed}
    end

    def start_stopwatch(_repo, _n, _opts), do: :ok
    def stop_stopwatch(_repo, _n, _opts), do: :ok
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)
  end

  defmodule StubLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"slot_scope" => "project"},
           spec: %{"brief_kind" => "worker"}
         }}
  end

  # Saturé + pod frais : has_capacity? false, pod_info :error (pod pas vivant).
  defmodule FullFreshSpawner do
    def has_capacity?, do: false
    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: raise("spawn_pod ne doit JAMAIS être atteint à saturation")
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # Saturé + pod VIVANT : le re-brief ne crée aucun child → ne doit PAS être gaté.
  defmodule FullAliveSpawner do
    def has_capacity?, do: false
    def pod_info(_pod_id), do: {:ok, %{phase: :monitoring}}
    def spawn_pod(_p, _i, _o), do: raise("un pod vivant se re-brief, pas de spawn")
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  # TOCTOU : la place libre au check est volée avant le spawn → :max_children au spawn réel.
  defmodule ToctouSpawner do
    def has_capacity?, do: true
    def pod_info(_pod_id), do: {:error, :not_found}
    def spawn_pod(_p, _i, _o), do: {:error, :max_children}
    def wake_pod(_pod_id), do: :ok
    def kill_pod(_pod_id), do: :ok
  end

  defp profile do
    {:ok, p} = StubLoader.load("engineer")
    p
  end

  defp seams(spawner) do
    %Spawn.Seams{
      forge: CaptureForge,
      spawner: spawner,
      task_queue: StubTaskQueue,
      repo: "lordzurp/lcars-test",
      forge_opts: [],
      wake_recovery: fn _pod_id, _spawn_fn, _opts -> :ok end
    }
  end

  test "saturé + spawn FRAIS → {:skipped, :at_capacity}, AUCUNE écriture forge (pas de lock)" do
    assert {:skipped, :at_capacity} =
             Spawn.spawn_step(
               seams(FullFreshSpawner),
               "pod-x",
               "engineer",
               profile(),
               "brief",
               [],
               42,
               42,
               "ctx"
             )

    refute_received {:add_label, _}
    refute_received {:remove_label, _}
  end

  test "saturé + pod VIVANT → le re-brief PROCÈDE (un pipe vivant ne crée pas de child : pas affamé)" do
    assert {:ok, {:spawned, "pod-alive", "engineer"}} =
             Spawn.spawn_step(
               seams(FullAliveSpawner),
               "pod-alive",
               "engineer",
               profile(),
               "brief",
               [],
               42,
               42,
               "ctx"
             )

    # le lock EST pris (le pod travaille l'issue), aucun kill/compensation
    assert_received {:add_label, "lcars-in-flight"}
    refute_received {:remove_label, _}
  end

  test "TOCTOU (place volée entre check et spawn) → :max_children au spawn + compensation intacte" do
    assert {:error, :max_children} =
             Spawn.spawn_step(
               seams(ToctouSpawner),
               "pod-t",
               "engineer",
               profile(),
               "brief",
               [],
               42,
               42,
               "ctx"
             )

    # le lock a été pris PUIS compensé (remove_label) — le filet TOCTOU tient
    assert_received {:add_label, "lcars-in-flight"}
    assert_received {:remove_label, "lcars-in-flight"}
  end

  test "propagation bout-en-bout : dispatch_issue rend {:skipped, :at_capacity} (tally skip, pas erreur)" do
    payload = %{
      "issue" => %{
        "number" => 42,
        "body" => "fais le hello",
        "labels" => [],
        "assignees" => [%{"login" => "lordzurp"}]
      }
    }

    opts = [
      repo: "lordzurp/lcars-test",
      forge_client: CaptureForge,
      forge_opts: [_test_route: {:ok, {"g", "build"}}],
      loader: StubLoader,
      spawner: FullFreshSpawner,
      task_queue: StubTaskQueue,
      project_resolver: fn _repo, _opts -> {:ok, nil} end,
      workflow_map_loader: fn _name ->
        %{
          "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
          "max_rework_rounds" => 2
        }
      end
    ]

    assert {:skipped, :at_capacity} = StepDispatcher.dispatch_issue(payload, opts)
    refute_received {:add_label, _}
  end
end
