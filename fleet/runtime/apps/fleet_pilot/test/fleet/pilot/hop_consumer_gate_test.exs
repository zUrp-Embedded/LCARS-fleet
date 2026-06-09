defmodule Fleet.Pilot.HopConsumerGateTest do
  @moduledoc """
  A2.3 / B (§L441) — la gate du stage FINI décide la fin-de-hop (DN forge-state-machine §9).
  On pilote `HopConsumer.maybe_complete` (avec le VRAI `HopCompleter`) contre un sim forge +
  des cartes gatées, et on prouve :

    * gate `:pass`              → avance (next_stage)
    * gate `{:fail}`            → rebond vers le 1er stage, BORNÉ (budget hops)
    * budget épuisé             → `{:error, {:rework_exhausted, _}}` (aucune écriture forge)
    * gate `soft`/non-tranchable (B) → ESCALADE : `{:escalate, corr, ctx}` + mandat enqueué
      au gatekeeper permanent (PAS un stage `role: gatekeeper`). La décision revient async ;
      `resume_gate/3` route : continue→avance, abandon→close, humain→await_human.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.HopConsumer

  # ── Sim forge : capture les writes via send(self()), sert un compteur de hops
  #    configurable par `forge_opts[:_hops]` (le bound lit count_signed_hops). ──
  defmodule StubForge do
    def post_comment(_r, _n, body, _o), do: send(self(), {:comment, body}) && {:ok, :posted}
    def set_state_label(_r, _n, _s, _o), do: {:ok, :set}
    def set_assignee(_r, _n, login, _o), do: send(self(), {:assignee, login}) && {:ok, :set}
    def post_route(_r, _n, p, s, _o), do: send(self(), {:route, p, s}) && {:ok, :posted}
    def remove_label(_r, _n, _l, _o), do: send(self(), :unlocked) && {:ok, :removed}
    def add_label(_r, _n, label, _o), do: send(self(), {:label, label}) && {:ok, :added}
    def close_issue(_r, _n, _o), do: send(self(), :closed) && {:ok, :closed}
    def count_signed_hops(_r, _n, opts), do: {:ok, Keyword.get(opts, :_hops, 0)}
  end

  defmodule DelivStub do
    def publish(o) do
      send(self(), {:publish, o})
      {:ok, %{commit_sha: "sha-x", pushed?: true, mode: Map.get(o, :mode, :git_native)}}
    end
  end

  # B — broker de mandats stub : capture l'enqueue, rend un correlation_id stable.
  defmodule StubQueue do
    def enqueue(pod_id, attrs) do
      send(self(), {:enqueue, pod_id, attrs})
      {:ok, %{id: "corr-1"}}
    end
  end

  defmodule StubSpawner do
    def wake_pod(pod_id), do: send(self(), {:wake, pod_id}) && :ok
  end

  # Cartes 2 stages. `gated` : hard gate sur triage (exige result %{"ok"=>true}).
  # `soft` : soft gate sur triage (B → escalade gatekeeper). `plain` : aucune gate.
  defmodule Carte do
    def load!("gated") do
      %{
        "name" => "gated",
        "stages" => %{
          "triage" => %{
            "role" => "architect",
            "needs" => [],
            "gate" => %{"type" => "hard", "rule" => %{"ok" => true}}
          },
          "build" => %{"role" => "engineer", "needs" => ["triage"]}
        }
      }
    end

    def load!("soft") do
      %{
        "name" => "soft",
        "stages" => %{
          "triage" => %{"role" => "architect", "needs" => [], "gate" => %{"type" => "soft"}},
          "build" => %{"role" => "engineer", "needs" => ["triage"]}
        }
      }
    end

    def load!("plain") do
      %{
        "name" => "plain",
        "stages" => %{
          "triage" => %{"role" => "architect", "needs" => []},
          "build" => %{"role" => "engineer", "needs" => ["triage"]}
        }
      }
    end
  end

  defp hc(opts \\ []) do
    %HopConsumer{
      repo: "o/r",
      remote: "origin",
      forge_opts: Keyword.get(opts, :forge_opts, []),
      role_emails: fn r -> ["#{r}@lcars.local"] end,
      hop_completer: Fleet.Pilot.HopCompleter,
      forge_client: StubForge,
      loader: Carte,
      deliverable: DelivStub,
      max_rework_rounds: Keyword.get(opts, :max_rework_rounds, 2),
      task_queue: StubQueue,
      spawner: StubSpawner,
      gatekeeper_pod_id_fun:
        Keyword.get(opts, :gatekeeper_pod_id_fun, fn -> "gatekeeper-permanent" end),
      gate_evals: %{}
    }
  end

  # pod.completed du stage `triage` qui vient de finir, avec son `result`.
  defp triage_done(pipeline, result) do
    %{
      "ticket_id" => "issue-1",
      "workspace" => "/ws",
      "base_sha" => "cafe",
      "role" => "architect",
      "pipeline" => pipeline,
      "stage" => "triage",
      "result" => result
    }
  end

  # contexte de reprise tel que le construit gate_decide à l'escalade (carte "soft").
  defp soft_ctx do
    %{
      n: 1,
      role: "architect",
      payload: triage_done("soft", %{"x" => 1}),
      carte: Carte.load!("soft"),
      stage: "triage"
    }
  end

  # ── Happy path : pass / fail / budget (inchangé vs A2.3) ──────────────────────

  test "gate :pass → avance vers build (engineer)" do
    assert {:ok, :reassigned} =
             HopConsumer.maybe_complete(triage_done("gated", %{"ok" => true}), hc())

    assert_received {:route, "gated", "build"}
    assert_received {:assignee, "engineer"}
    assert_received :unlocked
  end

  test "pas de gate sur le stage → avance (comportement A2 inchangé)" do
    assert {:ok, :reassigned} = HopConsumer.maybe_complete(triage_done("plain", %{}), hc())
    assert_received {:route, "plain", "build"}
    assert_received {:assignee, "engineer"}
  end

  test "gate {:fail} sous budget → rebond vers le 1er stage (triage/architect)" do
    payload = triage_done("gated", %{})

    assert {:ok, :reassigned} = HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 0]))
    assert_received {:route, "gated", "triage"}
    assert_received {:assignee, "architect"}
    assert_received :unlocked
  end

  test "gate {:fail} mais budget épuisé → rework_exhausted, AUCUNE écriture forge" do
    # budget = nb_stages(2) * (max_rework_rounds(2) + 1) = 6
    payload = triage_done("gated", %{})

    assert {:error, {:rework_exhausted, %{hops: 6, budget: 6}}} =
             HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 6]))

    refute_received {:assignee, _}
    refute_received {:route, _, _}
    refute_received :unlocked
    refute_received :closed
  end

  test "budget : juste sous la limite rebondit, pile à la limite s'arrête" do
    payload = triage_done("gated", %{})
    assert {:ok, :reassigned} = HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 5]))

    assert {:error, {:rework_exhausted, _}} =
             HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 6]))
  end

  test "hop ordinaire (non-gatekeeper) → livrable git_native (le pod a commité)" do
    assert {:ok, :reassigned} = HopConsumer.maybe_complete(triage_done("plain", %{}), hc())
    assert_received {:publish, d}
    assert d.mode == :git_native
    refute Map.has_key?(d, :files)
  end

  # ── B (§L441) : escalade gatekeeper (gate soft sur un stage MÉTIER) ───────────

  test "gate soft sur stage métier → ESCALADE : mandat enqueué, AUCUNE avance/écriture forge" do
    # En B, une gate soft sur un stage métier (architect) n'est PAS une carte malformée :
    # elle dispatche le gatekeeper permanent (juge d'exception). Pas de stage role:gatekeeper.
    assert {:escalate, "corr-1", ctx} =
             HopConsumer.maybe_complete(triage_done("soft", %{"sev" => "high"}), hc())

    assert ctx.stage == "triage"
    assert ctx.role == "architect"

    assert_received {:enqueue, "gatekeeper-permanent", attrs}
    assert attrs.role == "gatekeeper"
    assert attrs.metadata["gate_eval"] == true
    assert attrs.metadata["stage"] == "triage"
    assert is_binary(attrs.brief)
    # outputs DÉPLIÉS portés au juge (le worker peut envelopper) :
    assert attrs.metadata["outputs"] == %{"sev" => "high"}
    # kick best-effort du gatekeeper permanent.
    assert_received {:wake, "gatekeeper-permanent"}

    # rien d'avancé avant le verdict (l'issue reste verrouillée) :
    refute_received {:assignee, _}
    refute_received :unlocked
    refute_received :closed
  end

  test "escalade : outputs ENVELOPPÉS %{status,result} → dépliés avant le brief (#2)" do
    enveloped = %{"status" => "ok", "result" => %{"sev" => "low"}}

    assert {:escalate, "corr-1", _ctx} =
             HopConsumer.maybe_complete(triage_done("soft", enveloped), hc())

    assert_received {:enqueue, _pod, attrs}
    assert attrs.metadata["outputs"] == %{"sev" => "low"}
  end

  test "escalade : pas de gatekeeper booté → fail-loud (jamais un pass silencieux)" do
    state = hc(gatekeeper_pod_id_fun: fn -> nil end)

    assert {:error, {:gatekeeper_dispatch, :no_gatekeeper}} =
             HopConsumer.maybe_complete(triage_done("soft", %{}), state)

    refute_received {:assignee, _}
    refute_received :unlocked
  end

  # ── B : reprise sur le verdict du gatekeeper (resume_gate/3) ──────────────────

  test "verdict continue → avance (push business git_native + reassign) + trace" do
    assert {:ok, :reassigned} =
             HopConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "continue", "reason" => "RAS"}},
               hc()
             )

    assert_received {:route, "soft", "build"}
    assert_received {:assignee, "engineer"}
    assert_received {:publish, d}
    assert d.mode == :git_native
    assert_received {:comment, body}
    assert body =~ "gatekeeper"
    assert body =~ "continue"
    assert_received :unlocked
  end

  test "verdict continue ENVELOPPÉ %{status,result} → déplié (gate_result), avance" do
    raw = %{result: %{"status" => "ok", "result" => %{"decision" => "continue"}}}
    assert {:ok, :reassigned} = HopConsumer.resume_gate(soft_ctx(), raw, hc())
    assert_received {:assignee, "engineer"}
  end

  test "verdict abandon → close (terminal), PAS de push business (travail rejeté)" do
    assert {:ok, :completed} =
             HopConsumer.resume_gate(soft_ctx(), %{"result" => %{"decision" => "abandon"}}, hc())

    assert_received :closed
    refute_received {:publish, _}
    refute_received {:assignee, _}
  end

  test "verdict escalate_user → await_human (lcars-awaits-human + unlock, pas close/reassign)" do
    assert {:ok, :awaiting_human} =
             HopConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "escalate_user"}},
               hc()
             )

    assert_received {:label, "lcars-awaits-human"}
    assert_received :unlocked
    refute_received {:assignee, _}
    refute_received :closed
  end

  test "verdict halt_wait_input → await_human" do
    assert {:ok, :awaiting_human} =
             HopConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "halt_wait_input"}},
               hc()
             )

    assert_received {:label, "lcars-awaits-human"}
  end

  test "verdict redirect → await_human (différé A2.x, pas de routage hors-DAG)" do
    assert {:ok, :awaiting_human} =
             HopConsumer.resume_gate(soft_ctx(), %{"result" => %{"decision" => "redirect"}}, hc())

    assert_received {:label, "lcars-awaits-human"}
    refute_received {:assignee, _}
  end

  test "verdict absent/invalide → await_human (fail-closed, jamais continue silencieux)" do
    assert {:ok, :awaiting_human} =
             HopConsumer.resume_gate(soft_ctx(), %{"result" => %{}}, hc())

    assert_received {:label, "lcars-awaits-human"}
    refute_received {:assignee, _}
    refute_received :closed
  end

  # ── B : câblage async (GenServer) — store gate_evals à l'escalade, pop à la reprise ──

  test "GenServer : pod.completed soft → gate_evals stocké ; task_completed corrélé → pop" do
    {:ok, pid} =
      HopConsumer.start_link(
        repo: "o/r",
        remote: "origin",
        subscribe: false,
        forge_client: StubForge,
        loader: Carte,
        deliverable: DelivStub,
        task_queue: StubQueue,
        spawner: StubSpawner,
        gatekeeper_pod_id_fun: fn -> "gk-perm" end,
        role_emails: fn r -> ["#{r}@lcars.local"] end
      )

    # 1. business soft → escalade → gate_evals["corr-1"] présent
    send(pid, %Fleet.Event{
      source: :spawner,
      type: :"pod.completed",
      timestamp: DateTime.utc_now(),
      payload: triage_done("soft", %{})
    })

    state = :sys.get_state(pid)
    assert Map.has_key?(state.gate_evals, "corr-1")
    assert %{stage: "triage"} = state.gate_evals["corr-1"]

    # 2. verdict du gatekeeper (corrélé) → resume + pop
    send(pid, %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      correlation_id: "corr-1",
      timestamp: DateTime.utc_now(),
      payload: %{result: %{"decision" => "continue"}}
    })

    assert %{gate_evals: evals} = :sys.get_state(pid)
    refute Map.has_key?(evals, "corr-1")
  end

  test "GenServer : task_completed d'un corr inconnu → ignoré (pas de crash)" do
    {:ok, pid} =
      HopConsumer.start_link(repo: "o/r", remote: "origin", subscribe: false, loader: Carte)

    send(pid, %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      correlation_id: "inconnu",
      timestamp: DateTime.utc_now(),
      payload: %{result: %{"decision" => "continue"}}
    })

    assert %{gate_evals: evals} = :sys.get_state(pid)
    assert evals == %{}
  end
end
