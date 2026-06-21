defmodule Fleet.Pilot.StageDispatcherTest do
  use ExUnit.Case, async: true

  alias Fleet.Pilot.StageDispatcher

  defp issue(fields) do
    %{
      "issue" =>
        Map.merge(
          %{"number" => 42, "body" => "fais le hello", "labels" => [], "assignees" => []},
          fields
        )
    }
  end

  # Ticket-producteur du modèle forge-state-machine (DN §1) : assignee = l'HUMAIN owner. Le rôle
  # producteur est un INVARIANT côté poller (`:producer_role`, défaut engineer), pas un marqueur
  # par-ticket. `fields` override (labels, body…).
  defp eng_issue(fields \\ %{}) do
    issue(Map.merge(%{"assignees" => [%{"login" => "lordzurp"}]}, fields))
  end

  # #5.2 D2 — decide = PORTE pure : verrou → skip, sinon :engage. Pas d'ownership (scoping forge-side amont),
  # pas de rôle (vient de la route via carte_role), pas de load (carte_role charge).
  describe "decide/1 (porte pure)" do
    test "issue non verrouillée → :engage (rôle ET action spawn/onboard décidés en aval)" do
      assert :engage = StageDispatcher.decide(eng_issue())
    end

    test "verrou lcars-in-flight présent → {:skip, :in_flight}" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}]})
      assert {:skip, :in_flight} = StageDispatcher.decide(payload)
    end

    test "verrou HUMAIN lcars-awaits-arch → {:skip, :awaits_arch} (A2.3b, pas de re-dispatch)" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-awaits-arch"}]})
      assert {:skip, :awaits_arch} = StageDispatcher.decide(payload)
    end
  end

  # Seams stubs pour dispatch_issue/2
  defmodule StubForge do
    def add_label(_repo, _n, _label, _opts), do: {:ok, :added}
    def post_comment(_repo, _n, _body, _opts), do: {:ok, :posted}
    # A2.1 : route lue depuis forge_opts[:_test_route] (défaut :none = hors-carte / 1-stage).
    def get_route(_repo, _n, opts), do: Keyword.get(opts, :_test_route, :none)

    # #5.2 D2 — onboarding : grave la route initiale de la carte par défaut. Capture pour assertion.
    def post_route(_repo, n, carte, stage, _opts) do
      send(self(), {:routed, n, carte, stage})
      {:ok, :posted}
    end

    # F077 : le mandat juge lit le result du prédécesseur (option B). Stub : forge_opts[:_test_pred].
    def get_predecessor_result(_repo, _n, opts), do: Keyword.get(opts, :_test_pred, :none)

    # Fix famine-d'info : build_judge_mandate lit le critère (body de l'issue) via get_issue.
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

    # F181 : compensation — retrait du verrou sur échec post-verrou.
    def remove_label(_repo, _n, label, _opts) do
      send(self(), {:removed_label, label})
      {:ok, :removed}
    end

    # ②.1d : merge FF (promote PR-state-driven, tous les juges OK). Signale pour assertion.
    def merge_pr(_repo, index, _opts) do
      send(self(), {:merged, index})
      :ok
    end
  end

  defmodule StubLoader do
    def load("engineer"),
      do: {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}}

    # F077 : un rôle juge déclare `mandate_kind: judge` dans son cap-profile (pas un nom magique).
    def load("gatekeeper"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "gatekeeper"},
           spec: %{"mandate_kind" => "judge"}
         }}

    # Corr.3 : un juge de PR (qualifier/reviewer) declare aussi mandate_kind: judge.
    def load(role) when role in ["qualifier", "reviewer"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"mandate_kind" => "judge"}
         }}

    # #8 : le consultant relit le MANDAT (juge) → mandate_kind: judge.
    def load("consultant"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "consultant"},
           spec: %{"mandate_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  defmodule StubSpawner do
    # Fidèle au contrat réel `Spawner.spawn_pod/3` : retourne `{:ok, pid()}`, PAS une string
    # (un retour string masquait le bug d'interpolation PID attrapé par le dogfood PASSE-9).
    def spawn_pod(_profile, ticket_id, opts) do
      send(self(), {:spawned, ticket_id, opts})
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

  # BL-055 : spawner dont le pod est DÉJÀ VIVANT (`pod_info` → `{:ok, _}`) → le dispatcher doit
  # RE-MANDATER (enqueue + wake), JAMAIS re-spawn.
  defmodule StubSpawnerAlive do
    def spawn_pod(_profile, ticket_id, opts) do
      send(self(), {:spawned, ticket_id, opts})
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

  defmodule StubTaskQueue do
    def enqueue(pod_id, attrs) do
      send(self(), {:enqueued, pod_id, attrs})
      {:ok, %{id: "task-1"}}
    end
  end

  # F181 : broker qui échoue tout enqueue → simule un échec POST-verrou (pod déjà spawné).
  defmodule FailTaskQueue do
    def enqueue(_pod_id, _attrs), do: {:error, :broker_down}
  end

  # F075 : loader qui SIGNALE chaque load(role) → permet d'asserter UN SEUL load par dispatch.
  defmodule CountingLoader do
    def load(role) do
      send(self(), {:f075_loaded, role})
      {:ok, %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{}, spec: %{}}}
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
        clock: fn :second -> 1_700_000_000 end,
        # résolveur stub par défaut : pas de projet (les tests d'ordre ne clonent rien).
        project_resolver: fn _repo, _opts -> {:ok, nil} end,
        # #5.2 D2 — route par défaut (stage build=engineer) : depuis le découplage, une issue ROUTELESS
        # est ONBOARDÉE (skip) au lieu de spawner. Les tests d'effet veulent un spawn → ils partent d'une
        # issue déjà routée. Les tests routés/onboard overrident `forge_opts`/`carte_loader`.
        forge_opts: [_test_route: {:ok, {"g", "build"}}],
        carte_loader: fn "g" ->
          %{"stages" => %{"build" => %{"role" => "engineer", "needs" => []}}}
        end
      ],
      extra
    )
  end

  describe "dispatch_issue/2 (effets, seams stubés)" do
    test "F075 : un seul load(role) par dispatch (fin du double-load sonde+spawn)" do
      payload = eng_issue()

      assert {:ok, {:spawned, _, "engineer"}} =
               StageDispatcher.dispatch_issue(payload, dispatch_opts(loader: CountingLoader))

      # decide charge le profil et le threade ; dispatch le réutilise → load appelé EXACTEMENT une fois.
      assert_received {:f075_loaded, "engineer"}
      refute_received {:f075_loaded, _}
    end

    test "spawn : ordre label-verrou → pod (plus de comment-lock), retourne {:ok, {:spawned, pod, role}}" do
      payload = eng_issue()

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-engineer", "engineer"}} =
               StageDispatcher.dispatch_issue(payload, dispatch_opts())

      # le mandat = issue.body + l'instruction de LIVRAISON git-native (commit local + trailer),
      # sinon le pod « submit les contenus » au lieu de committer → :no_deliverable_commit.
      assert_received {:spawned, "issue-42", opts}
      assert opts[:mandate] =~ "fais le hello"
      assert opts[:mandate] =~ "git commit"
      assert opts[:mandate] =~ "Co-authored-by: LCARS-engineer"

      # Voix de l'eng (info sortante) : le mandat demande un `summary` posté sur la PR par le système.
      assert opts[:mandate] =~ "summary"
      assert opts[:mandate] =~ "Ta voix"
      # Blocked_dep : le mandat dit à l'eng de marquer `blocked: true` plutôt que deviner/wedge.
      assert opts[:mandate] =~ "blocked"

      # le mandat est ENQUEUÉ en TaskQueue (sinon le pod se croit bootstrap → idle ; bug PASSE-9)
      assert_received {:enqueued, "lordzurp-lcars-test-issue-42-engineer", attrs}
      assert attrs.brief =~ "fais le hello"
      assert attrs.role == "engineer"

      # F071 : verrouille le 2ᵉ site `TicketId.compose` (enqueue_mandate) — sinon un retour au littéral
      # "issue-#{number}" pour `ticket_id` ne serait pas attrapé (le pod_id ≠ ticket_id).
      assert attrs.ticket_id == "issue-42"
      # kick best-effort émis
      assert_received {:woke, "lordzurp-lcars-test-issue-42-engineer"}
    end

    test "BL-055 : pod déjà vivant (id stable) → RE-MANDATE (enqueue+wake), PAS de re-spawn" do
      payload = eng_issue()

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-engineer", "engineer"}} =
               StageDispatcher.dispatch_issue(payload, dispatch_opts(spawner: StubSpawnerAlive))

      # idempotent : le dispatcher a CONSULTÉ pod_info, l'a vu vivant → AUCUN spawn_pod.
      assert_received {:pod_info, "lordzurp-lcars-test-issue-42-engineer"}
      refute_received {:spawned, _, _}
      # le mandat de rework est quand même enqueué + le pod réveillé (re-mandate).
      assert_received {:enqueued, "lordzurp-lcars-test-issue-42-engineer", _attrs}
      assert_received {:woke, "lordzurp-lcars-test-issue-42-engineer"}
    end

    test "BL-055 : pod vivant + enqueue KO → verrou retiré mais pod PAS tué (contexte préservé)" do
      assert {:error, {:enqueue_failed, :broker_down}} =
               StageDispatcher.dispatch_issue(
                 eng_issue(),
                 dispatch_opts(spawner: StubSpawnerAlive, task_queue: FailTaskQueue)
               )

      # compensation : on retire le verrou MAIS on ne tue PAS l'eng vivant (un re-mandate raté ≠ kill).
      assert_received {:removed_label, "lcars-in-flight"}
      refute_received {:killed, _}
    end

    test "F181 : échec POST-verrou (enqueue KO) → verrou retiré + pod tué (pas de stuck)" do
      payload = eng_issue()
      opts = dispatch_opts(task_queue: FailTaskQueue)

      assert {:error, {:enqueue_failed, :broker_down}} =
               StageDispatcher.dispatch_issue(payload, opts)

      # le pod avait spawné → tué (sinon orphelin) ; le verrou lcars-in-flight → retiré (sinon le
      # poller skipperait l'issue à jamais).
      assert_received {:spawned, "issue-42", _}
      assert_received {:killed, "lordzurp-lcars-test-issue-42-engineer"}
      assert_received {:removed_label, "lcars-in-flight"}
    end

    test "skip in_flight : pas de spawn" do
      payload = eng_issue(%{"labels" => [%{"name" => "lcars-in-flight"}]})

      assert {:skipped, :in_flight} = StageDispatcher.dispatch_issue(payload, dispatch_opts())
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

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-engineer", "engineer"}} =
               StageDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:project] == project
      assert spawn_opts[:mandate] =~ "fais le hello"
    end

    test "route gravée → rôle dérivé de la carte (stage build=engineer) + pipeline/stage injectés (A2.1, #8)" do
      payload = eng_issue()

      # #8 : le rôle vient DÉSORMAIS de la carte (CarteNav.stage_role), pas de producer_role en dur.
      # Ici le stage courant "build" porte role=engineer → rôle engineer (et route injectée, A2.1).
      carte = %{
        "name" => "poc-cycle",
        "stages" => %{"build" => %{"role" => "engineer", "needs" => []}}
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"poc-cycle", "build"}}],
          carte_loader: fn "poc-cycle" -> carte end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StageDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:pipeline] == "poc-cycle"
      assert spawn_opts[:stage] == "build"
    end

    test "#8 : route sur un stage AMONT (mandate-review/consultant) → spawn le CONSULTANT, pas l'eng" do
      payload = eng_issue()

      # La carte EST la machine à états : le 1er stage (racine `needs:[]`) est mandate-review/consultant.
      # decide() rendait "engineer" (DN §1) ; carte_role override avec le rôle du stage courant → consultant.
      carte = %{
        "name" => "mandate-gate",
        "stages" => %{
          "mandate-review" => %{"role" => "consultant", "needs" => []},
          "build" => %{"role" => "engineer", "needs" => ["mandate-review"]}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"mandate-gate", "mandate-review"}}],
          carte_loader: fn "mandate-gate" -> carte end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-consultant", "consultant"}} =
               StageDispatcher.dispatch_issue(payload, opts)
    end

    test "#8.B : mandate_kind:judge AU STAGE override un profil worker (engineer) → mandat JUGE" do
      payload = eng_issue()

      # Le stage déclare mandate_kind:judge ; le rôle engineer a un profil WORKER. L'override per-stage
      # doit produire un mandat JUGE (désamorcé), PAS le mandat worker (issue body + "Livraison git-native").
      carte = %{
        "name" => "g",
        "stages" => %{
          "review" => %{"role" => "engineer", "needs" => [], "mandate_kind" => "judge"}
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "review"}}],
          carte_loader: fn "g" -> carte end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StageDispatcher.dispatch_issue(payload, opts)
      assert_received {:spawned, "issue-42", spawn_opts}
      refute spawn_opts[:mandate] =~ "Livraison (git-native)"
    end

    test "#8.B : sans mandate_kind au stage → défaut du profil (engineer=worker → mandat worker)" do
      payload = eng_issue()
      carte = %{"name" => "g", "stages" => %{"build" => %{"role" => "engineer", "needs" => []}}}

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"g", "build"}}],
          carte_loader: fn "g" -> carte end
        )

      assert {:ok, {:spawned, _, "engineer"}} = StageDispatcher.dispatch_issue(payload, opts)
      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:mandate] =~ "Livraison (git-native)"
    end

    test "#8.E : judge_target:mandate → brief en cadrage MANDAT (juge le ticket.body, pas un livrable)" do
      # F-S2-1 : le mandat = body de l'ISSUE en main (payload), PAS un get_issue redondant.
      payload = eng_issue(%{"body" => "MON MANDAT A JUGER"})

      carte = %{
        "name" => "mg",
        "stages" => %{
          "mandate-review" => %{
            "role" => "consultant",
            "needs" => [],
            "mandate_kind" => "judge",
            "judge_target" => "mandate"
          }
        }
      }

      opts =
        dispatch_opts(
          forge_opts: [_test_route: {:ok, {"mg", "mandate-review"}}],
          carte_loader: fn "mg" -> carte end
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-consultant", "consultant"}} =
               StageDispatcher.dispatch_issue(payload, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      mandate = spawn_opts[:mandate]
      # cadrage MANDAT (subject:mandate) + le mandat à juger, PAS le cadrage livrable.
      assert mandate =~ "Mandat à juger"
      assert mandate =~ "MON MANDAT A JUGER"
      refute mandate =~ "Livrable à juger (outputs du stage"
      refute mandate =~ "Livraison (git-native)"
    end

    test "#5.2 D2 — issue ROUTELESS → onboardée sur la carte par défaut (skip), PAS de spawn eng" do
      payload = eng_issue()

      # route :none (override de la route par défaut) + carte par défaut mandate-gate (1er stage mandate-review).
      opts =
        dispatch_opts(
          forge_opts: [_test_route: :none],
          carte_loader: fn "mandate-gate" ->
            %{"stages" => %{"mandate-review" => %{"role" => "consultant", "needs" => []}}}
          end
        )

      assert {:skipped, :onboarded} = StageDispatcher.dispatch_issue(payload, opts)

      # la carte par défaut a été GRAVÉE (le tick suivant dispatchera le consultant) ; AUCUN spawn eng.
      assert_received {:routed, 42, "mandate-gate", "mandate-review"}
      refute_received {:spawned, _, _}
    end

    test "échec lecture route → {:error, {:route_resolution, _}}, AUCUN verrou ni spawn" do
      payload = eng_issue()
      opts = dispatch_opts(forge_opts: [_test_route: {:error, :http_500}])

      assert {:error, {:route_resolution, :http_500}} =
               StageDispatcher.dispatch_issue(payload, opts)

      refute_received {:spawned, _, _}
    end

    test "échec résolution projet → {:error}, AUCUN verrou posé ni spawn" do
      payload = eng_issue()

      opts =
        dispatch_opts(project_resolver: fn _repo, _opts -> {:error, :ls_remote_timeout} end)

      assert {:error, {:project_resolution, :ls_remote_timeout}} =
               StageDispatcher.dispatch_issue(payload, opts)

      # résolution AVANT toute écriture forge : pas de spawn, pas de verrou orphelin
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

    test "PR avec review demandee -> spawn le juge (ticket=ISSUE, verrou sur la PR)" do
      opts =
        dispatch_opts(
          forge_opts: [
            _test_route: {:ok, {"poc", "spec-review"}},
            _test_issue_body: "implémente le décodeur morse"
          ]
        )

      assert {:ok, {:spawned, "lordzurp-lcars-test-pr-6-qualifier", "qualifier"}} =
               StageDispatcher.dispatch_review(pr(), opts)

      # ticket_id = l'ISSUE (remontee de head.ref lcars/issue-42-engineer), PAS la PR
      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:pipeline] == "poc" and spawn_opts[:stage] == "spec-review"
      # mandat juge desamorce (mandate_kind: judge) — pas un corps executable
      assert spawn_opts[:mandate] =~ "JUGER"

      # Fix famine-d'info (juge) : predecessor vide (git-native) → le juge est POINTÉ sur son
      # workspace ET reçoit le CRITÈRE (body de l'issue, désamorcé en contexte).
      # La base du diff est `origin/main` (clone mono-branche : le ref local `main` n'existe pas —
      # bug live morse : `git diff main..HEAD` → fatal unknown revision → halt_wait_input intermittent).
      assert spawn_opts[:mandate] =~ "git diff origin/main...HEAD"
      assert spawn_opts[:mandate] =~ "implémente le décodeur morse"

      # enqueue cible le pod_id pr-... ; ticket_id = l'issue
      assert_received {:enqueued, "lordzurp-lcars-test-pr-6-qualifier", attrs}
      assert attrs.ticket_id == "issue-42"
      assert attrs.role == "qualifier"
      assert_received {:woke, "lordzurp-lcars-test-pr-6-qualifier"}
    end

    test "PR verrouillee (lcars-in-flight) -> skip, pas de spawn" do
      pr = pr(%{"labels" => [%{"name" => "lcars-in-flight"}]})
      assert {:skipped, :in_flight} = StageDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "PR sans reviewer + aucune review decisive -> skip :no_verdict (②.1d, PR en attente)" do
      pr = pr(%{"requested_reviewers" => []})
      # _test_review_state defaut :none
      assert {:skipped, :no_verdict} = StageDispatcher.dispatch_review(pr, dispatch_opts())
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

      assert {:ok, {:merged, 6}} = StageDispatcher.dispatch_review(pr, opts)
      # le merge FF a bien ete declenche sur la PR (auto-close de l'issue via Closes #N)
      assert_received {:merged, 6}
      refute_received {:spawned, _, _}

      # BL-055 die-on-promote : le producteur (id déterministe issue-42-engineer) est tué au
      # merge. En one-shot il est déjà mort (kill = no-op de sûreté) ; en pipe c'est le vrai
      # release terminal. Inconditionnel côté dispatcher → couvre les deux profils.
      assert_received {:killed, "lordzurp-lcars-test-issue-42-engineer"}
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
      assert {:ok, {:spawned, "lordzurp-lcars-test-issue-42-engineer", "engineer"}} =
               StageDispatcher.dispatch_review(pr, opts)

      assert_received {:spawned, "issue-42", spawn_opts}
      assert spawn_opts[:mandate] =~ "REWORK"

      # Fix famine-d'info (rework) : le BODY de la review REQUEST_CHANGES est injecté (sinon « corrige
      # selon la review » est creux → l'eng devine à l'aveugle → blocked_dep/wedge, prouvé live morse).
      assert spawn_opts[:mandate] =~ "le timing des points/traits est faux"
      assert spawn_opts[:mandate] =~ "reviewer"

      # Voix de l'eng (rework) : le mandat demande un `summary` = réponse au reviewer, posté sur la PR.
      assert spawn_opts[:mandate] =~ "summary"
      assert_received {:enqueued, "lordzurp-lcars-test-issue-42-engineer", attrs}
      assert attrs.role == "engineer"
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
               StageDispatcher.dispatch_review(pr, opts)

      refute_received {:merged, _}
    end

    test "PR sur branche non-fleet -> skip (jamais misroutee)" do
      pr = pr(%{"head" => %{"ref" => "refs/pull/6/head"}})
      assert {:skipped, :not_fleet_branch} = StageDispatcher.dispatch_review(pr, dispatch_opts())
      refute_received {:spawned, _, _}
    end

    test "reviewer = role inconnu -> skip :no_role" do
      pr = pr(%{"requested_reviewers" => [%{"login" => "lordzurp"}]})
      assert {:skipped, :no_role} = StageDispatcher.dispatch_review(pr, dispatch_opts())
    end

    test "F181 : echec POST-verrou (enqueue KO) -> verrou PR retire + pod tue" do
      opts = dispatch_opts(task_queue: FailTaskQueue, forge_opts: [_test_route: :none])

      assert {:error, {:enqueue_failed, :broker_down}} =
               StageDispatcher.dispatch_review(pr(), opts)

      assert_received {:killed, "lordzurp-lcars-test-pr-6-qualifier"}
      assert_received {:removed_label, "lcars-in-flight"}
    end
  end
end
