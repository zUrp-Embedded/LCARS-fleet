defmodule Fleet.Pilot.StepDispatcherTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StepDispatcher
  alias Fleet.Pilot.StubTaskQueue

  defp issue(fields) do
    %{
      "issue" =>
        Map.merge(
          %{"number" => 42, "body" => "fais le hello", "labels" => [], "assignees" => []},
          fields
        )
    }
  end

  # Issue-producteur du modèle forge-state-machine (DN §1) : assignee = l'HUMAIN owner. Le rôle
  # producteur est un INVARIANT côté poller (`:producer_role`, défaut engineer), pas un marqueur
  # par-issue. `fields` override (labels, body…).
  defp eng_issue(fields \\ %{}) do
    issue(Map.merge(%{"assignees" => [%{"login" => "lordzurp"}]}, fields))
  end

  # #5.2 D2 — decide = PORTE pure : verrou → skip, sinon :engage. Pas d'ownership (scoping forge-side amont),
  # pas de rôle (vient de la route via workflow_map_role), pas de load (workflow_map_role charge).
  describe "decide/1 (porte pure)" do
    test "issue non verrouillée → :engage (rôle ET action spawn/onboard décidés en aval)" do
      assert :engage = StepDispatcher.decide(eng_issue())
    end

    test "verrou lcars-in-flight présent → {:skip, :in_flight}" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}]})
      assert {:skip, :in_flight} = StepDispatcher.decide(payload)
    end

    test "verrou HUMAIN lcars-awaits-arch → {:skip, :awaits_arch} (A2.3b, pas de re-dispatch)" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-awaits-arch"}]})
      assert {:skip, :awaits_arch} = StepDispatcher.decide(payload)
    end
  end

  # Seams stubs pour dispatch_issue/2
  defmodule StubForge do
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    def start_stopwatch(_repo, _n, _opts), do: :ok

    # QoL 2026-07-07 (régression) : signale `n` — prouve que `promote_pr` (merge poller-driven,
    # no-workflow_map) lève DÉSORMAIS le verrou ISSUE en plus du verrou PR (jamais fait avant ce fix).
    def stop_stopwatch(_repo, n, _opts) do
      send(self(), {:stopped_watch, n})
      :ok
    end

    # Adoption : pose des juges sur une PR orpheline (humaine/fork). Capture pour assertion.
    def request_review(_repo, index, reviewers, _opts) do
      send(self(), {:requested_review, index, reviewers})
      :ok
    end

    # A2.1 : route lue depuis forge_opts[:_test_route] (défaut :none = hors-workflow_map / 1-step).
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)

    # #5.2 D2 — onboarding : grave la route initiale de la workflow_map par défaut. Capture pour assertion.
    def post_route(_repo, n, workflow_map, step, _opts) do
      send(self(), {:routed, n, workflow_map, step})
      {:ok, :posted}
    end

    # F077 : le brief juge lit le result du prédécesseur (option B). Stub : forge_opts[:_test_pred].
    def get_predecessor_result(_repo, _n, opts), do: Keyword.get(opts, :_test_pred, :none)

    # Fix famine-d'info : build_judge_brief lit le critère (body de l'issue) via get_issue.
    # Stub : forge_opts[:_test_issue_body] (défaut un body non-vide).
    def get_issue(_repo, n, opts),
      do: {:ok, %{"number" => n, "body" => Keyword.get(opts, :_test_issue_body, "critère stub")}}

    # ②.1d : verdicts par juge (reviews-driven). Stub : forge_opts[:_test_verdicts] (map login↓→verdict,
    # defaut %{} = aucun juge n'a encore de verdict décisif).
    def pr_review_verdicts(_repo, _index, opts),
      do: {:ok, Keyword.get(opts, :_test_verdicts, %{})}

    # F-E8 : état de jury combiné (verdicts + SET du jury depuis les review-records). `:_test_reviewers`
    # (défaut [] → `requested` = le seul `requested_reviewers` du PR, comportement legacy des tests).
    def pr_review_state(_repo, _index, opts),
      do:
        {:ok,
         %{
           verdicts: Keyword.get(opts, :_test_verdicts, %{}),
           reviewers: Keyword.get(opts, :_test_reviewers, [])
         }}

    # Fix famine-d'info (rework) : feedback REQUEST_CHANGES injecté au brief de rework. Stub :
    # forge_opts[:_test_feedback] (liste %{"login","body"}, défaut un body non-vide).
    def change_request_feedback(_repo, _index, opts),
      do:
        {:ok,
         Keyword.get(opts, :_test_feedback, [%{"login" => "reviewer", "body" => "feedback stub"}])}

    # MA-06 : compteur forge-natif des rounds de rework (nb REQUEST_CHANGES). Stub :
    # forge_opts[:_test_rework_rounds] (défaut 0 = pas de round → re-spawn normal, tests legacy inchangés).
    def count_change_request_rounds(_repo, _index, opts),
      do: Keyword.get(opts, :_test_rework_rounds, {:ok, 0})

    # F181 : compensation — retrait du verrou sur échec post-verrou.
    def remove_label(_repo, _n, label, _opts) do
      send(self(), {:removed_label, label})
      {:ok, :removed}
    end

    # ②.1d : merge FF (promote PR-state-driven, tous les juges OK). Signale pour assertion.
    # `_test_merge_result` (seam) force un échec (ex. conflit `{:error, {:http, 409, _}}`) → teste la
    # résolution F-PARALLEL-PR-CONFLICT ; absent → succès `:ok`.
    def merge_pr(_repo, index, opts) do
      case Keyword.get(opts, :_test_merge_result) do
        nil ->
          send(self(), {:merged, index})
          :ok

        result ->
          result
      end
    end

    def set_stage(_repo, _n, _stage, _opts), do: {:ok, :posted}
    def close_issue(_repo, _n, _opts), do: {:ok, :closed}

    # Objet PR relu par `route_merge_failure` pour CLASSIFIER un échec de merge (MergeOutcome). Seam
    # `_test_pull` (map de champs mergeable/draft/state) ; défaut = vrai conflit git (mergeable:false).
    def get_pull(_repo, n, opts) do
      {:ok,
       Keyword.get(opts, :_test_pull, %{
         "number" => n,
         "state" => "open",
         "draft" => false,
         "mergeable" => false
       })}
    end

    # Juges re-demandés (timeline) — seam `_test_rerequested` (défaut aucun).
    def pr_rerequested_reviewers(_repo, _n, opts),
      do: {:ok, Keyword.get(opts, :_test_rerequested, [])}
  end

  defmodule StubLoader do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"slot_scope" => "project"},
           spec: %{}
         }}

    # F077 : un rôle juge déclare `brief_kind: judge` dans son cap-profile (pas un nom magique).
    def load("gatekeeper"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "gatekeeper", "slot_scope" => "project"},
           spec: %{"brief_kind" => "judge"}
         }}

    # Corr.3 : un juge de PR (qualifier/reviewer) declare aussi brief_kind: judge.
    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role, "slot_scope" => "instance"},
           spec: %{"brief_kind" => "judge"}
         }}

    # #8 : le consultant relit le BRIEF (juge) → brief_kind: judge.
    def load("consultant"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "consultant", "slot_scope" => "instance"},
           spec: %{"brief_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  defmodule StubSpawner do
    # Fidèle au contrat réel `Spawner.spawn_pod/3` : retourne `{:ok, pid()}`, PAS une string
    # (un retour string masquait le bug d'interpolation PID attrapé par le dogfood PASSE-9).
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    def wake_pod(pod_id) do
      send(self(), {:woke, pod_id})
      :ok
    end

    # F181 : compensation — kill best-effort du pod avant retrait du verrou.
    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end
  end

  # Spawner dont le pod est DÉJÀ VIVANT (`pod_info` → `{:ok, _}`). Sert à tester le GATE de
  # sérialisation : un rôle project-scoped déjà vivant → le dispatcher DÉFÈRE (`:role_busy`), il ne
  # spawn ni ne rebrief un pod occupé. (Le rebrief-sur-vivant reste possible pour les `instance`.)
  defmodule StubSpawnerAlive do
    def spawn_pod(_profile, issue_id, opts) do
      send(self(), {:spawned, issue_id, opts})
      {:ok, self()}
    end

    def wake_pod(pod_id) do
      send(self(), {:woke, pod_id})
      :ok
    end

    def kill_pod(pod_id) do
      send(self(), {:killed, pod_id})
      :ok
    end

    def pod_info(pod_id) do
      send(self(), {:pod_info, pod_id})
      {:ok, %{phase: :monitoring}}
    end
  end

  # F181 : broker qui échoue tout enqueue → simule un échec POST-verrou (pod déjà spawné).
  defmodule FailTaskQueue do
    def enqueue(_pod_id, _attrs), do: {:error, :broker_down}
  end

  # SLOT-FREEZE : engineer en PIPE (lifetime_scope: pipe) → le gate prend la voie pipe-aware (vs one-shot).
  defmodule StubLoaderPipe do
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"slot_scope" => "project"},
           spec: %{"invocation" => %{"lifetime_scope" => "pipe"}}
         }}

    def load(_), do: {:error, :not_found}
  end

  # Spawner pipe CONFIGURABLE via le process dict (`:pipe_state`) — un seul stub pour les 4 etats du gate.
  # pod_info expose conditions + has_active_task (comme le vrai pod) ; reprovision_pipe_workspace trace.
  defmodule StubSpawnerPipe do
    def spawn_pod(_p, t, o) do
      send(self(), {:spawned, t, o})
      {:ok, self()}
    end

    def wake_pod(p) do
      send(self(), {:woke, p})
      :ok
    end

    def kill_pod(p) do
      send(self(), {:killed, p})
      :ok
    end

    def reprovision_pipe_workspace(p, project, opts) do
      send(self(), {:reprovisioned, p, project, opts})
      Process.get(:reprovision_result, :ok)
    end

    def pod_info(p) do
      send(self(), {:pod_info, p})

      case Process.get(:pipe_state, :dead) do
        :dead -> {:error, :not_found}
        :ready -> {:ok, %{conditions: [], has_active_task: false}}
        :busy_active -> {:ok, %{conditions: [], has_active_task: true}}
        :publishing -> {:ok, %{conditions: [:publishing], has_active_task: false}}
      end
    end
  end

  # F075 : loader qui SIGNALE chaque load(role) → permet d'asserter UN SEUL load par dispatch.
  defmodule CountingLoader do
    def load(role) do
      send(self(), {:f075_loaded, role})

      {:ok,
       %Fleet.CapProfile{
         kind: "CapabilityProfile",
         metadata: %{"slot_scope" => "project"},
         spec: %{}
       }}
    end
  end

  defp dispatch_opts(extra \\ []) do
    Keyword.merge(
      [
        repo: "lordzurp/lcars-test",
        forge_client: StubForge,
        loader: StubLoader,
        spawner: StubSpawner,
        task_queue: StubTaskQueue,
        # résolveur stub par défaut : pas de projet (les tests d'ordre ne clonent rien).
        project_resolver: fn _repo, _opts -> {:ok, nil} end,
        # #5.2 D2 — route par défaut (step build=engineer) : depuis le découplage, une issue ROUTELESS
        # est ONBOARDÉE (skip) au lieu de spawner. Les tests d'effet veulent un spawn → ils partent d'une
        # issue déjà routée. Les tests routés/onboard overrident `forge_opts`/`workflow_map_loader`.
        forge_opts: [_test_route: {:ok, {"g", "build"}}],
        # Loader générique (tout nom de map) : porte `max_rework_rounds` (budget rework lu comme donnée
        # côté rework PR ET issue). Les tests routés spécifiques overrident au besoin.
        workflow_map_loader: fn _name ->
          %{
            "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
            "max_rework_rounds" => 2
          }
        end
      ],
      extra
    )
  end

  describe "dispatch_issue/2 (effets, seams stubés)" do
    test "F075 : un seul load(role) par dispatch (fin du double-load sonde+spawn)" do
      payload = eng_issue()

      assert {:ok, {:spawned, _, "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(loader: CountingLoader))

      # decide charge le profil et le threade ; dispatch le réutilise → load appelé EXACTEMENT une fois.
      assert_received {:f075_loaded, "engineer"}
      refute_received {:f075_loaded, _}
    end

    test "spawn : ordre label-verrou → pod (plus de comment-lock), retourne {:ok, {:spawned, pod, role}}" do
      payload = eng_issue()

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts())

      # le brief = issue.body + l'instruction de LIVRAISON git-native (commit local + trailer),
      # sinon le pod « submit les contenus » au lieu de committer → :no_deliverable_commit.
      assert_received {:spawned, "issue-42", opts}
      assert opts[:brief] =~ "fais le hello"

      # #chantier pod-seed : nom RC Desktop = <projet>_<role> (projet = segment final du repo
      # "lordzurp/lcars-test" → "lcars-test"). Label exact, distinct du pod_id technique.
      assert opts[:rc_name] == "lcars-test_engineer"
      assert opts[:brief] =~ "git commit"
      assert opts[:brief] =~ "Co-authored-by: LCARS-engineer"

      # Voix de l'eng (info sortante) : le brief demande un `summary` posté sur la PR par le système.
      assert opts[:brief] =~ "summary"
      assert opts[:brief] =~ "Ta voix"
      # Blocked_dep : le brief dit à l'eng de marquer `blocked: true` plutôt que deviner/wedge.
      assert opts[:brief] =~ "blocked"

      # le brief est ENQUEUÉ en TaskQueue (sinon le pod se croit bootstrap → idle ; bug PASSE-9)
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", attrs}
      assert attrs.brief =~ "fais le hello"
      assert attrs.role == "engineer"

      # F071 : verrouille le 2ᵉ site `IssueId.compose` (enqueue_brief) — sinon un retour au littéral
      # "issue-#{number}" pour `issue_id` ne serait pas attrapé (le pod_id ≠ issue_id).
      assert attrs.issue_id == "issue-42"
      # kick best-effort émis
      assert_received {:woke, "lordzurp-lcars-test-engineer"}
    end

    test "GATE slot_scope: engineer (project) déjà vivant → DÉFÈRE :role_busy (sérialisé, pas de rebrief)" do
      payload = eng_issue()

      # StubSpawnerAlive : pod_info → {:ok,_} = le pod projet `<repo>-engineer` est DÉJÀ vivant (un autre
      # issue du repo en cours). Le gate sérialise les rôles project-scoped : on DÉFÈRE, on ne rebrief
      # PAS un pod occupé (ça wedgerait — un one-shot mid-tâche ne pull pas un 2ᵉ brief). Le poller
      # re-dispatch au tick suivant ; le pod meurt en fin de tâche → spawn frais pour le suivant.
      assert {:skipped, :role_busy} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(spawner: StubSpawnerAlive))

      # Le gate a CONSULTÉ pod_info (avec l'id PROJET) pour voir le pod vivant...
      assert_received {:pod_info, "lordzurp-lcars-test-engineer"}
      # ...puis a DÉFÉRÉ sans AUCUN effet de bord : pas de spawn, pas d'enqueue, pas de wake.
      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}
      refute_received {:woke, _}
    end

    test "GATE slot_scope: engineer (project) vivant → défère AVANT verrou/enqueue (rien à compenser)" do
      # Le gate défère AVANT de poser le verrou ou d'enqueuer → le task_queue défaillant n'est JAMAIS
      # atteint. Donc aucun verrou à retirer, aucun pod à tuer : la défère est sans effet de bord.
      assert {:skipped, :role_busy} =
               StepDispatcher.dispatch_issue(
                 eng_issue(),
                 dispatch_opts(spawner: StubSpawnerAlive, task_queue: FailTaskQueue)
               )

      refute_received {:removed_label, _}
      refute_received {:killed, _}
      refute_received {:enqueued, _, _}
    end

    test "F181 : échec POST-verrou (enqueue KO) → verrou retiré + pod tué (pas de stuck)" do
      payload = eng_issue()
      opts = dispatch_opts(task_queue: FailTaskQueue)

      assert {:error, {:enqueue_failed, :broker_down}} =
               StepDispatcher.dispatch_issue(payload, opts)

      # le pod avait spawné → tué (sinon orphelin) ; le verrou lcars-in-flight → retiré (sinon le
      # poller skipperait l'issue à jamais).
      assert_received {:spawned, "issue-42", _}
      assert_received {:killed, "lordzurp-lcars-test-engineer"}
      assert_received {:removed_label, "lcars-in-flight"}
    end

    # MA-17 — wake escalade (pod injoignable, re-wake KO → {:error,{:escalated,_}}). AVANT : le retour de
    # WakeRecovery.wake était jeté (`_ = wake(...)`) → dispatch_issue rendait {:ok,{:spawned}} → le poller
    # comptait `dispatched:1/errors:0` MENTEUR (pod jamais réveillé). Le seam `wake_recovery` simule
    # l'escalade ; on assert que le dispatch N'est PAS un succès silencieux mais `{:error,{:wake_unreached,_}}`.
    test "MA-17 : wake escaladé (pod injoignable) → dispatch {:error,{:wake_unreached}}, PAS {:ok,{:spawned}}" do
      payload = eng_issue()

      # Seam : le recovery de wake ESCALADE (équivalent re-wake KO → starfleet). Pas de hit
      # IncidentRegistry/forge réels — on injecte directement le verdict d'injoignabilité.
      escalating_wake = fn _pod_id, _respawn, _opts -> {:error, {:escalated, :dead}} end

      result =
        StepDispatcher.dispatch_issue(
          payload,
          dispatch_opts(wake_recovery: escalating_wake)
        )

      # LE finding : surtout PAS un succès dispatch silencieux (le poller le comptait dispatched:1).
      refute match?({:ok, {:spawned, _, _}}, result)

      assert {:error,
              {:wake_unreached, "lordzurp-lcars-test-engineer", "engineer", {:escalated, :dead}}} =
               result

      # Le pod ET le brief RESTENT en place (brief enqueué, le re-wake/escalade couvre) : PAS de
      # compensation (ce n'est pas un échec POST-verrou, c'est un wake injoignable). Le verrou tient.
      assert_received {:spawned, "issue-42", _}
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", _}
      refute_received {:removed_label, _}
      refute_received {:killed, _}
    end

    # MA-17 — contre-épreuve : un wake PROPRE (:ok) garde le dispatch en succès `{:ok,{:spawned}}` (le
    # tally `dispatched` reste juste quand le pod EST réellement réveillé).
    test "MA-17 : wake OK → dispatch reste {:ok,{:spawned}} (tally dispatched honnête)" do
      payload = eng_issue()
      clean_wake = fn _pod_id, _respawn, _opts -> :ok end

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, dispatch_opts(wake_recovery: clean_wake))

      refute_received {:removed_label, _}
      refute_received {:killed, _}
    end

    test "skip in_flight : pas de spawn" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}]})

      assert {:skipped, :in_flight} = StepDispatcher.dispatch_issue(payload, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "projet résolu → injecté dans spawn_opts (:project, F-03 base_sha pinné)" do
      payload = eng_issue()

      project = %{
        "repo_path" => "http://10.42.0.118/lordzurp/lcars-test.git",
        "base_branch" => "main",
        "base_sha" => "cafe1234"
      }

      opts = dispatch_opts(project_resolver: fn _repo, _opts -> {:ok, project} end)

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:project] == project
      assert spawn_opts[:brief] =~ "fais le hello"
    end

    test "route gravée → rôle dérivé de la workflow_map (step build=engineer) + pipeline/step injectés (A2.1, #8)" do
      payload = eng_issue()

      # #8 : le rôle vient DÉSORMAIS de la workflow_map (WorkflowMapNav.step_role), pas de producer_role en dur.
      # Ici le step courant "build" porte role=engineer → rôle engineer (et route injectée, A2.1).
      workflow_map = %{
        "name" => "poc-cycle",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"poc-cycle", "build"}}],
          workflow_map_loader: fn "poc-cycle" -> workflow_map end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:workflow_map] == "poc-cycle"
      assert spawn_opts[:step] == "build"
    end

    test "#8 : route sur un step AMONT (brief-review/consultant) → spawn le CONSULTANT, pas l'eng" do
      payload = eng_issue()

      # La workflow_map EST la machine à états : le 1er step (racine `needs:[]`) est brief-review/consultant.
      # decide() rendait "engineer" (DN §1) ; workflow_map_role override avec le rôle du step courant → consultant.
      workflow_map = %{
        "name" => "brief-gate",
        "steps" => %{
          "brief-review" => %{"role" => "consultant", "needs" => []},
          "build" => %{"role" => "engineer", "needs" => ["brief-review"]}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"brief-gate", "brief-review"}}],
          workflow_map_loader: fn "brief-gate" -> workflow_map end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-consultant", "consultant"}} =
               StepDispatcher.dispatch_issue(payload, opts)
    end

    test "#8.B : brief_kind:judge AU STEP override un profil worker (engineer) → brief JUGE" do
      payload = eng_issue()

      # Le step déclare brief_kind:judge ; le rôle engineer a un profil WORKER. L'override per-step
      # doit produire un brief JUGE (désamorcé), PAS le brief worker (issue body + "Livraison git-native").
      workflow_map = %{
        "name" => "g",
        "steps" => %{
          "review" => %{"role" => "engineer", "needs" => [], "brief_kind" => "judge"}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:spawned, "issue-42", spawn_opts}
      refute spawn_opts[:brief] =~ "Livraison (git-native)"
    end

    test "#8.B : sans brief_kind au step → défaut du profil (engineer=worker → brief worker)" do
      payload = eng_issue()

      workflow_map = %{
        "name" => "g",
        "steps" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "build"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StepDispatcher.dispatch_issue(payload, opts)
      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:brief] =~ "Livraison (git-native)"
    end

    test "SÉCU : brief_kind hors-vocab au step → raise (jamais retombé sur worker en silence)" do
      payload = eng_issue()

      # `reviewer` n'est PAS du vocabulaire {worker, judge}. AVANT le fix, ce hors-vocab tombait sur la
      # clause `_worker` → brief EXÉCUTABLE pour un rôle qui aurait dû être désamorcé. La judge-ness est
      # une propriété de sécurité : elle ne s'infère pas par omission → fail-loud.
      workflow_map = %{
        "name" => "g",
        "steps" => %{
          "review" => %{"role" => "engineer", "needs" => [], "brief_kind" => "reviewer"}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert_raise ArgumentError, ~r/hors vocabulaire \{worker, judge\}/, fn ->
        StepDispatcher.dispatch_issue(payload, opts)
      end
    end

    test "SÉCU : judge_target hors-vocab (kind=judge) → raise (la cible d'un juge ne s'infère pas)" do
      payload = eng_issue()

      workflow_map = %{
        "name" => "g",
        "steps" => %{
          "review" => %{
            "role" => "engineer",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "subject"
          }
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          workflow_map_loader: fn "g" -> workflow_map end
        )

      assert_raise ArgumentError, ~r/hors vocabulaire \{brief, deliverable\}/, fn ->
        StepDispatcher.dispatch_issue(payload, opts)
      end
    end

    test "#8.E : judge_target:brief → brief en cadrage BRIEF (juge le issue.body, pas un livrable)" do
      # F-S2-1 : le brief = body de l'ISSUE en main (payload), PAS un get_issue redondant.
      payload = eng_issue(%{"body" => "MON BRIEF A JUGER"})

      workflow_map = %{
        "name" => "mg",
        "steps" => %{
          "brief-review" => %{
            "role" => "consultant",
            "needs" => [],
            "brief_kind" => "judge",
            "judge_target" => "brief"
          }
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"mg", "brief-review"}}],
          workflow_map_loader: fn "mg" -> workflow_map end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-consultant", "consultant"}} =
               StepDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      brief = spawn_opts[:brief]
      # cadrage BRIEF (subject:brief) + le brief à juger, PAS le cadrage livrable.
      assert brief =~ "Brief à juger"
      assert brief =~ "MON BRIEF A JUGER"
      refute brief =~ "Livrable à juger (outputs du step"
      refute brief =~ "Livraison (git-native)"
    end

    test "#5.2 D2 — issue ROUTELESS → onboardée sur la workflow_map par défaut (skip), PAS de spawn eng" do
      payload = eng_issue()

      # route :none (override de la route par défaut) + workflow_map par défaut brief-gate (1er step brief-review).
      opts =
        dispatch_opts(
          forge_opts: [_test_route: :none],
          workflow_map_loader: fn "brief-gate" ->
            %{"steps" => %{"brief-review" => %{"role" => "consultant", "needs" => []}}}
          end
        )

      assert {:skipped, :onboarded} = StepDispatcher.dispatch_issue(payload, opts)

      # la workflow_map par défaut a été GRAVÉE (le tick suivant dispatchera le consultant) ; AUCUN spawn eng.
      assert_received {:routed, 42, "brief-gate", "brief-review"}
      refute_received {:spawned, _, _}
    end

    test "échec lecture route → {:error, {:route_resolution, _}}, AUCUN verrou ni spawn" do
      payload = eng_issue()
      opts = dispatch_opts(forge_opts: [_test_route: {:error, :http_500}])

      assert {:error, {:route_resolution, :http_500}} =
               StepDispatcher.dispatch_issue(payload, opts)

      refute_received {:spawned, _, _}
    end

    test "échec résolution projet → {:error}, AUCUN verrou posé ni spawn" do
      payload = eng_issue()

      opts =
        dispatch_opts(project_resolver: fn _repo, _opts -> {:error, :ls_remote_timeout} end)

      assert {:error, {:project_resolution, :ls_remote_timeout}} =
               StepDispatcher.dispatch_issue(payload, opts)

      # résolution AVANT toute écriture forge : pas de spawn, pas de verrou orphelin
      refute_received {:spawned, _, _}
    end

    # ====================================================================
    # SLOT-FREEZE — gate PIPE-aware : un engineer PIPE (resident) est re-brief selon son etat.
    #   dead  -> spawn frais ; busy (tache active OU :publishing) -> DEFERE ; ready -> reprovision COLD +
    #   rebrief. (project["base_sha"] est passe au reset ; le slug = la branche feature du issue.)
    # ====================================================================
    test "GATE pipe DEAD (1er issue) : spawn frais, PAS de reprovision" do
      Process.put(:pipe_state, :dead)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(eng_issue(), opts)

      assert_received {:spawned, "issue-42", _opts}
      refute_received {:reprovisioned, _, _, _}
    end

    test "GATE pipe BUSY (tache active) : DEFERE :role_busy, ni reprovision ni spawn (pod en plein travail)" do
      Process.put(:pipe_state, :busy_active)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe PUBLISHING (livrable en vol) : DEFERE :role_busy (pas de reset pendant le push)" do
      Process.put(:pipe_state, :publishing)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      refute_received {:reprovisioned, _, _, _}
      refute_received {:spawned, _, _}
    end

    test "GATE pipe READY (idle + livrable confirme) : reprovision COLD (base_sha + slug) PUIS re-brief" do
      Process.put(:pipe_state, :ready)

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_issue(eng_issue(), opts)

      # reset cold appele AVANT le rebrief, avec le projet (base_sha) + le slug du issue.
      assert_received {:reprovisioned, "lordzurp-lcars-test-engineer",
                       %{"base_sha" => "basesha1"}, [slug: _slug]}

      # re-brief (pod vivant) -> enqueue + wake, PAS de re-spawn frais.
      refute_received {:spawned, _, _}
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", _}
      assert_received {:woke, "lordzurp-lcars-test-engineer"}
    end

    test "GATE pipe READY mais reset KO -> DEFERE :role_busy (pas de rebrief sur workspace sale)" do
      Process.put(:pipe_state, :ready)
      Process.put(:reprovision_result, {:error, {:reset_failed, :git_exit}})

      opts =
        dispatch_opts(
          loader: StubLoaderPipe,
          spawner: StubSpawnerPipe,
          project_resolver: fn _r, _o -> {:ok, %{"base_sha" => "basesha1"}} end
        )

      assert {:skipped, :role_busy} = StepDispatcher.dispatch_issue(eng_issue(), opts)

      assert_received {:reprovisioned, _, _, _}
      refute_received {:enqueued, _, _}
      refute_received {:spawned, _, _}
    end
  end

  describe "dispatch_review/2 (juge PR-driven, Corr.3 4-C)" do
    defp pr(fields \\ %{}) do
      Map.merge(
        %{
          "number" => 6,
          "head" => %{"ref" => "lcars/issue-42-engineer"},
          "requested_reviewers" => [%{"login" => "Qualifier"}],
          "labels" => []
        },
        fields
      )
    end

    test "PR avec review demandee -> spawn le juge (issue=ISSUE, verrou sur la PR)" do
      opts =
        dispatch_opts(
          forge_opts: [
            _test_route: {:ok, {"poc", "spec-review"}},
            _test_issue_body: "implémente le décodeur morse"
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-qualifier", "qualifier"}} =
               StepDispatcher.dispatch_review(pr(), opts)

      # issue_id = l'ISSUE (remontee de head.ref lcars/issue-42-engineer), PAS la PR
      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:workflow_map] == "poc" and spawn_opts[:step] == "spec-review"
      # brief juge desamorce (brief_kind: judge) — pas un corps executable
      assert spawn_opts[:brief] =~ "JUGER"

      # Fix famine-d'info (juge) : predecessor vide (git-native) → le juge est POINTÉ sur son
      # workspace ET reçoit le CRITÈRE (body de l'issue, désamorcé en contexte).
      # La base du diff est `origin/main` (clone mono-branche : le ref local `main` n'existe pas —
      # bug live morse : `git diff main..HEAD` → fatal unknown revision → halt_wait_input intermittent).
      assert spawn_opts[:brief] =~ "git diff origin/main...HEAD"
      assert spawn_opts[:brief] =~ "implémente le décodeur morse"

      # enqueue cible le pod_id pr-... ; issue_id = l'issue
      assert_received {:enqueued, "lordzurp-lcars-test-pr-6-qualifier", attrs}
      assert attrs.issue_id == "issue-42"
      assert attrs.role == "qualifier"
      assert_received {:woke, "lordzurp-lcars-test-pr-6-qualifier"}
    end

    test "PR verrouillee (lcars-in-flight) -> skip, pas de spawn" do
      pr = pr(%{"labels" => [%{"name" => "lcars-in-flight"}]})
      assert {:skipped, :in_flight} = StepDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "PR sans juge (orpheline/humaine) -> ADOPTION : pose les juges, review au tick suivant" do
      pr = pr(%{"requested_reviewers" => []})

      # requested == [] (ni requested_reviewers, ni jury) = PR NON mise en place par le pipeline (typ.
      # humaine/fork découverte par le poller). Gate agent-agnostique → on POSE les juges au lieu de skip
      # `:no_verdict`. Ils spawnent au tick SUIVANT (pas ici → `refute_received {:spawned}`).
      assert {:ok, {:adopted, _pr_number, reviewers}} =
               StepDispatcher.dispatch_review(pr, dispatch_opts())

      assert reviewers != []
      assert_received {:requested_review, _index, ^reviewers}
      refute_received {:spawned, _, _}
    end

    test "②.1d : tous les juges demandés ont APPROUVÉ -> PROMOTE (comment de fin + merge FF, gatekeeper)" do
      # les 2 juges demandés ont chacun un verdict décisif APPROVED → pending vide → tous verts → merge.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [_test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved}]
        )

      assert {:ok, {:merged, 6}} = StepDispatcher.dispatch_review(pr, opts)

      # le merge FF a bien ete declenche sur la PR (close explicite via seal_and_merge, plus de Closes #N)
      assert_received {:merged, 6}
      refute_received {:spawned, _, _}

      # Die-on-promote : le kill-site cible `for_issue` (id `...-issue-42-engineer`). Pour l'eng
      # one-shot project-scoped c'est un pod_id PHANTÔME → no-op SÛR (cf. step_dispatcher : utiliser
      # for_repo ici tuerait l'eng s'il code une AUTRE issue). On asserte l'APPEL au kill avec l'id
      # issue-keyé (même s'il no-op), inconditionnel côté dispatcher.
      assert_received {:killed, "lordzurp-lcars-test-issue-42-engineer"}

      # RÉGRESSION QoL 2026-07-07 : ce chemin (merge poller-driven, no-workflow_map) ne levait JAMAIS
      # le verrou ISSUE — seul le verrou PR se levait (via route(:reviewed) de chaque juge, hors-scope
      # ici). `promote_pr` doit désormais lever aussi l'ISSUE (42), la brique entière est finie au merge.
      assert_received {:stopped_watch, 42}
    end

    # ── Angle « la machine lit l'état-forge complet » : échec de merge CLASSIFIÉ (2026-07-07) ──
    # Remplace l'ancien fourre-tout « tout échec = conflit → eng rebase » (impossible car forge-aveugle →
    # mur live). L'échec est relu de l'objet PR (MergeOutcome) et aiguillé sur sa cause RÉELLE.

    test "échec merge + PR mergeable:false (VRAI conflit git) → escalade HONNÊTE arch (pas d'eng-rebase impossible)" do
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 409, "conflict"}},
            _test_pull: %{
              "number" => 6,
              "state" => "open",
              "draft" => false,
              "mergeable" => false
            }
          ]
        )

      # vrai conflit → escalade arch honnête (le système ne rebase PAS — barrière forge-aveugle) ;
      # AUCUN spawn d'eng, AUCUN merge. Forme `{:skipped, _}` gérée par le poller.
      assert {:skipped, {:merge_blocked_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "échec merge + PR mergeable:true (POLICY : re-request humaine) → re-dispatch le juge re-demandé" do
      # LE cas hello-kitty : git mergeable, mais la branch-protection refuse (un juge re-demandé à la main
      # a reset le compteur d'approbations). On re-dispatche ce juge (le bouton fait enfin son job), PAS
      # d'escalade, PAS de traitement conflit.
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6,
          "head" => %{"ref" => "lcars/issue-42-engineer"}
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "Does not have enough approvals"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: ["qualifier"]
          ]
        )

      assert {:ok, {:spawned, _pod, "qualifier"}} = StepDispatcher.dispatch_review(pr, opts)
      refute_received {:merged, _}
    end

    test "échec merge + PR mergeable:true SANS re-request → escalade honnête (policy non levable, pas de wedge muet)" do
      pr =
        pr(%{
          "requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}],
          "number" => 6
        })

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :approved},
            _test_merge_result: {:error, {:http, 405, "policy"}},
            _test_pull: %{"number" => 6, "state" => "open", "draft" => false, "mergeable" => true},
            _test_rerequested: []
          ]
        )

      assert {:skipped, {:merge_blocked_escalated, 6}} = StepDispatcher.dispatch_review(pr, opts)
    end

    test "PR repassée en DRAFT (garde dispatch-juge) → skip, pas de review ni de merge" do
      pr =
        pr(%{
          "number" => 6,
          "draft" => true,
          "requested_reviewers" => [%{"login" => "Qualifier"}]
        })

      assert {:skipped, :draft} = StepDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
      refute_received {:merged, _}
    end

    test "②.1d : un juge a demandé des changements (les autres approuvent) -> re-spawn le PRODUCTEUR" do
      # tous les juges demandés ont un verdict (pending vide), mais un :changes_requested → rework.
      pr =
        pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}, %{"login" => "Reviewer"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved, "reviewer" => :changes_requested},
            _test_route: {:ok, {"poc", "build"}},
            _test_feedback: [
              %{"login" => "reviewer", "body" => "le timing des points/traits est faux"}
            ]
          ]
        )

      # producteur = role git_native de head (lcars/issue-42-engineer) = engineer ; verrou sur la PR.
      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:brief] =~ "REWORK"

      # Fix famine-d'info (rework) : le BODY de la review REQUEST_CHANGES est injecté (sinon « corrige
      # selon la review » est creux → l'eng devine à l'aveugle → blocked_dep/wedge, prouvé live morse).
      assert spawn_opts[:brief] =~ "le timing des points/traits est faux"
      assert spawn_opts[:brief] =~ "reviewer"

      # Voix de l'eng (rework) : le brief demande un `summary` = réponse au reviewer, posté sur la PR.
      assert spawn_opts[:brief] =~ "summary"
      assert_received {:enqueued, "lordzurp-lcars-test-engineer", attrs}
      assert attrs.role == "engineer"
    end

    test "MA-06 : rework SOUS le budget (rounds <= max) -> re-spawn producteur (pas d'escalade)" do
      # Garde-fou de borne basse : tant que le budget n'est pas épuisé, le rework continue normalement.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_rework_rounds: {:ok, 2},
            _test_route: {:ok, {"poc", "build"}}
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)
    end

    test "MA-06 : N rounds de rework PR (rounds > budget) -> ESCALADE ARCH (borné, pas de churn infini)" do
      # État illégal AVANT MA-06 : `dispatch_rework` re-spawnait le producteur SANS compteur → si l'eng ne
      # satisfait jamais le juge, rework INFINI (le frein workflow_map `rebound` n'est pas appelé sur ce chemin). Le
      # fix borne par un compteur forge-natif (nb REQUEST_CHANGES) : > budget (2) → escalade arch (pas de
      # re-spawn). On vérifie le retour {:skipped, {:rework_exhausted_escalated, _}} + le label awaits-arch posé.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            # Route présente → le budget (= max_rework_rounds:2 du loader générique) est LISIBLE : on teste
            # bien « rounds(3) > budget(2) → escalade », pas un budget illisible (couvert par le test suivant).
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:ok, 3}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      # PAS de re-spawn du producteur (fin du churn) ; le verrou humain awaits-arch est posé sur l'ISSUE.
      refute_received {:spawned, _, _}
    end

    test "MA-06 : budget illisible (forge {:error}) -> escalade (pas de re-spawn aveugle)" do
      # Symétrique de `rebound` : un budget non vérifiable ne doit PAS faire boucler → on remonte à l'arch.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            # Route présente → budget lisible : on teste bien le COMPTEUR illisible (count {:error}), pas la route.
            _test_route: {:ok, {"g", "build"}},
            _test_rework_rounds: {:error, {:http, 500, "boom"}}
          ]
        )

      assert {:skipped, {:rework_exhausted_escalated, 6}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:spawned, _, _}
    end

    test "budget PR map-level HONORÉ : max_rework_rounds:5 rebondit à 4 rounds (le défaut 2 escaladerait)" do
      # Preuve que le budget PR vient de la DONNÉE du map (spec.max_rework_rounds), pas d'un défaut codé :
      # un map à 5 laisse rebondir à 4 rounds (4 ≤ 5) là où l'ancien défaut 2 aurait escaladé.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}]})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :changes_requested},
            _test_route: {:ok, {"budget5", "build"}},
            _test_rework_rounds: {:ok, 4}
          ],
          workflow_map_loader: fn "budget5" ->
            %{
              "steps" => %{"build" => %{"role" => "engineer", "needs" => []}},
              "max_rework_rounds" => 5
            }
          end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-engineer", "engineer"}} =
               StepDispatcher.dispatch_review(pr, opts)
    end

    test "F-E8 : juge tombé de requested_reviewers (mais dans les review-records) reste au jury -> spawn, PAS merge" do
      # BUG live PoC-7 : Gitea a fait DISPARAÎTRE le reviewer de `requested_reviewers` SANS qu'il vote
      # (review-record encore REQUEST_REVIEW). Le champ volatil ne montre que le qualifier (qui a approuvé).
      # SANS le fix : requested=[qualifier], pending=[] → MERGE prématuré sur 1 juge (demi-jury). AVEC : le
      # jury vient des review-records (`pr_review_state.reviewers` = [qualifier, reviewer]) → union →
      # pending=[reviewer] → on spawn le reviewer, JAMAIS de merge.
      pr = pr(%{"requested_reviewers" => [%{"login" => "Qualifier"}], "number" => 6})

      opts =
        dispatch_opts(
          forge_opts: [
            _test_verdicts: %{"qualifier" => :approved},
            _test_reviewers: ["qualifier", "reviewer"],
            _test_route: {:ok, {"poc", "review"}},
            _test_issue_body: "implémente le décodeur morse"
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-reviewer", "reviewer"}} =
               StepDispatcher.dispatch_review(pr, opts)

      refute_received {:merged, _}
    end

    test "PR sur branche non-fleet -> skip (jamais misroutee)" do
      pr = pr(%{"head" => %{"ref" => "refs/pull/6/head"}})
      assert {:skipped, :not_fleet_branch} = StepDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "reviewer = role inconnu -> skip :no_role" do
      pr = pr(%{"requested_reviewers" => [%{"login" => "lordzurp"}]})
      assert {:skipped, :no_role} = StepDispatcher.dispatch_review(pr, dispatch_opts())
    end

    test "F181 : echec POST-verrou (enqueue KO) -> verrou PR retire + pod tue" do
      opts = dispatch_opts(task_queue: FailTaskQueue, forge_opts: [_test_route: :none])

      assert {:error, {:enqueue_failed, :broker_down}} =
               StepDispatcher.dispatch_review(pr(), opts)

      assert_received {:killed, "lordzurp-lcars-test-pr-6-qualifier"}
      assert_received {:removed_label, "lcars-in-flight"}
    end

    test "MA-01 (bug B) : l'issue parente porte awaits-arch -> skip :awaits_arch, PAS de re-dispatch juge" do
      # La PR head=lcars/issue-42-engineer (issue 42) a un reviewer demandé → SANS le fix, le juge serait
      # re-spawné à chaque tick. Mais l'issue 42 est dans le SET `:awaits_arch_ids` (escalade en cours) →
      # `dispatch_review` skippe (symétrique de `decide/1` côté issue) → fin du churn.
      opts = dispatch_opts(awaits_arch_ids: MapSet.new([42]))

      assert {:skipped, :awaits_arch} = StepDispatcher.dispatch_review(pr(), opts)
      refute_received {:spawned, _, _}
      refute_received {:enqueued, _, _}
    end

    test "MA-01 (bug B) : awaits_arch_ids ne contient PAS l'issue -> dispatch normal (back-compat)" do
      # Garde-fou : le skip ne se déclenche QUE pour l'issue concernée. Issue 42 (PR head) absente du SET
      # (ici {99}) → dispatch normal du juge. Et défaut MapSet vide (autres callers) → inchangé.
      opts =
        dispatch_opts(
          awaits_arch_ids: MapSet.new([99]),
          forge_opts: [_test_route: {:ok, {"poc", "spec-review"}}, _test_issue_body: "x"]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-qualifier", "qualifier"}} =
               StepDispatcher.dispatch_review(pr(), opts)
    end
  end

  # F-PARALLEL-PR-CONFLICT — DÉCONFLATION clone-base / gate-base. Pour une résolution par rebase, le pod
  # part de la feature (clone-base) mais son livrable doit DESCENDRE de `main` (gate-base) → le resolver
  # pinne les DEUX séparément quand `:gate_base_branch` est posé. Fixture : un bare repo local = la « forge ».
  describe "default_project_resolver/2 — gate_base_sha déconflé" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      forge = Path.join(tmp, "forge")
      src = Path.join(tmp, "src")
      File.mkdir_p!(forge)
      gg = fn args -> {_o, 0} = System.cmd("git", ["-C", src] ++ args, stderr_to_stdout: true) end

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
      gg.(["config", "user.email", "engineer@lcars.local"])
      gg.(["config", "user.name", "LCARS-engineer"])
      File.write!(Path.join(src, "base.txt"), "c0")
      gg.(["add", "."])
      gg.(["commit", "-q", "-m", "c0"])

      # feature-branch (le travail du producteur, depuis C0)
      gg.(["checkout", "-q", "-b", "lcars/issue-3-engineer"])
      File.write!(Path.join(src, "feat.txt"), "feat")
      gg.(["add", "."])
      gg.(["commit", "-q", "-m", "feat"])
      {ft, 0} = System.cmd("git", ["-C", src, "rev-parse", "HEAD"], stderr_to_stdout: true)

      # `main` avance (issue parallèle fusionné) → C1
      gg.(["checkout", "-q", "main"])
      File.write!(Path.join(src, "para.txt"), "para")
      gg.(["add", "."])
      gg.(["commit", "-q", "-m", "c1"])
      {m1, 0} = System.cmd("git", ["-C", src, "rev-parse", "HEAD"], stderr_to_stdout: true)

      # publie les deux branches dans le bare = `<forge>/owner/proj.git` (base_url = `<forge>`)
      bare = Path.join(forge, "owner/proj.git")
      File.mkdir_p!(Path.dirname(bare))
      {_, 0} = System.cmd("git", ["clone", "-q", "--bare", src, bare], stderr_to_stdout: true)

      %{base_url: forge, feature_tip: String.trim(ft), main_c1: String.trim(m1)}
    end

    test "resolve (gate_base_branch=main) : base_sha=feature_tip (clone) MAIS gate_base_sha=main",
         ctx do
      assert {:ok, proj} =
               StepDispatcher.default_project_resolver("owner/proj",
                 base_branch: "lcars/issue-3-engineer",
                 gate_base_branch: "main",
                 forge_opts: [base_url: ctx.base_url]
               )

      # clone-base = tip de la feature (le pod part de SON travail) ; gate-base = main (cible du rebase).
      assert proj["base_sha"] == ctx.feature_tip
      assert proj["gate_base_sha"] == ctx.main_c1
      refute proj["base_sha"] == proj["gate_base_sha"]
    end

    test "forward (sans gate_base_branch) : gate_base_sha == base_sha (clone-base, inchangé)",
         ctx do
      assert {:ok, proj} =
               StepDispatcher.default_project_resolver("owner/proj",
                 base_branch: "lcars/issue-3-engineer",
                 forge_opts: [base_url: ctx.base_url]
               )

      assert proj["base_sha"] == ctx.feature_tip
      assert proj["gate_base_sha"] == proj["base_sha"]
    end
  end
end
