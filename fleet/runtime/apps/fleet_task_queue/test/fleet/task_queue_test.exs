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

  # MA-04 — bus stub : `broadcast/2` RETOURNE `{:error, _}` (simule un PubSub qui refuse, ex.
  # UnregisteredError downgradé). Le chemin lifecycle doit propager, pas avaler.
  defmodule FailBus do
    def broadcast(_topic, _ev), do: {:error, :forced_broadcast_fail}
  end

  # MA-04 — bus stub : `broadcast/2` LÈVE (simule UnregisteredError / PubSub pas démarré). Le
  # `required_broadcast` doit rescue → `{:error, {:broadcast_failed, _}}`, jamais `:ok` muet.
  defmodule RaiseBus do
    def broadcast(_topic, _ev), do: raise(Fleet.Event.UnregisteredError, "forced raise")
  end

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
      type: :"work_item.enqueued",
      pod_id: "pod-A",
      correlation_id: ^tid,
      # F144 : payload = %{work_item_id} (cohérent + JSON-safe), plus le %WorkItem{} brut.
      payload: %{work_item_id: ^tid}
    }

    {:ok, assigned} = TaskQueue.get_for_pod(q, "pod-A")
    assert %{state: :assigned, id: ^tid} = assigned

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :"work_item.assigned",
      pod_id: "pod-A",
      correlation_id: ^tid
    }
  end

  test "AXIOME cleanup : enqueue supersède le :pending existant du pod (1 work item actif/pod, le frais gagne)",
       %{q: q} do
    {:ok, _stale} = TaskQueue.enqueue(q, "pod-X", %{brief: "stale", role: "engineer"})
    {:ok, fresh} = TaskQueue.enqueue(q, "pod-X", %{brief: "frais", role: "engineer"})

    # un SEUL :pending pour pod-X = le frais ; le stale est superséded → pas d'empilement intra-session
    # (la cause des 1124 "en cours"). [[axiome source-unique : nettoyé quand ce n'est plus vrai]]
    assert [%{brief: "frais", state: :pending} = only] =
             TaskQueue.list_pending(q) |> Enum.filter(&(&1.pod_id == "pod-X"))

    assert only.id == fresh.id
    # get_for_pod sert le frais, pas le résidu
    assert {:ok, %{brief: "frais"}} = TaskQueue.get_for_pod(q, "pod-X")
  end

  test "last_poll : get_for_pod enregistre le poll MÊME sans work item (ACK bootstrap in-band)",
       %{
         q: q
       } do
    assert TaskQueue.last_poll(q, "pod-boot") == nil
    # pas de work item → :no_work_item, mais l'agent a TENDU LA MAIN → le poll est gravé
    assert {:error, :no_work_item} = TaskQueue.get_for_pod(q, "pod-boot")
    assert %DateTime{} = TaskQueue.last_poll(q, "pod-boot")
  end

  test "last_poll : tracké aussi sur un pull (avec work item)", %{q: q} do
    {:ok, _} = TaskQueue.enqueue(q, "pod-W", %{brief: "x", role: "engineer"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-W")
    assert %DateTime{} = TaskQueue.last_poll(q, "pod-W")
  end

  test "last_poll : clear_for_pod oublie le poll du pod (pas d'accumulation de pod_id morts)", %{
    q: q
  } do
    # Le pod a tendu la main (poll gravé), puis est décommissionné via clear_for_pod.
    {:error, :no_work_item} = TaskQueue.get_for_pod(q, "pod-dead")
    assert %DateTime{} = TaskQueue.last_poll(q, "pod-dead")

    assert :ok = TaskQueue.clear_for_pod(q, "pod-dead")
    # Le clear est le point de purge canonique du pod → son last-poll est oublié (sinon `polls`
    # accumulerait indéfiniment les pod_id morts).
    assert TaskQueue.last_poll(q, "pod-dead") == nil
  end

  test "2. get_for_pod idempotent (résiste au /clear one_shot, pas de double dispatch)", %{q: q} do
    {:ok, t1} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    assert_receive %Fleet.Event{type: :"work_item.enqueued"}

    {:ok, a1} = TaskQueue.get_for_pod(q, "pod-A")
    assert_receive %Fleet.Event{type: :"work_item.assigned"}

    # 2e appel → MÊME work item, PAS de nouveau broadcast :"work_item.assigned"
    {:ok, a2} = TaskQueue.get_for_pod(q, "pod-A")
    assert a1.id == t1.id
    assert a2.id == a1.id
    refute_receive %Fleet.Event{type: :"work_item.assigned"}, 100
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
      type: :"work_item.completed",
      pod_id: "pod-A",
      correlation_id: ^tid,
      payload: %{result: %{"verdict" => "proven"}}
    }
  end

  # MA-04 — LE finding : `work_item.completed` est LIFECYCLE load-bearing (le StepRunConsumer en dépend pour finir
  # le step_run). Si sa diffusion échoue, `submit_result` NE rend PLUS `{:ok}` muet (le pod croirait son livrable
  # accepté alors que le step_run ne finit jamais → verrou forge à vie) — il propage `{:error,{:broadcast_failed,_}}`.
  test "3b. MA-04 : broadcast work_item.completed qui RETOURNE {:error} → submit_result {:error,{:broadcast_failed,_}}, pas {:ok}",
       %{tmp_dir: tmp_dir} do
    state_path = Path.join(tmp_dir, "state_failbus.json")

    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: "t.failbus", state_path: state_path, bus: FailBus},
        id: :q_failbus
      )

    {:ok, _t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")

    result = TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})

    # PAS un succès muet. Le caller VOIT l'échec lifecycle.
    refute match?({:ok, _}, result)
    assert {:error, {:broadcast_failed, :forced_broadcast_fail}} = result
  end

  # MA-04 — variante : le broadcast LÈVE (UnregisteredError / PubSub down). Le `required_broadcast` rescue
  # et propage `{:error,{:broadcast_failed,_}}`, jamais `:ok` muet (le rescue ne ré-avale plus le lifecycle).
  test "3c. MA-04 : broadcast work_item.completed qui LÈVE → {:error,{:broadcast_failed,_}}, pas {:ok}",
       %{tmp_dir: tmp_dir} do
    state_path = Path.join(tmp_dir, "state_raisebus.json")

    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: "t.raisebus", state_path: state_path, bus: RaiseBus},
        id: :q_raisebus
      )

    {:ok, _t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")

    result = TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})

    refute match?({:ok, _}, result)
    assert {:error, {:broadcast_failed, _}} = result
  end

  test "4. submit_result idempotent (double submit ignoré, pas de double broadcast)", %{q: q} do
    {:ok, _} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    {:ok, _} = TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})
    assert_receive %Fleet.Event{type: :"work_item.completed"}

    assert {:error, :double_submit_ignored} =
             TaskQueue.submit_result(q, "pod-A", %{"verdict" => "proven"})

    refute_receive %Fleet.Event{type: :"work_item.completed"}, 100
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

  test "6. recovery schema mismatch → state.corrupt + state vide (non-bloquant)", %{
    topic: topic,
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "corrupt.json")
    File.write!(path, Jason.encode!(%{"v" => 99, "work_items" => %{}}))

    {:ok, q} = start_supervised({Server, name: nil, topic: topic, state_path: path}, id: :qc)

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :"state.corrupt",
      payload: %{expected: 1, found: 99}
    }

    # fallback non-bloquant : la queue tourne, state vide
    assert [] = TaskQueue.list_pending(q)
  end

  test "6b. WorkItem.from_map round-trip préserve les champs riches (fix deep-02 : recovery ne perd plus brief/role/metadata)" do
    t = %Fleet.TaskQueue.WorkItem{
      id: "t1",
      pod_id: "p1",
      enqueued_at: ~U[2026-06-02 00:00:00Z],
      state: :assigned,
      issue_id: "tk1",
      role: "engineer",
      brief: "fais X",
      metadata: %{"step" => "qa"},
      result: %{"ok" => true}
    }

    assert {:ok, back} = Fleet.TaskQueue.WorkItem.from_map(Fleet.TaskQueue.WorkItem.to_map(t))

    assert %{
             brief: "fais X",
             role: "engineer",
             issue_id: "tk1",
             state: :assigned,
             metadata: %{"step" => "qa"},
             result: %{"ok" => true}
           } = back
  end

  test "6c. recovery d'une tâche au state INCONNU → state.corrupt (fix deep-02 : fail-loud, pas de raise ni drop silencieux)",
       %{topic: topic, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "badstate.json")

    File.write!(
      path,
      Jason.encode!(%{
        "v" => 1,
        "work_items" => %{
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
      type: :"state.corrupt",
      payload: %{found: {:work_item, "t1", :invalid}}
    }

    assert [] = TaskQueue.list_pending(q)
  end

  test "6d. enqueued_at ISO invalide → {:error,:invalid} (champ requis, pas de nil silencieux — fix after-9b3aea3d)" do
    bad = %{"id" => "t1", "pod_id" => "p1", "enqueued_at" => "pas-une-date", "state" => "pending"}
    assert {:error, :invalid} = Fleet.TaskQueue.WorkItem.from_map(bad)
  end

  test "6e. from_map REFUSE un optionnel malformé (metadata/result non-map, retry_count non-int≥0, id non-binaire) → :invalid" do
    base = %{
      "id" => "t1",
      "pod_id" => "p1",
      "enqueued_at" => "2026-06-02T00:00:00Z",
      "state" => "pending"
    }

    for bad <- [
          Map.put(base, "metadata", "not-a-map"),
          Map.put(base, "result", ["not", "a", "map"]),
          Map.put(base, "retry_count", -1),
          Map.put(base, "retry_count", "3"),
          Map.put(base, "issue_id", 42)
        ] do
      assert {:error, :invalid} = Fleet.TaskQueue.WorkItem.from_map(bad),
             "map #{inspect(bad)} devrait être :invalid"
    end
  end

  test "6f. WorkItem.new/2 = smart-constructor : caste (deadline ISO→DateTime), refuse un attr malformé" do
    alias Fleet.TaskQueue.WorkItem

    assert {:ok,
            %WorkItem{
              deadline: %DateTime{},
              metadata: %{"k" => "v"},
              state: :pending,
              retry_count: 0
            }} =
             WorkItem.new("p1", %{deadline: "2026-06-02T00:00:00Z", metadata: %{"k" => "v"}})

    assert {:ok, %WorkItem{deadline: nil}} = WorkItem.new("p1", %{})
    assert {:error, {:bad_attr, {:metadata, _}}} = WorkItem.new("p1", %{metadata: "nope"})
    assert {:error, {:bad_attr, {:deadline, _}}} = WorkItem.new("p1", %{deadline: 12_345})
    assert {:error, {:bad_attr, {:issue_id, _}}} = WorkItem.new("p1", %{issue_id: 7})
  end

  test "6g. enqueue propage l'erreur du smart-constructor + caste le deadline ISO", %{
    topic: topic
  } do
    {:ok, q} = start_supervised({Server, name: nil, topic: topic, persist: false}, id: :qenq)

    assert {:error, {:bad_attr, {:deadline, 42}}} = TaskQueue.enqueue(q, "p1", %{deadline: 42})
    assert [] = TaskQueue.list_pending(q)

    assert {:ok, %{deadline: %DateTime{}}} =
             TaskQueue.enqueue(q, "p2", %{deadline: "2030-01-01T00:00:00Z"})
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
        "work_items" => %{
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
                     type: :"work_item.failed",
                     correlation_id: "t1",
                     payload: %{reason: :deadline_expired}
                   },
                   1000

    assert {:ok, :failed} = TaskQueue.pod_status(q, "p1")
  end

  test "MINE-TQ-02 : deadline max-DateTime (année 9999) → enqueue ne crashe PAS le GenServer (clamp du timer)",
       %{topic: topic} do
    {:ok, q} = start_supervised({Server, name: nil, topic: topic, persist: false}, id: :qfar)

    # DateTime MAX valide d'Elixir : ms ≈ 2.5e14 > le plafond `Process.send_after` de l'ERTS → sans clamp,
    # `send_after` lève ArgumentError DANS handle_call(:enqueue) → crash du GenServer (idem à la recovery).
    far = ~U[9999-12-31 23:59:59Z]

    assert {:ok, %{deadline: %DateTime{}}} = TaskQueue.enqueue(q, "p1", %{deadline: far})

    assert Process.alive?(q),
           "le GenServer TaskQueue a crashé sur une deadline lointaine (send_after non clampé)"

    assert [%{pod_id: "p1", state: :pending}] = TaskQueue.list_pending(q)
  end

  test "MINE-TQ-02 : check_deadline PRÉMATURÉ (deadline pas atteinte) → re-arme, ne fail PAS", %{
    topic: topic
  } do
    {:ok, q} = start_supervised({Server, name: nil, topic: topic, persist: false}, id: :qearly)

    # deadline dans 1h : un check_deadline qui arrive AVANT (timer clampé qui fire early) ne doit PAS
    # failer l'item — seule une deadline VRAIMENT atteinte le fait.
    future = DateTime.add(DateTime.utc_now(), 3600, :second)
    {:ok, wi} = TaskQueue.enqueue(q, "p1", %{deadline: future})

    send(q, {:check_deadline, wi.id})
    # list_pending = call synchrone → flushe le check_deadline (FIFO) avant l'assert.
    assert [%{pod_id: "p1", state: :pending}] = TaskQueue.list_pending(q)
  end

  test "MINE-TQ-02 : recovery d'une deadline lointaine (année 9999) → boot SANS crash (clamp au ré-arme)",
       %{topic: topic, tmp_dir: tmp_dir} do
    now_iso = DateTime.utc_now() |> DateTime.to_iso8601()
    path = Path.join(tmp_dir, "far_deadline_recovery.json")

    # Le pire scénario : une deadline lointaine PERSISTÉE → init la ré-arme → sans clamp, crash au boot
    # (potentiellement en BOUCLE, la state.json rechargée re-crashe à chaque redémarrage).
    File.write!(
      path,
      Jason.encode!(%{
        "v" => 1,
        "work_items" => %{
          "t1" => %{
            "id" => "t1",
            "pod_id" => "p1",
            "enqueued_at" => now_iso,
            "state" => "assigned",
            "deadline" => "9999-12-31T23:59:59Z"
          }
        }
      })
    )

    {:ok, q} = start_supervised({Server, name: nil, topic: topic, state_path: path}, id: :qfarrec)

    assert Process.alive?(q), "le GenServer a crashé au boot en ré-armant une deadline lointaine"
    # item recovered actif (la deadline lointaine n'expire pas) — pas de fail spurious.
    assert {:ok, :assigned} = TaskQueue.pod_status(q, "p1")
  end

  test "MINE-TQ-01 : les polls STALE (> TTL) sont purgés → `polls` borné (pod mort sans clear ne fuit pas)",
       %{topic: topic} do
    {:ok, q} =
      start_supervised(
        {Server, name: nil, topic: topic, persist: false, poll_retention_ms: 30},
        id: :qpolls
      )

    # podA poll (get_for_pod enregistre le poll même sans work item = signal bootstrap)
    TaskQueue.get_for_pod(q, "podA")
    assert %DateTime{} = TaskQueue.last_poll(q, "podA")

    # au-delà du TTL (30ms) sans re-poll ni clear : podB poll → le poll STALE de podA est purgé
    Process.sleep(60)
    TaskQueue.get_for_pod(q, "podB")

    assert TaskQueue.last_poll(q, "podA") == nil,
           "le poll stale de podA (pod mort sans clear) aurait dû être purgé"

    assert %DateTime{} = TaskQueue.last_poll(q, "podB")
  end

  test "7. failed via deadline", %{q: q} do
    deadline = DateTime.add(DateTime.utc_now(), 200, :millisecond)
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x", deadline: deadline})
    tid = t.id
    assert_receive %Fleet.Event{type: :"work_item.enqueued"}

    assert_receive %Fleet.Event{
                     source: :task_queue,
                     type: :"work_item.failed",
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

  test "8bis. list_active = pending+assigned+in_progress ; cleared (supersede) et completed EXCLUS",
       %{q: q} do
    # 3 pods : A assigned (pullé), B pending (jamais pullé), C complété — puis D supersédé.
    {:ok, _} = TaskQueue.enqueue(q, "pod-A", %{brief: "a"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    {:ok, _} = TaskQueue.enqueue(q, "pod-B", %{brief: "b"})
    {:ok, tc} = TaskQueue.enqueue(q, "pod-C", %{brief: "c"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-C")
    {:ok, _} = TaskQueue.submit_result(q, "pod-C", %{"work_item_id" => tc.id, "out" => "ok"})

    # D : la 1re tâche est SUPERSÉDÉE (:cleared) par la 2e à l'enqueue (axiome 1-actif/pod tenu à
    # l'écriture) → seule la 2e est active. C'est le cas G1 « éval clobbée » : la cleared ne doit
    # PAS être possédée (sinon un verrou orphelin serait masqué à vie par un fantôme).
    {:ok, d1} = TaskQueue.enqueue(q, "pod-D", %{brief: "d1"})
    {:ok, d2} = TaskQueue.enqueue(q, "pod-D", %{brief: "d2"})

    active = TaskQueue.list_active(q)
    active_ids = MapSet.new(active, & &1.id)

    # A (assigned) + B (pending) + D2 (pending) = 3 actives ; C (completed) et D1 (cleared) exclues.
    assert length(active) == 3
    assert MapSet.member?(active_ids, d2.id)
    refute MapSet.member?(active_ids, d1.id)
    refute MapSet.member?(active_ids, tc.id)
    assert Enum.all?(active, &(&1.state in [:pending, :assigned, :in_progress]))
  end

  test "9. clear_for_pod", %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    tid = t.id

    assert :ok = TaskQueue.clear_for_pod(q, "pod-A")

    assert_receive %Fleet.Event{
      source: :task_queue,
      type: :"work_item.cleared",
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
    # correlation_id == task.id quand un work item existe
    assert ev.correlation_id == t.id
    assert Fleet.Event.valid_source?(ev.source)
  end

  test "11. submit_result avec work_item_id ≠ work item actif → :work_item_id_mismatch (§A.70, pas de mutation)",
       %{q: q} do
    {:ok, t} = TaskQueue.enqueue(q, "pod-A", %{brief: "x"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-A")
    assert_receive %Fleet.Event{type: :"work_item.enqueued"}
    assert_receive %Fleet.Event{type: :"work_item.assigned"}

    # Le pod renvoie un work_item_id forgé/périmé ≠ son work item actif → rejet.
    assert {:error, :work_item_id_mismatch} =
             TaskQueue.submit_result(q, "pod-A", %{
               "work_item_id" => "forged-uuid",
               "verdict" => "x"
             })

    # Aucune mutation : le work item reste actif, pas de :"work_item.completed".
    assert {:ok, :assigned} = TaskQueue.pod_status(q, "pod-A")
    refute_receive %Fleet.Event{type: :"work_item.completed"}, 100

    # Avec le bon work_item_id → OK.
    assert {:ok, _} =
             TaskQueue.submit_result(q, "pod-A", %{"work_item_id" => t.id, "verdict" => "ok"})

    assert_receive %Fleet.Event{type: :"work_item.completed"}
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

    # + un work item ACTIF : ne doit JAMAIS être élagué.
    {:ok, _} = TaskQueue.enqueue(q, "pod-active", %{brief: "en cours"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-active")

    work_items = :sys.get_state(q).work_items |> Map.values()
    terminal = Enum.filter(work_items, &(&1.state == :completed))
    active = Enum.filter(work_items, &(&1.state in [:pending, :assigned, :in_progress]))

    # Borne dure : 5 complétées → au plus 3 conservées (2 élaguées).
    assert length(terminal) == 3
    # L'active survit toujours (jamais comptée ni coupée).
    assert [%{pod_id: "pod-active", state: :assigned}] = active

    # Le plus récent complété (pod-5) survit → double-submit TOUJOURS détecté, pas dégradé
    # en :no_active_work_item par une rétention qui couperait la mauvaise tâche (récence, pas FIFO).
    assert {:error, :double_submit_ignored} =
             TaskQueue.submit_result(q, "pod-5", %{"verdict" => "retry"})
  end

  # MA-27 — invariant « 1 work item ACTIF/pod » tenu À L'ÉCRITURE. Un re-brief d'un pod portant une
  # `:assigned` existante doit la SUPERSÉDER (→ `:cleared`) : sinon la vieille `:assigned` FUYAIT à côté du
  # nouveau pending (invisible aux gardes — `find_active`/`max_by` la masquait sans la retirer). RED avant le
  # fix (`supersede_pending` gardait les `:assigned`) → 2 actives ; GREEN après (`supersede_active`) → 1.
  test "MA-27 re-brief d'un pod avec :assigned existante → 1 SEULE active (l'ancienne :cleared)",
       %{
         q: q
       } do
    {:ok, old} = TaskQueue.enqueue(q, "pod-Z", %{brief: "ancien work item"})
    # pull → l'ancien passe :assigned (le pod « travaille dessus »).
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-Z")
    assert {:ok, :assigned} = TaskQueue.pod_status(q, "pod-Z")

    # RE-BRIEF : un nouveau work item frais (re-dispatch forge) arrive PENDANT l'ancien :assigned.
    {:ok, fresh} = TaskQueue.enqueue(q, "pod-Z", %{brief: "nouveau work item"})

    work_items = :sys.get_state(q).work_items |> Map.values()

    active =
      Enum.filter(
        work_items,
        &(&1.pod_id == "pod-Z" and &1.state in [:pending, :assigned, :in_progress])
      )

    # 1 SEULE active = le frais (:pending). L'ancien :assigned est superséded → :cleared.
    assert [%{state: :pending} = only] = active
    assert only.id == fresh.id

    old_now = Enum.find(work_items, &(&1.id == old.id))
    assert old_now.state == :cleared

    # Sémantique re-brief validée : le pod prend le NOUVEAU work item au prochain pull (seul actif restant).
    fresh_id = fresh.id
    assert {:ok, %{brief: "nouveau work item", id: ^fresh_id}} = TaskQueue.get_for_pod(q, "pod-Z")

    # Et le vieux work item ne peut plus muter la queue : son submit tombe sur une active = le frais
    # (work_item_id mismatch) — jamais une complétion de l'ancien fantôme.
    assert {:error, :work_item_id_mismatch} =
             TaskQueue.submit_result(q, "pod-Z", %{"work_item_id" => old.id, "verdict" => "stale"})
  end

  # MA-27 — `clear_for_pod` purge TOUTES les actives du pod (pas seulement la + récente via `find_active`).
  # Avec l'invariant tenu à l'enqueue il n'y en a normalement qu'une ; le test pose volontairement DEUX
  # actives (en court-circuitant l'unicité via la map d'état directe) pour prouver que clear est TOTAL.
  test "MA-27 clear_for_pod purge TOUTES les actives du pod (clear total, pas seulement la + récente)",
       %{
         q: q
       } do
    {:ok, t1} = TaskQueue.enqueue(q, "pod-M", %{brief: "m1"})
    {:ok, _} = TaskQueue.get_for_pod(q, "pod-M")

    # Injecte une 2e active (:assigned) pour le MÊME pod, en contournant supersede_active (qui en prod
    # garantit l'unicité) — on veut prouver que clear_for_pod ne LAISSE PAS de stale même s'il y en avait.
    :sys.replace_state(q, fn st ->
      ghost = %Fleet.TaskQueue.WorkItem{
        id: "ghost-uuid",
        pod_id: "pod-M",
        enqueued_at: DateTime.add(t1.enqueued_at, -60, :second),
        state: :assigned
      }

      %{st | work_items: Map.put(st.work_items, ghost.id, ghost)}
    end)

    assert :ok = TaskQueue.clear_for_pod(q, "pod-M")

    work_items = :sys.get_state(q).work_items |> Map.values()

    active =
      Enum.filter(
        work_items,
        &(&1.pod_id == "pod-M" and &1.state in [:pending, :assigned, :in_progress])
      )

    assert active == []
    assert Enum.all?(work_items, &(&1.pod_id != "pod-M" or &1.state == :cleared))
  end
end
