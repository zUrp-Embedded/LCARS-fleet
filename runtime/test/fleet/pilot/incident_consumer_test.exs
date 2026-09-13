defmodule Fleet.Pilot.IncidentConsumerTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.IncidentConsumer

  # Direct events, synchronous callbacks and a local routing table isolate routing
  # from Bus delivery, global configuration and the registry's escalation policy.
  defp routing do
    %{
      {:spawner, :"pod.failed"} => %{
        action: :incident,
        incident: %{op: "pod", subject: "pod_id", escalate_kind: nil, forward: []}
      },
      {:spawner, :"wake.failed"} => %{
        action: :incident,
        incident: %{op: "wake", subject: "pod_id", escalate_kind: :sp_suspect, forward: [:pane]}
      },
      {:spawner, :"spawn.failed"} => %{
        action: :incident,
        incident: %{op: "spawn", subject: "cap_profile_name", escalate_kind: nil, forward: []}
      },
      {:workflow, :"workflow_map.failed"} => %{
        action: :incident,
        incident: %{
          op: "workflow_map",
          subject: "workflow_map",
          gate: :immediate,
          escalate_kind: :workflow_map_failed,
          forward: []
        }
      }
    }
  end

  defp start(record_fun, opts \\ []) do
    start_supervised!(
      {IncidentConsumer,
       [subscribe: false, record_fun: record_fun, routing_fun: fn -> routing() end] ++ opts}
    )
  end

  defp echo_fun do
    me = self()

    fn op, subject, reason, opts ->
      send(me, {:rec, op, subject, reason, opts})
      :recorded
    end
  end

  defp failed_event(type, payload),
    do: Fleet.Event.new(:spawner, type, payload: payload)

  describe "LE FREIN (BL-6-37.6) — detecter la recurrence sans debrancher fabriquait un compteur" do
    defp brake_spy do
      me = self()
      fn repo, number, reason -> send(me, {:brake, repo, number, reason}) end
    end

    defp brake_event(payload),
      do: failed_event(:"pod.failed", Map.merge(%{"pod_id" => "pod_1"}, payload))

    defp start_with(outcome, extra \\ []) do
      start(fn _op, _s, _r, _o -> outcome end, [brake_fun: brake_spy()] ++ extra)
    end

    test "recurrence ESCALADEE sur un result_timeout → le ticket sort du dispatch" do
      pid = start_with({:escalated, 77})

      send(
        pid,
        brake_event(%{
          "repo" => "fleet/demo",
          "issue_id" => "issue-42",
          "reason" => "result_timeout"
        })
      )

      assert_receive {:brake, "fleet/demo", 42, "result_timeout"}, 500
    end

    test "recurrence SOUS COOLDOWN → le frein s'applique AUSSI (c'est la que vit la boucle)" do
      # Cooldown suppresses sysadmin issue creation, not the work-ticket brake.
      pid = start_with({:escalation_suppressed, 77})

      send(
        pid,
        brake_event(%{
          "repo" => "fleet/demo",
          "issue_id" => "issue-42",
          "reason" => "result_timeout"
        })
      )

      assert_receive {:brake, "fleet/demo", 42, _}, 500
    end

    test "PREMIERE occurrence → AUCUN frein (une panne isolee peut etre du hasard)" do
      pid = start_with(:recorded)

      send(
        pid,
        brake_event(%{
          "repo" => "fleet/demo",
          "issue_id" => "issue-42",
          "reason" => "result_timeout"
        })
      )

      refute_receive {:brake, _, _, _}, 200
    end

    test "recurrence sur une AUTRE categorie → aucun frein (restriction deliberee)" do
      # Other failures may be recoverable through rework; braking is deliberately narrow.
      pid = start_with({:escalated, 77})

      send(
        pid,
        brake_event(%{
          "repo" => "fleet/demo",
          "issue_id" => "issue-42",
          "reason" => "exited_before_result"
        })
      )

      refute_receive {:brake, _, _, _}, 200
    end

    test "payload SANS depot → aucun frein, et aucun crash du rail d'incident" do
      # An issue number without a repository cannot identify the ticket to brake.
      pid = start_with({:escalated, 77})

      send(pid, brake_event(%{"issue_id" => "issue-42", "reason" => "result_timeout"}))

      refute_receive {:brake, _, _, _}, 200
      assert Process.alive?(pid)
    end
  end

  test "pod.failed → record_or_escalate(\"pod\", pod_id, reason, reason_detail threaded)" do
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"pod.failed", %{
        "pod_id" => "pod_1",
        "reason" => "result_timeout",
        "reason_detail" => "{:result_timeout, \"pod_1\"}"
      })
    )

    # `reason` = stable category (key of the dedup signature); the full detail travels as an opt
    # down to the issue body (Escalation.detail_block) without polluting the signature.
    assert_receive {:rec, "pod", "pod_1", "result_timeout", opts}
    assert Keyword.get(opts, :reason_detail) == "{:result_timeout, \"pod_1\"}"
  end

  test "wake.failed → record_or_escalate(\"wake\", …, escalate_kind: :sp_suspect, pane:)" do
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"wake.failed", %{
        "pod_id" => "pod_2",
        "reason" => "no_ack",
        "pane" => "sess:1.2"
      })
    )

    assert_receive {:rec, "wake", "pod_2", "no_ack", opts}
    assert Keyword.get(opts, :escalate_kind) == :sp_suspect
    assert Keyword.get(opts, :pane) == "sess:1.2"

    # Payload without reason_detail (pre-normalization producer or forged event) → nil, never a crash.
    assert Keyword.get(opts, :reason_detail) == nil
  end

  test "the classification is DATA: re-declaring the op in the table changes the recording, zero code" do
    # Changing the table must change routing for the same event.
    me = self()

    fun = fn op, subject, reason, opts ->
      send(me, {:rec, op, subject, reason, opts})
      :recorded
    end

    pid =
      start_supervised!(
        {IncidentConsumer,
         subscribe: false,
         record_fun: fun,
         routing_fun: fn ->
           %{
             {:spawner, :"wake.failed"} => %{
               action: :incident,
               incident: %{op: "reveil", subject: "pod_id", escalate_kind: nil, forward: []}
             }
           }
         end}
      )

    send(pid, failed_event(:"wake.failed", %{"pod_id" => "pod_9", "reason" => "no_ack"}))
    assert_receive {:rec, "reveil", "pod_9", "no_ack", _opts}
  end

  test "a routed incident whose subject key is MISSING → LOUD producer-bug warning, nothing recorded" do
    me = self()

    pid =
      start(fn _, _, _, _ ->
        send(me, :rec)
        :recorded
      end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        send(pid, failed_event(:"pod.failed", %{"reason" => "boom", "no_pod_id" => true}))
        refute_receive :rec, 100
      end)

    assert log =~ "producer bug"
  end

  test "failure event without pod_id → ignored (no record)" do
    me = self()

    pid =
      start(fn _, _, _, _ ->
        send(me, :rec)
        :recorded
      end)

    send(pid, failed_event(:"pod.failed", %{"reason" => "boom"}))

    refute_receive :rec, 100
  end

  test "out-of-scope event (other type) → ignored" do
    me = self()

    pid =
      start(fn _, _, _, _ ->
        send(me, :rec)
        :recorded
      end)

    send(pid, failed_event(:"pod.completed", %{"pod_id" => "pod_3"}))

    refute_receive :rec, 100
  end

  test "spawn.failed → record_or_escalate(\"spawn\", cap_profile_name, reason, opts)" do
    # Group failed spawns by role rather than per-request issue identity.
    pid = start(echo_fun())

    send(
      pid,
      failed_event(:"spawn.failed", %{
        "cap_profile_name" => "reviewer",
        "issue_id" => "issue_42",
        "reason" => "boom"
      })
    )

    assert_receive {:rec, "spawn", "reviewer", "boom", opts}
    assert Keyword.get(opts, :reason_detail) == nil
  end

  test "spawn.failed without cap_profile_name → ignored (guard)" do
    me = self()

    pid =
      start(fn _, _, _, _ ->
        send(me, :rec)
        :recorded
      end)

    send(pid, failed_event(:"spawn.failed", %{"reason" => "boom"}))

    refute_receive :rec, 100
  end

  describe "gate: immediate — la porte est un champ de la route, pas une classe de severite" do
    test "issue des la 1re occurrence : escalate_fun recoit le kind DECLARE et la signature op:sujet" do
      pid = self()

      consumer =
        start(fn _, _, _, _ -> flunk("gate=immediate ne passe JAMAIS par record_or_escalate") end,
          escalate_fun: fn kind, subject, reason, sig, _opts ->
            send(pid, {:escalated, kind, subject, reason, sig})
            {:ok, 42}
          end
        )

      send(
        consumer,
        Fleet.Event.new(:workflow, :"workflow_map.failed",
          payload: %{"workflow_map" => "standard-qa", "reason" => "yaml illisible"}
        )
      )

      assert_receive {:escalated, :workflow_map_failed, "standard-qa", "yaml illisible",
                      "workflow_map:standard-qa"},
                     500
    end

    test "gate ABSENT de la table = recurrence (le defaut du YAML, pas un crash)" do
      pid = self()

      # La route pod.failed du harnais ne porte PAS :gate — elle doit passer par record_or_escalate.
      consumer =
        start(fn op, subject, _r, _o ->
          send(pid, {:recorded, op, subject})
          :recorded
        end)

      send(
        consumer,
        Fleet.Event.new(:spawner, :"pod.failed", payload: %{"pod_id" => "pod-7", "reason" => "x"})
      )

      assert_receive {:recorded, "pod", "pod-7"}, 500
    end
  end
end
