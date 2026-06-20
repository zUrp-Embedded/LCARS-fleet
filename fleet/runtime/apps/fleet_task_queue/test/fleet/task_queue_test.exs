defmodule Fleet.TaskQueueTest do
  @moduledoc """
  Tests conformance du broker — DN `orchestration/task-queue` §G (10 tests).
  Tous les `assert_receive` matchent le schema canon `%Fleet.Event{}`.

  Isolation async : topic PubSub unique par test (défaut canonique `fleet.events`
  surchargé via opt `:topic`) + `@moduletag :tmp_dir` pour le `state.json`.
  """
  use ExUnit.Case, async: true
  @moduletag :tmp_dir

  alias Fleet.TaskQueue
  alias Fleet.TaskQueue.Server

  setup %{tmp_dir: tmp_dir} do
    topic = "fleet.events.test.#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Fleet.PubSub, topic)
    state_path = Path.join(tmp_dir, "state.json")
    {:ok, q} = start_supervised({Server, name: nil, topic: topic, state_path: state_path})
    %{q: q, topic: topic, tmp_dir: tmp_dir}
  end

  test "1. enqueue + get_for_pod happy path", %{q: q} do
    {:ok, task} = TaskQueue.enqueue(q, "pod-A", %{brief: "fix X", role: "engineer"})
    assert task.state == :pending
    tid = task.id

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :task_enqueued,
      pod_id: "pod-A",
      correlation_id: ^tid,
      # F144 : payload = %{task_id} (cohérent + JSON-safe), plus le %Task{} brut.
      payload: %{task_id: ^tid}
    }

    {:ok, assigned} = TaskQueue.get_for_pod(q, "pod-A")
    assert %{state: :assigned, id: ^tid} = assigned

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :task_assigned,
      pod_id: "pod-A",
      correlation_id: ^tid
    }
  end

  test "last_poll : get_for_pod enregistre le poll MÊME sans mandat (ACK bootstrap in-band)", %{
    q: q
  } do
    assert TaskQueue.last_poll(q, "pod-boot") == nil
    # pas de mandat → :no_task, mais l'agent a TENDU LA MAIN → le poll est gravé
    assert {:error, :no_task} = TaskQueue.get_for_pod(q, "pod-boot")
    assert %DateTime{} = TaskQueue.last_poll(q, "pod-boot")
  end

  test "last_poll : tracké aussi sur un pull (avec mandat)", %{q: q} do
    {:ok, _} = TaskQueue.enqueue(q, "pod-W", %{brief: "x", role: "engineer"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-W")
    assert %DateTime{} = TaskQueue.last_poll(q, "pod-W")
  end

  test "2. get_for_pod idempotent (résiste au /clear one_shot, pas de double dispatch)", %{q: q} do
    {:ok, t1} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    assert_receive %Fleet.Event{type: :task_enqueued}

    {:ok, a1} = TaskQueue.get_for_pod(q, "pod-A")
    assert_receive %Fleet.Event{type: :task_assigned}

    # 2e appel → MÊME mandat, PAS de nouveau broadcast :task_assigned
    {:ok, a2} = TaskQueue.get_for_pod(q, "pod-A")
    assert a1.id == t1.id
    assert a2.id == a1.id
    refute_receive %Fleet.Event{type: :task_assigned}, 100
  end

  test "3. submit_result happy path", %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    tid = t.id

    {:ok, completed} =
      TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven", "artifacts" => []})

    assert completed.state == :completed

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      pod_id: "pod-A",
      correlation_id: ^tid,
      payload: %{result: %{"verdict" => "proven"}}
    }
  end

  test "4. submit_result idempotent (double submit ignoré, pas de double broadcast)", %{q: q} do
    {:ok, _} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    {:ok, _} = TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})
    assert_receive %Fleet.Event{type: :task_completed}

    assert {:error, :double_submit_ignored} =
             TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})

    refute_receive %Fleet.Event{type: :task_completed}, 100
  end

  test "5. recovery cross-restart", %{topic: topic, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "recover.json")
    {:ok, q1} = start_supervised({Server, name: nil, topic: topic, state_path: path}, id: :q1)
    {:ok, _} = TaskQueue.enqueue(q1, "pod-A", %{brief: "a"})
    {:ok, _} = TaskQueue.enqueue(q1, "pod-B", %{brief: "b"})
    {:ok, _} = TaskQueue.enqueue(q1, "pod-C", %{brief: "c"})
    {:ok, _} = TaskQueue.get_for_pod(q1, "pod-A")
    {:ok, _} = TaskQueue.submit_result(q1, "pod-A", %{"verdict" => "proven"})

    :ok = stop_supervised(:q1)

    {:ok, q2} = start_supervised({Server, name: nil, topic: topic, state_path: path}, id: :q2)
    # 3 tasks total : A completed, B + C pending — état reconstruit
    assert {:ok, :completed} = TaskQueue.pod_status(q2, "pod-A")

    assert [%{pod_id: "pod-B"}, %{pod_id: "pod-C"}] =
             q2 |> TaskQueue.list_pending() |> Enum.sort_by(& &1.pod_id)
  end

  test "6. recovery schema mismatch → :state_corrupt + state vide (non-bloquant)", %{
    topic: topic,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "corrupt.json")
    File.write!(path, Jason.encode!(%{"v" => 99, "tasks" => %{}}))

    {:ok, q} = start_supervised({Server, name: nil, topic: topic, state_path: path}, id: :qc)

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :state_corrupt,
      payload: %{expected: 1, found: 99}
    }

    # fallback non-bloquant : la queue tourne, state vide
    assert [] = TaskQueue.list_pending(q)
  end

  test "6b. Task.from_map round-trip préserve les champs riches (fix deep-02 : recovery ne perd plus brief/role/metadata)" do
    t = %Fleet.TaskQueue.Task{
      id: "t1",
      pod_id: "p1",
      enqueued_at: ~U[2026-06-02 00:00:00Z],
      state: :assigned,
      ticket_id: "tk1",
      role: "engineer",
      brief: "fais X",
      metadata: %{"stage" => "qa"},
      result: %{"ok" => true}
    }

    assert {:ok, back} = Fleet.TaskQueue.Task.from_map(Fleet.TaskQueue.Task.to_map(t))

    assert %{
             brief: "fais X",
             role: "engineer",
             ticket_id: "tk1",
             state: :assigned,
             metadata: %{"stage" => "qa"},
             result: %{"ok" => true}
           } = back
  end

  test "6c. recovery d'une tâche au state INCONNU → :state_corrupt (fix deep-02 : fail-loud, pas de raise ni drop silencieux)",
       %{topic: topic, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "badstate.json")

    File.write!(
      path,
      Jason.encode!(%{
        "v" => 1,
        "tasks" => %{
          "t1" => %{
            "id" => "t1",
            "pod_id" => "p1",
            "enqueued_at" => "2026-06-02T00:00:00Z",
            "state" => "bogus_xyz"
          }
        }
      })
    )

    {:ok, q} = start_supervised({Server, name: nil, topic: topic, state_path: path}, id: :qbs)

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :state_corrupt,
      payload: %{found: {:task, "t1", :invalid}}
    }

    assert [] = TaskQueue.list_pending(q)
  end

  test "6d. enqueued_at ISO invalide → {:error,:invalid} (champ requis, pas de nil silencieux — fix after-9b3aea3d)" do
    bad = %{"id" => "t1", "pod_id" => "p1", "enqueued_at" => "pas-une-date", "state" => "pending"}
    assert {:error, :invalid} = Fleet.TaskQueue.Task.from_map(bad)
  end

  test "6e. recovery ré-arme les deadlines actives — expirée pendant le downtime → fail (fix deep-02 P1)",
       %{topic: topic, tmp_dir: tmp_dir} do
    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()
    past_iso = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
    path = Path.join(tmp_dir, "deadline_recovery.json")

    File.write!(
      path,
      Jason.encode!(%{
        "v" => 1,
        "tasks" => %{
          "t1" => %{
            "id" => "t1",
            "pod_id" => "p1",
            "enqueued_at" => now_iso,
            "state" => "assigned",
            "deadline" => past_iso
          }
        }
      })
    )

    {:ok, q} = start_supervised({Server, name: nil, topic: topic, state_path: path}, id: :qdl)

    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :task_failed,
                     correlation_id: "t1",
                     payload: %{reason: :deadline_expired}
                   },
                   1000

    assert {:ok, :failed} = TaskQueue.pod_status(q, "p1")
  end

  test "7. failed via deadline", %{q: q} do
    deadline = DateTime.add(DateTime.utc_now(), 200, :millisecond)
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x", deadline: deadline})
    tid = t.id
    assert_receive %Fleet.Event{type: :task_enqueued}

    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :task_failed,
                     correlation_id: ^tid,
                     payload: %{reason: :deadline_expired}
                   },
                   1000

    assert {:ok, :failed} = TaskQueue.pod_status(q, "pod-A")
  end

  test "8. list_pending (Query Port, pas de broadcast)", %{q: q} do
    for n <- 1..5, do: TaskQueue.enqueue(q, "pod-#{n}", %{brief: "t#{n}"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-1")
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-2")
    # 5 enqueue - 2 assigned = 3 pending
    assert [_, _, _] = TaskQueue.list_pending(q)
  end

  test "9. clear_for_pod", %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    tid = t.id

    assert :ok = TaskQueue.clear_for_pod(q, "pod-A")

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :task_cleared,
      pod_id: "pod-A",
      correlation_id: ^tid
    }

    assert {:ok, :cleared} = TaskQueue.pod_status(q, "pod-A")
  end

  test "10. conformance schema %Fleet.Event{} sur les events", %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})

    assert_receive %Fleet.Event{} = ev
    assert ev.source == :task_queue
    # enforce_keys présents
    assert ev.timestamp != nil and ev.type != nil
    # correlation_id == task.id quand un mandat existe
    assert ev.correlation_id == t.id
    assert Fleet.Event.valid_source?(ev.source)
  end

  test "11. submit_result avec task_id ≠ mandat actif → :task_id_mismatch (§A.70, pas de mutation)",
       %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    assert_receive %Fleet.Event{type: :task_enqueued}
    assert_receive %Fleet.Event{type: :task_assigned}

    # Le pod renvoie un task_id forgé/périmé ≠ son mandat actif → rejet.
    assert {:error, :task_id_mismatch} =
             TaskQueue.submit_result(q, "pod-A", %{"task_id" => "forged-uuid", "verdict" => "x"})

    # Aucune mutation : le mandat reste actif, pas de :task_completed.
    assert {:ok, :assigned} = TaskQueue.pod_status(q, "pod-A")
    refute_receive %Fleet.Event{type: :task_completed}, 100

    # Avec le bon task_id → OK.
    assert {:ok, _} = TaskQueue.submit_result(q, "pod-A", %{"task_id" => t.id, "verdict" => "ok"})
    assert_receive %Fleet.Event{type: :task_completed}
  end

  test "12. F148 — rétention borne les tâches terminales (actives intactes + double-submit du plus récent)",
       %{topic: topic, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "retention.json")

    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: topic, state_path: path, retention_terminal_max: 3},
        id: :qret
      )

    # 5 pods menés à complétion (terminal :completed) ; cap = 3.
    for i <- 1..5 do
      pod = "pod-#{i}"
      {:ok, _} = TaskQueue.enqueue(q, pod, %{brief: "b#{i}"})
      {:ok, _} = TaskQueue.get_for_pod(q, pod)
      {:ok, _} = TaskQueue.submit_result(q, pod, %{"verdict" => "ok"})
    end

    # + un mandat ACTIF : ne doit JAMAIS être élagué.
    {:ok, _} = TaskQueue.enqueue(q, "pod-active", %{brief: "en cours"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-active")

    tasks = :sys.get_state(q).tasks |> Map.values()
    terminal = Enum.filter(tasks, &(&1.state == :completed))
    active = Enum.filter(tasks, &(&1.state in [:pending, :assigned, :in_progress]))

    # Borne dure : 5 complétées → au plus 3 conservées (2 élaguées).
    assert length(terminal) == 3
    # L'active survit toujours (jamais comptée ni coupée).
    assert [%{pod_id: "pod-active", state: :assigned}] = active

    # Le plus récent complété (pod-5) survit → double-submit TOUJOURS détecté, pas dégradé
    # en :no_active_task par une rétention qui couperait la mauvaise tâche (récence, pas FIFO).
    assert {:error, :double_submit_ignored} =
             TaskQueue.submit_result(q, "pod-5", %{"verdict" => "retry"})
  end
end
