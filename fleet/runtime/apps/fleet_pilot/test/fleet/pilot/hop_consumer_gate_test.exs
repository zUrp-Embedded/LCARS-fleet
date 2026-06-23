defmodule Fleet.Pilot.HopConsumerGateTest do
  @moduledoc """
  A2.3 / B (L441) — la gate du stage FINI decide la fin-de-hop. Corr.3 engineer-first : le stage
  producteur (engineer, git_native) finit, sa gate decide, et le hop est PR-natif :

    * gate :pass               -> avance (request_review du juge suivant + pont set_assignee)
    * gate {:fail}             -> rebond producteur (re-dispatch, PAS de PR), BORNE (budget hops)
    * budget epuise            -> {:error, {:rework_exhausted, _}} (aucune ecriture forge)
    * gate soft/non-tranchable -> ESCALADE gatekeeper (inchange) ; le verdict revient async :
      resume_gate continue->avance(PR), abandon->close(5), humain->await_arch(5).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.HopConsumer

  # Sim forge : §5 (abandon/await) + primitives PR (Corr.3). Compteur de hops via forge_opts[:_hops].
  defmodule StubForge do
    def post_comment(_r, _n, body, _o), do: send(self(), {:comment, body}) && {:ok, :posted}
    def set_state_label(_r, _n, _s, _o), do: {:ok, :set}
    def set_assignee(_r, _n, login, _o), do: send(self(), {:assignee, login}) && {:ok, :set}
    def remove_label(_r, _n, _l, _o), do: send(self(), :unlocked) && {:ok, :removed}
    def add_label(_r, _n, label, _o), do: send(self(), {:label, label}) && {:ok, :added}
    def close_issue(_r, _n, _o), do: send(self(), :closed) && {:ok, :closed}
    def count_signed_hops(_r, _n, opts), do: {:ok, Keyword.get(opts, :_hops, 0)}
    def post_route(_r, _n, p, s, _o), do: send(self(), {:route, p, s}) && {:ok, :posted}

    def open_pr(_r, head, base, _t, o),
      do: send(self(), {:open_pr, head, base, o[:body]}) && {:ok, 7}

    def get_pr_for_branch(_r, head, base, _o), do: send(self(), {:get_pr, head, base}) && {:ok, 7}
    # #8.E : un juge de MANDAT (mandate-review) est PRÉ-PR → aucune PR producteur ouverte.
    def list_open_pulls(_r, _o), do: {:ok, []}
    def request_review(_r, pr, revs, _o), do: send(self(), {:request_review, pr, revs}) && :ok
    def post_review(_r, pr, ev, body, _o), do: send(self(), {:review, pr, ev, body}) && :ok
    def merge_pr(_r, pr, _o), do: send(self(), {:merge, pr}) && :ok
  end

  defmodule DelivStub do
    def publish(o) do
      send(self(), {:publish, o})
      {:ok, %{commit_sha: "sha-x", pushed?: true, mode: Map.get(o, :mode, :git_native)}}
    end
  end

  defmodule StubQueue do
    def enqueue(pod_id, attrs) do
      send(self(), {:enqueue, pod_id, attrs})
      {:ok, %{id: "corr-1"}}
    end
  end

  defmodule StubSpawner do
    def wake_pod(pod_id), do: send(self(), {:wake, pod_id}) && :ok
  end

  # Cartes engineer-first 2 stages : build(engineer, producteur) -> review(reviewer, juge).
  # `gated` : hard gate sur build. `soft` : soft gate sur build (B -> escalade). `plain` : aucune.
  defmodule Carte do
    def load!("gated") do
      %{
        "name" => "gated",
        "stages" => %{
          "build" => %{
            "role" => "engineer",
            "needs" => [],
            "gate" => %{"type" => "hard", "rule" => %{"ok" => true}}
          },
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    def load!("soft") do
      %{
        "name" => "soft",
        "stages" => %{
          "build" => %{"role" => "engineer", "needs" => [], "gate" => %{"type" => "soft"}},
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    def load!("plain") do
      %{
        "name" => "plain",
        "stages" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    # #8.E : carte mandate-gate — stage racine mandate-review (consultant JUGE le MANDAT, pré-PR) -> build.
    def load!("mandgate") do
      %{
        "name" => "mandgate",
        "stages" => %{
          "mandate-review" => %{
            "role" => "consultant",
            "needs" => [],
            "mandate_kind" => "judge",
            "judge_target" => "mandate"
          },
          "build" => %{"role" => "engineer", "needs" => ["mandate-review"]}
        }
      }
    end
  end

  defp dmode,
    do: fn
      "engineer" -> "git_native"
      _ -> "payload"
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
      deliverable_mode_fun: dmode(),
      max_rework_rounds: Keyword.get(opts, :max_rework_rounds, 2),
      task_queue: StubQueue,
      spawner: StubSpawner,
      gatekeeper_pod_id_fun:
        Keyword.get(opts, :gatekeeper_pod_id_fun, fn -> "gatekeeper-permanent" end),
      gate_evals: %{}
    }
  end

  # pod.completed du stage producteur `build` (engineer) qui vient de finir, avec son result.
  defp build_done(pipeline, result) do
    %{
      "ticket_id" => "issue-1",
      "workspace" => "/ws",
      "base_sha" => "cafe",
      "role" => "engineer",
      "pipeline" => pipeline,
      "stage" => "build",
      "result" => result
    }
  end

  # contexte de reprise tel que le construit gate_decide a l'escalade (carte "soft").
  defp soft_ctx do
    %{
      n: 1,
      role: "engineer",
      payload: build_done("soft", %{"x" => 1}),
      carte: Carte.load!("soft"),
      stage: "build"
    }
  end

  # ── Happy path : pass / fail / budget ────────────────────────────────────────

  test "gate :pass -> producteur :advance : ouvre la PR, request_review(reviewer), grave la route" do
    assert {:ok, :review_requested} =
             HopConsumer.maybe_complete(build_done("gated", %{"ok" => true}), hc())

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}

    # plus de set_assignee (PR-driven) : la position carte est gravee (route), le trigger = la review
    refute_received {:assignee, _}
    assert_received {:route, "gated", "review"}
    assert_received :unlocked
  end

  test "pas de gate sur le stage -> avance (comportement inchange)" do
    assert {:ok, :review_requested} = HopConsumer.maybe_complete(build_done("plain", %{}), hc())
    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}
    refute_received {:assignee, _}
    assert_received {:route, "plain", "review"}
  end

  test "gate {:fail} sous budget -> rebond producteur (engineer), PAS de PR" do
    payload = build_done("gated", %{})

    assert {:ok, :rework_requested} =
             HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 0]))

    # producteur rework : pas de set_assignee (l'engineer reste assigne par Entry) ; route rebondie
    refute_received {:assignee, _}
    assert_received {:route, "gated", "build"}
    assert_received :unlocked
    refute_received {:open_pr, _, _, _}
  end

  test "gate {:fail} mais budget epuise -> rework_exhausted, AUCUNE ecriture forge" do
    # budget = nb_stages(2) * (max_rework_rounds(2) + 1) = 6
    payload = build_done("gated", %{})

    assert {:error, {:rework_exhausted, %{hops: 6, budget: 6}}} =
             HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 6]))

    refute_received {:assignee, _}
    refute_received {:open_pr, _, _, _}
    refute_received :unlocked
    refute_received :closed
  end

  test "budget : juste sous la limite rebondit, pile a la limite s'arrete" do
    payload = build_done("gated", %{})

    assert {:ok, :rework_requested} =
             HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 5]))

    assert {:error, {:rework_exhausted, _}} =
             HopConsumer.maybe_complete(payload, hc(forge_opts: [_hops: 6]))
  end

  test "hop producteur ordinaire -> livrable git_native (le pod a commite) pousse a l'ouverture PR" do
    assert {:ok, :review_requested} = HopConsumer.maybe_complete(build_done("plain", %{}), hc())
    assert_received {:publish, d}
    assert d.mode == :git_native
    refute Map.has_key?(d, :files)
  end

  # ── B (L441) : escalade gatekeeper (gate soft sur le stage producteur) ────────

  test "gate soft -> ESCALADE : mandat enqueue, AUCUNE avance/ecriture forge" do
    assert {:escalate, "corr-1", ctx} =
             HopConsumer.maybe_complete(build_done("soft", %{"sev" => "high"}), hc())

    assert ctx.stage == "build"
    assert ctx.role == "engineer"

    assert_received {:enqueue, "gatekeeper-permanent", attrs}
    assert attrs.role == "gatekeeper"
    assert attrs.metadata["gate_eval"] == true
    assert attrs.metadata["stage"] == "build"
    assert is_binary(attrs.brief)
    assert attrs.metadata["outputs"] == %{"sev" => "high"}
    assert_received {:wake, "gatekeeper-permanent"}

    refute_received {:assignee, _}
    refute_received {:open_pr, _, _, _}
    refute_received :unlocked
  end

  test "escalade : outputs ENVELOPPES %{status,result} -> deplies avant le brief (#2)" do
    enveloped = %{"status" => "ok", "result" => %{"sev" => "low"}}

    assert {:escalate, "corr-1", _ctx} =
             HopConsumer.maybe_complete(build_done("soft", enveloped), hc())

    assert_received {:enqueue, _pod, attrs}
    assert attrs.metadata["outputs"] == %{"sev" => "low"}
  end

  test "escalade : pas de gatekeeper boote -> fail-loud (jamais un pass silencieux)" do
    state = hc(gatekeeper_pod_id_fun: fn -> nil end)

    assert {:error, {:gatekeeper_dispatch, :no_gatekeeper}} =
             HopConsumer.maybe_complete(build_done("soft", %{}), state)

    refute_received {:assignee, _}
    refute_received :unlocked
  end

  # ── B : reprise sur le verdict du gatekeeper (resume_gate/3) ──────────────────
  # NB Corr.3 : continue passe par complete_pr (PR-natif). La trace verdict n'est PAS encore
  # materialisee sur la PR (gap transitionnel) ; abandon/await gardent la sequence §5 (trace ok).

  test "verdict continue -> producteur :advance (ouvre PR + request_review + route)" do
    assert {:ok, :review_requested} =
             HopConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "continue", "reason" => "RAS"}},
               hc()
             )

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}
    refute_received {:assignee, _}
    assert_received {:route, "soft", "review"}
    assert_received {:publish, d}
    assert d.mode == :git_native
    assert_received :unlocked
  end

  test "verdict continue ENVELOPPE %{status,result} -> deplie (gate_result), avance" do
    raw = %{result: %{"status" => "ok", "result" => %{"decision" => "continue"}}}
    assert {:ok, :review_requested} = HopConsumer.resume_gate(soft_ctx(), raw, hc())
    assert_received {:route, "soft", "review"}
  end

  test "verdict abandon -> close (terminal §5), PAS de push business (travail rejete)" do
    assert {:ok, :completed} =
             HopConsumer.resume_gate(soft_ctx(), %{"result" => %{"decision" => "abandon"}}, hc())

    assert_received :closed
    refute_received {:publish, _}
    refute_received {:assignee, _}

    # #5.2 — abandon NOTIFIE l'arch (sas user) : kick + commentaire adressé-arch (pas d'enterrement muet).
    assert_received {:wake, "permanent-architect"}
    assert_received {:comment, abody}
    assert abody =~ "Architecte"
  end

  test "verdict escalate_user -> await_arch (lcars-awaits-arch + unlock, pas close/reassign) + KICK arch" do
    assert {:ok, :awaiting_arch} =
             HopConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "escalate_user"}},
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
    assert_received :unlocked
    refute_received {:assignee, _}
    refute_received :closed
    assert_received {:comment, body}
    assert body =~ "gatekeeper"
    assert body =~ "escalate_user"

    # #5.2 — commentaire ADRESSÉ à l'arch (sas unique) + KICK actif (l'arch arme son monitor au spawn).
    assert body =~ "Architecte"
    assert_received {:wake, "permanent-architect"}
  end

  test "verdict halt_wait_input -> await_arch" do
    assert {:ok, :awaiting_arch} =
             HopConsumer.resume_gate(
               soft_ctx(),
               %{"result" => %{"decision" => "halt_wait_input"}},
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
  end

  test "verdict redirect -> await_arch (differe A2.x, pas de routage hors-DAG)" do
    assert {:ok, :awaiting_arch} =
             HopConsumer.resume_gate(soft_ctx(), %{"result" => %{"decision" => "redirect"}}, hc())

    assert_received {:label, "lcars-awaits-arch"}
    refute_received {:assignee, _}
  end

  test "verdict absent/invalide -> await_arch (fail-closed, jamais continue silencieux)" do
    assert {:ok, :awaiting_arch} =
             HopConsumer.resume_gate(soft_ctx(), %{"result" => %{}}, hc())

    assert_received {:label, "lcars-awaits-arch"}
    refute_received {:assignee, _}
    refute_received :closed
    assert_received {:comment, body}
    assert body =~ "illisible ou absent"
  end

  # ── #8.E : verdict d'un juge de MANDAT (mandate-review/consultant) via pod.completed ──────────
  # MÊME apply_verdict que le gatekeeper (factorisé) ; le consultant est PRÉ-PR → avance ISSUE-LEVEL
  # (grave route, pas de PR) et trace attribuée au CONSULTANT (pas "gatekeeper").

  # pod.completed du stage mandate-review (consultant) qui vient de rendre son verdict.
  defp mandate_done(result),
    do: %{
      "ticket_id" => "issue-1",
      "workspace" => "/ws",
      "base_sha" => "cafe",
      "role" => "consultant",
      "pipeline" => "mandgate",
      "stage" => "mandate-review",
      "result" => result
    }

  test "#8.E mandate-review continue -> AVANCE issue-level vers build (route+commentaire, PAS de PR, assignee intact)" do
    assert {:ok, :reassigned} =
             HopConsumer.maybe_complete(
               mandate_done(%{"decision" => "continue", "reason" => "mandat clair"}),
               hc()
             )

    # avance ISSUE-LEVEL : grave la route vers build ; AUCUNE PR ouverte (le consultant juge pré-PR).
    assert_received {:route, "mandgate", "build"}
    refute_received {:open_pr, _, _, _}
    refute_received {:assignee, _}
    assert_received :unlocked
    # trace attribuée au CONSULTANT (honnête), pas au gatekeeper.
    assert_received {:comment, body}
    assert body =~ "consultant"
    assert body =~ "continue"
  end

  test "#8.E mandate-review escalate_user -> await_arch (arch) ; trace CONSULTANT, pas gatekeeper" do
    assert {:ok, :awaiting_arch} =
             HopConsumer.maybe_complete(
               mandate_done(%{"decision" => "escalate_user", "reason" => "mandat ambigu"}),
               hc()
             )

    assert_received {:label, "lcars-awaits-arch"}
    assert_received :unlocked
    refute_received {:assignee, _}
    refute_received :closed
    assert_received {:comment, body}
    assert body =~ "consultant"
    refute body =~ "gatekeeper"
  end

  test "#8.E mandate-review abandon -> close (mandat jeté), PAS de PR ni de push" do
    assert {:ok, :completed} =
             HopConsumer.maybe_complete(mandate_done(%{"decision" => "abandon"}), hc())

    assert_received :closed
    refute_received {:open_pr, _, _, _}
    refute_received {:publish, _}
  end

  # ── #8-fix « un producteur ne merge JAMAIS seul » ───────────────────────────────────────
  test "producteur terminal (build, dernier stage de la carte) -> :review (PR + juges), JAMAIS :promote/merge" do
    # mandgate = mandate-review -> build ; build (engineer, producteur) est TERMINAL. Avant le fix il
    # faisait :promote (merge sans juges = régression #8.F). Avec : :review -> ouvre la PR + demande
    # [qualifier, reviewer] ; le chemin PR-driven prouvé (dispatch_by_verdicts) scelle ensuite au gatekeeper.
    assert {:ok, :review_requested} =
             HopConsumer.maybe_complete(build_done("mandgate", %{}), hc())

    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["qualifier", "reviewer"]}
    refute_received {:merge, _}
  end

  # ── B : cablage async (GenServer) — store gate_evals a l'escalade, pop a la reprise ──

  test "GenServer : pod.completed soft -> gate_evals stocke ; task_completed correle -> pop" do
    {:ok, pid} =
      HopConsumer.start_link(
        repo: "o/r",
        remote: "origin",
        subscribe: false,
        forge_client: StubForge,
        loader: Carte,
        deliverable: DelivStub,
        deliverable_mode_fun: dmode(),
        task_queue: StubQueue,
        spawner: StubSpawner,
        gatekeeper_pod_id_fun: fn -> "gk-perm" end,
        role_emails: fn r -> ["#{r}@lcars.local"] end
      )

    send(pid, %Fleet.Event{
      source: :spawner,
      type: :"pod.completed",
      timestamp: DateTime.utc_now(),
      payload: build_done("soft", %{})
    })

    state = :sys.get_state(pid)
    assert Map.has_key?(state.gate_evals, "corr-1")
    assert %{stage: "build"} = state.gate_evals["corr-1"]

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

  test "GenServer : task_completed d'un corr inconnu -> ignore (pas de crash)" do
    {:ok, pid} =
      HopConsumer.start_link(repo: "o/r", remote: "origin", subscribe: false, loader: Carte)

    send(pid, %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      correlation_id: "inconnu",
      timestamp: DateTime.utc_now(),
      # MA-03 : payload SANS metadata gate_eval (cas NORMAL — un pod stage-dispatch ordinaire) → ignoré.
      payload: %{result: %{"decision" => "continue"}}
    })

    assert %{gate_evals: evals} = :sys.get_state(pid)
    assert evals == %{}
  end

  # ── MA-03 : le verdict gatekeeper SURVIT au restart du HopConsumer (verdict auto-descriptif) ──
  # Le wedge fermé : crash du HopConsumer SEUL (broker vivant). Le contexte de reprise n'est plus en RAM
  # (`gate_evals` vide au restart) ; il VOYAGE dans le metadata de la TÂCHE d'éval (qui survit dans le broker)
  # → ramené par `task_completed` → reconstruction → resume. Avant MA-03 : `{nil,_} -> {:noreply}` silencieux
  # (verdict jeté, issue verrouillée à vie).

  # Le metadata de la tâche d'éval, tel que `dispatch_gatekeeper` l'embarque + tel que `task_queue/server.ex`
  # le pose dans le payload de `task_completed`. Porte le contexte de reprise (resume_payload/n/role).
  defp gate_eval_meta do
    %{
      "gate_eval" => true,
      "stage" => "build",
      "pipeline" => "soft",
      "gate" => %{"type" => "soft"},
      "outputs" => %{"sev" => "high"},
      "resume_payload" => build_done("soft", %{"sev" => "high"}),
      "resume_n" => 1,
      "resume_role" => "engineer"
    }
  end

  # Stubs forge/deliverable qui RELAIENT vers le pid de test porté dans `forge_opts[:test_pid]`. Nécessaire
  # pour les tests GenServer : les effets forge tournent DANS le process du HopConsumer (`self()` ≠ test) →
  # un `send(self(), …)` n'atteindrait pas le test. Le pid est threadé via `forge_opts` (déjà passé au
  # forge_client par `HopCompleter`). DelivStub n'a pas d'opts → on relaie via le pid stocké à l'init du test.
  defmodule RelayForge do
    defp relay(opts, msg), do: send(Keyword.fetch!(opts, :test_pid), msg)
    def post_comment(_r, _n, body, o), do: relay(o, {:comment, body}) && {:ok, :posted}
    def set_state_label(_r, _n, _s, _o), do: {:ok, :set}
    def set_assignee(_r, _n, l, o), do: relay(o, {:assignee, l}) && {:ok, :set}
    def remove_label(_r, _n, _l, o), do: relay(o, :unlocked) && {:ok, :removed}
    def add_label(_r, _n, label, o), do: relay(o, {:label, label}) && {:ok, :added}
    def close_issue(_r, _n, o), do: relay(o, :closed) && {:ok, :closed}
    def count_signed_hops(_r, _n, _o), do: {:ok, 0}
    def post_route(_r, _n, p, s, o), do: relay(o, {:route, p, s}) && {:ok, :posted}
    def open_pr(_r, head, base, _t, o), do: relay(o, {:open_pr, head, base, o[:body]}) && {:ok, 7}
    def get_pr_for_branch(_r, _head, _base, _o), do: {:ok, 7}
    def list_open_pulls(_r, _o), do: {:ok, []}
    def request_review(_r, pr, revs, o), do: relay(o, {:request_review, pr, revs}) && :ok
    def post_review(_r, pr, ev, body, o), do: relay(o, {:review, pr, ev, body}) && :ok
    def merge_pr(_r, pr, o), do: relay(o, {:merge, pr}) && :ok
  end

  defp fresh_hop_consumer do
    # `deliverable: DelivStub` → son `{:publish, _}` part vers le GenServer (`self()` côté pod) ; on n'assert
    # PAS dessus (les effets observables passent par RelayForge/forge_opts). Le push réussit (mode git_native).
    {:ok, pid} =
      HopConsumer.start_link(
        repo: "o/r",
        remote: "origin",
        subscribe: false,
        forge_opts: [test_pid: self()],
        forge_client: RelayForge,
        loader: Carte,
        deliverable: DelivStub,
        deliverable_mode_fun: dmode(),
        task_queue: StubQueue,
        spawner: StubSpawner,
        gatekeeper_pod_id_fun: fn -> "gk-perm" end,
        role_emails: fn r -> ["#{r}@lcars.local"] end
      )

    pid
  end

  test "MA-03 : verdict gatekeeper RECONSTRUIT après restart (gate_evals VIDE) -> complétion, PAS de drop silencieux" do
    # 1. escalade sur un 1er HopConsumer → gate_evals peuplé.
    pid1 = fresh_hop_consumer()

    send(pid1, %Fleet.Event{
      source: :spawner,
      type: :"pod.completed",
      timestamp: DateTime.utc_now(),
      payload: build_done("soft", %{"sev" => "high"})
    })

    assert Map.has_key?(:sys.get_state(pid1).gate_evals, "corr-1")

    # 2. CRASH du HopConsumer SEUL (broker resterait vivant en prod) → on le stoppe + on en démarre un NEUF.
    #    Le neuf a gate_evals VIDE — exactement l'état post-crash où l'ancien code jetait le verdict.
    :ok = GenServer.stop(pid1)
    pid2 = fresh_hop_consumer()
    assert :sys.get_state(pid2).gate_evals == %{}

    # 3. Le verdict revient (le metadata de la tâche a survécu dans le broker → posé dans task_completed).
    send(pid2, %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      correlation_id: "corr-1",
      timestamp: DateTime.utc_now(),
      payload: %{
        result: %{"decision" => "continue", "reason" => "RAS"},
        metadata: gate_eval_meta()
      }
    })

    # 4. RECONSTRUCTION + COMPLÉTION : le verdict `continue` ouvre la PR + request_review + route — PAS un
    #    {:noreply} silencieux. (`:sys.get_state` après le send sérialise le handle_info → l'effet a eu lieu.)
    _ = :sys.get_state(pid2)
    assert_received {:open_pr, "lcars/issue-1-engineer", "main", _}
    assert_received {:request_review, 7, ["reviewer"]}
    assert_received {:route, "soft", "review"}
    assert_received :unlocked
  end

  test "MA-03 : restart + verdict abandon RECONSTRUIT -> close (terminal), pas de drop" do
    :ok = GenServer.stop(fresh_hop_consumer())
    pid = fresh_hop_consumer()
    assert :sys.get_state(pid).gate_evals == %{}

    send(pid, %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      correlation_id: "corr-1",
      timestamp: DateTime.utc_now(),
      payload: %{result: %{"decision" => "abandon"}, metadata: gate_eval_meta()}
    })

    _ = :sys.get_state(pid)
    assert_received :closed
    refute_received {:publish, _}
  end

  test "MA-03 : task_completed gate_eval mais metadata TRONQUÉ (resume_payload absent) -> pas de resume (fail-loud), pas de crash" do
    pid = fresh_hop_consumer()

    bad_meta = gate_eval_meta() |> Map.delete("resume_payload")

    send(pid, %Fleet.Event{
      source: :task_queue,
      type: :task_completed,
      correlation_id: "corr-1",
      timestamp: DateTime.utc_now(),
      payload: %{result: %{"decision" => "continue"}, metadata: bad_meta}
    })

    # Le singleton ne crashe pas, et n'agit PAS sur un contexte tronqué (pas de PR ouverte à l'aveugle).
    assert Process.alive?(pid)
    assert :sys.get_state(pid).gate_evals == %{}
    refute_received {:open_pr, _, _, _}
  end
end
