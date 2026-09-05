defmodule Fleet.Pilot.PollerBench do
  @moduledoc """
  The bench of the step-rail `Poller`'s witnesses: the forge, loader, spawner and task-queue stubs
  of the step mode, and `start_step_poller/3` that wires them. Shared by `PollerTest` and the
  reconciliation facts (`Poller.ReconciliationFactsTest`). Every stub spies with `send/2` on the
  `_test_pid` it is handed (the stubs run INSIDE the poller process).

  `import Fleet.Pilot.PollerBench` for the starters, `alias Fleet.Pilot.PollerBench.{…}` for the stubs.
  """

  alias Fleet.Pilot.Poller

  defmodule StepStubForge do
    # L'admission lit les preconditions avant de DEMARRER un ticket : un stub sans cette lecture
    # ne peut pas voir la porte, et la laisserait disparaitre sans qu'un test rougisse.
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}

    # LE RAIL CI, PREMISSE ET PAS SUJET. Les PR de ce module portent des labels vides : leur issue
    # n'a pas de carte gravee, donc la politique CI vient de la carte du PROJET — qui l'exige. Ces
    # tests mesurent la COMPTABILITE du poller (dispatched/skipped/errors) ; ils declarent donc un
    # rail vert et rien de plus. Le comportement de la porte elle-meme se mesure dans `CiGateTest`,
    # pas ici. Sans ces deux fonctions le stub ne decrit pas une forge : il plante.
    def get_pull(_repo, n, _opts) do
      {:ok,
       %{
         "number" => n,
         "state" => "open",
         "head" => %{"sha" => "p011e4c0ffee00000000"},
         "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end

    def commit_ci_state(_repo, _sha, _opts), do: {:ok, :success}

    # WS3 — the poller DISCOVERS its repos by org-membership (`list_org_repos`) BEFORE scanning.
    # Default = THE test repo (single-repo: 1 repo discovered → 1 `step_do_poll`). `_test_repos`
    # for multi-repo, `_test_discover` to simulate a failing discovery (forge down → backoff). No
    # more seal/admission: org-membership IS the admission (any repo returned here is scanned).
    def list_org_repos(_org, opts) do
      Keyword.get(
        opts,
        :_test_discover,
        {:ok, Keyword.get(opts, :_test_repos, ["lordzurp/lcars-test"])}
      )
    end

    # #5.2 D1 — the multi-user scoping is FORGE-SIDE: the poller passes `assigned_by=<my_human>`.
    # The stub CAPTURES this scoping (→ `:_test_pid`) to verify it, then returns `:_test_issues`
    # as-is.
    def list_open_issues(_repo, opts) do
      send(
        Keyword.get(opts, :_test_pid, self()),
        {:scoped, :issues, Keyword.get(opts, :assigned_by)}
      )

      Keyword.fetch!(opts, :_test_issues)
    end

    # Step mode ALSO lists PRs (judge path), scoped the same (assigned_by). Default {:ok, []}.
    def list_open_pulls(_repo, opts) do
      send(
        Keyword.get(opts, :_test_pid, self()),
        {:scoped, :pulls, Keyword.get(opts, :assigned_by)}
      )

      Keyword.get(opts, :_test_pulls, {:ok, []})
    end

    # Observable comme `remove_label` : la convergence du `wait/*` (BL-6-48) ecrit depuis le
    # Poller, donc le signal part vers le pid du TEST, pas vers la mailbox du GenServer.
    def add_label(_repo, n, label, opts) do
      send(Keyword.get(opts, :_test_pid, self()), {:add_label, n, label})
      {:ok, :added}
    end

    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def start_stopwatch(_repo, _n, _opts), do: :ok
    def stop_stopwatch(_repo, _n, _opts), do: :ok

    # DELEGATION a la vraie fonction, et c'est deliberé : `route_from_labels/1` est PURE (zero I/O)
    # — la stubber reviendrait a re-implementer la regle de derivation dans le harnais, donc a
    # tester une copie au lieu du contrat. Les stubs existent pour couper les I/O, pas les regles.
    def route_from_labels(labels), do: Fleet.Forge.Client.route_from_labels(labels)

    # #8: the route lives in the route-comment (state-machine). Stub configurable via
    # `_test_routes` (map n → {workflow_map, step}). Default :none (unrouted issue → A1 producer).
    def get_route(_repo, n, opts) do
      case Map.get(Keyword.get(opts, :_test_routes, %{}), n) do
        {workflow_map, step} -> {:ok, {workflow_map, step}}
        # `:error` sentinel → transient forge failure (fail-closed lease test).
        :error -> {:error, :timeout}
        _ -> :none
      end
    end

    def get_predecessor_result(_repo, _n, _opts), do: :none
    # Info-starvation fix: build_judge_brief reads the criterion (issue body) via get_issue.
    def get_issue(_repo, n, _opts), do: {:ok, %{"number" => n, "body" => "criterion stub ##{n}"}}

    # ②.1d: by default no judge verdict (the poller tests do not cover merge/rework) → every
    # requested judge is "pending" → dispatched.
    def pr_review_verdicts(_repo, _index, _opts), do: {:ok, %{}}

    # F-E8: combined jury state — no verdict + empty jury (the poller tests do not cover merge) →
    # `requested` = the PR's `requested_reviewers` → every requested judge stays pending →
    # dispatched.
    def pr_review_state(_repo, _index, _opts), do: {:ok, %{verdicts: %{}, reviewers: []}}

    # Adoption: sets judges on an orphan PR (human/fork, or an agent that lost its reviewers).
    def request_review(_repo, index, reviewers, _opts),
      do: send(self(), {:requested_review, index, reviewers}) && :ok

    # MA-06: forge-native counter of rework rounds (the poller tests do not cover bounded rework).
    def count_change_request_rounds(_repo, _index, _opts), do: {:ok, 0}
    def post_route(_repo, _n, p, s, _opts), do: send(self(), {:route, p, s}) && {:ok, :posted}
    def set_assignee(_repo, _n, login, _opts), do: send(self(), {:assignee, login}) && {:ok, :set}

    # Reconciliation (B): the reclaim runs INSIDE the Poller GenServer → we route the signal to
    # the test pid (`:_test_pid` of the forge_opts), not `self()` (the Poller's mailbox).
    def remove_label(_repo, n, label, opts) do
      send(Keyword.get(opts, :_test_pid, self()), {:remove_label, n, label})

      # `_test_fail_remove_label` — the forge refuses the removal (outage): the reconciliation must
      # KEEP the ref suspect and retry NEXT tick (not restart the 2-tick grace from scratch).
      if Keyword.get(opts, :_test_fail_remove_label, false),
        do: {:error, :forge_down},
        else: {:ok, :removed}
    end
  end

  defmodule StepStubLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{},
           spec: %{"brief_kind" => "worker", "invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    # PR judge (qualifier/reviewer) -> brief_kind: judge (defused GateBrief brief).
    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"brief_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  # WORKFLOW_MAP loader (load!/1) — distinct from the CapProfile loader above (load/1).
  defmodule StepStubWorkflowMapLoader do
    # 1-step (engineer producer): an issue routed here (step=build=1st) is QUEUED (not started).
    def load!("qa-build") do
      %{
        "name" => "qa-build",
        "ci" => "ignore",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
    end

    # 2-step: routed at the 2nd step (deploy ≠ 1st) = ADVANCED pipeline (between two step_runs) = ENGAGED.
    def load!("qa-2") do
      %{
        "name" => "qa-2",
        "ci" => "ignore",
        "steps" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "deploy" => %{"role" => "engineer", "needs" => ["build"]}
        }
      }
    end
  end

  defmodule StepStubSpawner do
    # PASSE-9 — real `Spawner.spawn_pod/3` shape = {:ok, pid()}, NEVER a string: a consumer
    # re-interpolating the pid would break in prod.
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    # Reconciliation (B): no live pod by default → every `lcars-in-flight` lock is an orphan
    # candidate (reclaimed after the 2-tick grace). A stub with list_pods absent would fail-safe
    # (skip).
    def list_pods, do: []

    # G4: the awaits-arch re-kick calls wake_pod — no-op stub (the tick must not crash when an
    # awaits-arch issue is present). A lost wake costs latency, never the backlog: the truth = the
    # `lcars-awaits-arch` label on the forge, re-read every tick, and this periodic re-kick
    # (@awaits_rekick_every throttle) IS the rail that re-derives the wake. The DECISION to
    # re-kick is tested via awaits_rekick?/2.
    def wake_pod(_pod_id), do: :ok
  end

  # F-037 / #25: a LIVE pod with a REPO-SCOPED pod_id (`<repo-slug>-issue-<n>-<role>`, real PodId format).
  defmodule LivePodSpawner do
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-issue-8-engineer"}]
  end

  # TaskQueue stub: the pod has an ACTIVE task → it legitimately OWNS its lock.
  defmodule ActiveTaskQueue do
    def pod_status(_pod_id), do: {:ok, :assigned}
  end

  # SLOT-FREEZE: a project-scoped PIPE eng (pod_id `<repo>-engineer`, WITHOUT `-issue-N-` — the
  # resident eng that handles N issues sequentially, 1 process = 1 Desktop slot).
  defmodule ProjectPipeSpawner do
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-engineer"}]
  end

  # TaskQueue stub: the project eng is working BRICK 8 (issue_id "issue-8") -> it owns #8.
  defmodule ProjectTaskQueueIssue8 do
    def pod_status(_pod_id), do: {:ok, :assigned}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # TaskQueue stub: the project eng is working ANOTHER brick (9) -> it does NOT own #8.
  defmodule ProjectTaskQueueIssue9 do
    def pod_status(_pod_id), do: {:ok, :assigned}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-9"}
  end

  # The listener name is GLOBAL and this file is async: the name frees on the PREVIOUS test
  # process's DEATH, which is asynchronous — a register at the next test's first line can race
  # it (seed-dependent flake, measured in the gate). Bounded wait: the only possible owner is
  # the dying predecessor of THIS serial module, never a live peer.
  def register_reap_listener!(tries \\ 50)

  # L'abandon est une CLAUSE, pas un `raise` dans le `rescue` — credo le demande
  # (`Warning.RaiseInsideRescue`) et la mesure dit que la trace ne changeait pas : un `raise` dans un
  # `rescue` porte deja sa propre pile, la bonne ligne dans la bonne fonction. Ce qui est perdu, c'est
  # la trace de l'`ArgumentError`, qui pointe sur `Process.register/2` — donc ce que le message dit
  # deja. `reraise` remplacerait ici un message utile par un message inutile ; sortir le `raise` du
  # bloc satisfait la regle sans rien echanger.
  def register_reap_listener!(0), do: raise("reap_test_listener never freed")

  def register_reap_listener!(tries) do
    Process.register(self(), :reap_test_listener)
  rescue
    ArgumentError ->
      Process.sleep(10)
      register_reap_listener!(tries - 1)
  end

  # Reap (B'): a live per-brick JUDGE pod + kill capture. `kill_pod` runs in the POLLER process →
  # the capture goes through the registered test listener (`:reap_test_listener`), same reason the
  # forge stub threads `_test_pid`.
  defmodule QuiescedJudgeSpawner do
    def spawn_pod(_profile, _issue_id, _opts), do: {:ok, self()}
    def list_pods, do: [%{pod_id: "lordzurp-lcars-test-issue-8-consultant"}]
    def wake_pod(_pod_id), do: :ok

    def kill_pod(pod_id) do
      if pid = Process.whereis(:reap_test_listener), do: send(pid, {:killed, pod_id})
      :ok
    end
  end

  # TaskQueue stub: the judge DELIVERED its verdict (terminal task) → no active task, owns nothing.
  # `enqueue`/`list_active`: the awaits-arch fixture also walks the arch-offer path on the tick.
  defmodule QuiescedTaskQueue do
    def pod_status(_pod_id), do: {:ok, :completed}
    def enqueue(_pod_id, _attrs), do: {:ok, %{id: "wi-arch"}}
    def list_active, do: []
  end

  # TaskQueue stub: the project eng DELIVERED #8 (task `:completed`) — martine + F-C050 configs.
  # `:completed` is TERMINAL (`WorkItem.active?/1` → false): a delivered eng NO LONGER owns its
  # lock. Two tests: martine (PR#6 open → issue excluded via pr_issue_ids, a dead judge's PR lock
  # is reclaimed) and F-C050 (NO PR → the ISSUE orphan, once masked by `:completed`, is finally
  # reclaimed). `pod_active_issue_id` returns "issue-8" but is no longer reached: the
  # `pod_has_active_task?` filter short-circuits before (a `:completed` is no longer active).
  defmodule ProjectTaskQueueCompletedIssue8 do
    def pod_status(_pod_id), do: {:ok, :completed}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # Parked-admission TaskQueue stub: the pod was ADMITTED (task enqueued on issue-8) but its wake
  # never LANDED (`wake_unreached`) — the task is still `:pending`, never pulled. `:pending` is
  # "active" but NOT pulled: a PARKED admission owns no lock. Twin of ProjectTaskQueueCompletedIssue8,
  # `:pending` instead of `:completed`.
  defmodule ParkedPendingTaskQueue do
    def pod_status(_pod_id), do: {:ok, :pending}
    def pod_active_issue_id(_pod_id), do: {:ok, "issue-8"}
  end

  # G1 — TaskQueue stub: a PULLED GATEKEEPER EVAL (state :assigned — the gatekeeper pulled it)
  # carries brick #8 of THIS repo (self-describing MA-03 metadata: gate_eval + resume_n +
  # resume_payload.repository). No live pod otherwise (the producer is done): exactly the eval window.
  defmodule GateEvalTaskQueue do
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          state: :assigned,
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/lcars-test"}}
          }
        }
      ]
    end
  end

  # A gate-eval ADMITTED but never activated: enqueued (state :pending), the gatekeeper never pulled
  # it (wake lost, kick net exhausted). An eval without an executor owns nothing — twin of
  # GateEvalTaskQueue with :pending instead of :assigned (enqueued, never pulled).
  defmodule GateEvalPendingTaskQueue do
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          state: :pending,
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/lcars-test"}}
          }
        }
      ]
    end
  end

  # G1 — TaskQueue stub: a pulled eval exists but for ANOTHER repo → it does NOT own the #8 ref
  # of lordzurp/lcars-test (multi-project: the ref's repo comes from the resume_payload).
  defmodule GateEvalOtherRepoTaskQueue do
    def pod_status(_pod_id), do: {:ok, nil}

    def list_active do
      [
        %{
          state: :assigned,
          metadata: %{
            "gate_eval" => true,
            "resume_n" => 8,
            "resume_payload" => %{"repository" => %{"full_name" => "lordzurp/autre-projet"}}
          }
        }
      ]
    end
  end

  # Wake recovery that FAILS (unreachable pod, unrepaired re-roll) → `StepDispatcher.dispatch_issue`
  # surfaces `{:error, {:wake_unreached, …}}`: the pipeline IS started (lock + pod + brief set
  # upstream, canonical order), only the tmux wake failed. Used to prove the contract "failed wake
  # ⇒ lease TAKEN".
  defmodule FailingWakeRecovery do
    def wake(_pod_id, _respawn_fun, _opts), do: {:error, {:escalated, :not_found}}
  end

  # WORKFLOW_MAP loader that TRANSIENTLY FAILS on `qa-2` (workflow_map → nil) but loads `qa-build`
  # normally. Simulates a network/forge workflow_map load failure on a routed-advanced pipeline:
  # the lease must NOT be released because of it (fail-closed). `load!/1` RAISES for `qa-2` → the
  # poller (load_workflow_map_or_nil) AND the StepDispatcher (load_workflow_map) rescue it into
  # nil/`{:error}`.
  defmodule NilWorkflowMapForQa2Loader do
    def load!("qa-2"), do: raise("workflow_map qa-2 unavailable (simulated transient failure)")

    def load!("qa-build"),
      do: %{
        "name" => "qa-build",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }
  end

  def start_step_poller(issues_response, pulls_response \\ {:ok, []}, extra \\ []) do
    name = :"P_step_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Poller.start_link(
        [
          name: name,
          repo: "lordzurp/lcars-test",
          human: "lordzurp",
          start_tick?: false,
          protection_reconciler: fn _repo, _opts -> :ok end,
          step_dispatch?: true,
          forge_client: StepStubForge,
          forge_opts: [
            _test_issues: issues_response,
            _test_pulls: pulls_response,
            _test_pid: self()
          ],
          loader: StepStubLoader,
          spawner: StepStubSpawner
        ] ++ extra
      )

    {name, pid}
  end

  # ── the entry poller: routes projected onto the issues' labels ──
  # La route d'une issue est PORTEE PAR SES LABELS, pas servie par un stub (BL-6-40 Phase 2).
  # `list_open_issues` les rend avec l'issue ; `get_route` refaisait un GET par issue et par tick
  # pour une donnee deja en RAM.
  #
  # La migration tient ICI et les 15 sites d'appel ne bougent pas : ils continuent d'exprimer
  # leur intention en `%{numero => {carte, step}}`, forme lisible, et le harnais la PROJETTE en
  # labels `wfmap/*` + `stage/*` sur les issues correspondantes. Garder la forme d'appel etait la
  # bonne decision : elle dit ce que le test veut, pas comment la forge l'encode.
  #
  # ⚠ `_test_routes` est RETIRE en meme temps, et c'est ce qui donne le ROUGE (`[RR2]` du plan) :
  # laisse en place, le stub `get_route` continuerait a servir la route et les tests resteraient
  # verts VIA LE STUB — des labels mal formes ne se verraient qu'au branchement, loin de leur
  # cause.
  def project_routes_onto_issues({:ok, issues}, routes) when map_size(routes) > 0 do
    {:ok,
     Enum.map(issues, fn issue ->
       case Map.get(routes, issue["number"]) do
         {map, step} ->
           existing = issue["labels"] || []

           Map.put(
             issue,
             "labels",
             existing ++
               [
                 %{"name" => Fleet.Labels.wfmap_prefix() <> map},
                 %{"name" => Fleet.Labels.stage_prefix() <> step}
               ]
           )

         # Une route non projetable (le sentinel `:error` de l'ancien stub) ne devient PAS un
         # label : l'issue reste routeless, ce qui est le seul etat que des labels peuvent dire.
         _ ->
           issue
       end
     end)}
  end

  def project_routes_onto_issues(issues_response, _routes), do: issues_response

  def start_entry_poller(issues_response, routes, extra_opts \\ []) do
    name = :"P_lease_#{System.unique_integer([:positive])}"

    base = [
      name: name,
      repo: "lordzurp/lcars-test",
      human: "lordzurp",
      start_tick?: false,
      protection_reconciler: fn _repo, _opts -> :ok end,
      step_dispatch?: true,
      forge_client: StepStubForge,
      forge_opts: [_test_issues: project_routes_onto_issues(issues_response, routes)],
      loader: StepStubLoader,
      workflow_map_loader: StepStubWorkflowMapLoader,
      spawner: StepStubSpawner
    ]

    {:ok, pid} = Poller.start_link(Keyword.merge(base, extra_opts))

    {name, pid}
  end
end
