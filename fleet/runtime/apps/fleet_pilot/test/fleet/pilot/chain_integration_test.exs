defmodule Fleet.Pilot.ChainIntegrationTest do
  @moduledoc """
  Integration Corr.3 4-C (switch review-request) : la chaine multi-stage de bout en bout, modules
  REELS (Entry, StageDispatcher, HopConsumer, HopCompleter, CarteNav) contre un sim forge stateful
  PR-aware, en synchrone. Prouve le CABLAGE PR-driven engineer-first :
    entree -> spawn engineer (issue-assignee) -> engineer ouvre la PR + request_review ->
    spawn juge via dispatch_review (PR) -> merge terminal -> issue close (Closes #N).

  Le producteur (engineer) reste issue-assignee-driven ; les JUGES sont dispatches via les
  requested_reviewers de la PR. Le verrou lcars-in-flight du juge est pose sur la PR (pas l'issue).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.{Entry, StageDispatcher, HopConsumer, ForgeClient}

  # ── Sim forge stateful : 1 issue + N PR (objets separes, labels/requested_reviewers propres) ──
  defmodule Sim do
    use Agent

    def start_link(issue), do: Agent.start_link(fn -> %{issue: issue, prs: %{}, seq: 99} end)
    def get(pid), do: Agent.get(pid, & &1.issue)
    def get_pr(pid, n), do: Agent.get(pid, &Map.get(&1.prs, n))
    defp upd_issue(pid, f), do: Agent.update(pid, fn s -> %{s | issue: f.(s.issue)} end)

    defp upd_pr(pid, n, f),
      do: Agent.update(pid, fn s -> %{s | prs: Map.update!(s.prs, n, f)} end)

    defp pr?(pid, n), do: Agent.get(pid, fn s -> Map.has_key?(s.prs, n) end)

    # Labels : routes vers la PR si `n` est un numero de PR connu, sinon l'issue (espace partage Gitea).
    def add_label(pid, _r, n, l, _o) do
      if pr?(pid, n), do: upd_pr(pid, n, &add_lbl(&1, l)), else: upd_issue(pid, &add_lbl(&1, l))
      {:ok, :added}
    end

    def remove_label(pid, _r, n, l, _o) do
      if pr?(pid, n), do: upd_pr(pid, n, &rm_lbl(&1, l)), else: upd_issue(pid, &rm_lbl(&1, l))
      {:ok, :removed}
    end

    defp add_lbl(m, l) do
      ls = m["labels"] || []

      if Enum.any?(ls, &(&1["name"] == l)),
        do: m,
        else: Map.put(m, "labels", ls ++ [%{"name" => l}])
    end

    defp rm_lbl(m, l),
      do: Map.put(m, "labels", Enum.reject(m["labels"] || [], &(&1["name"] == l)))

    # state/assignee/comments/route : sur l'ISSUE (le pipeline-state y reste).
    def set_state_label(pid, _r, _n, st, _o) do
      upd_issue(pid, fn i ->
        kept = Enum.reject(i["labels"] || [], &String.starts_with?(&1["name"], "state:"))
        Map.put(i, "labels", kept ++ [%{"name" => st}])
      end)

      {:ok, :set}
    end

    def set_assignee(pid, _r, _n, login, _o) do
      upd_issue(pid, &Map.put(&1, "assignees", [%{"login" => login}]))
      {:ok, :set}
    end

    # comment sur l'issue (route) ; sur une PR (lock comment du juge) -> ignore (osef pour le test).
    def post_comment(pid, _r, n, body, _o) do
      unless pr?(pid, n) do
        upd_issue(pid, fn i -> Map.put(i, "comments", (i["comments"] || []) ++ [body]) end)
      end

      {:ok, :posted}
    end

    def post_route(pid, r, n, p, s, _o),
      do: post_comment(pid, r, n, "[lcars-route:#{p}:#{s}]", [])

    def get_route(pid, _r, _n, _o) do
      (get(pid)["comments"] || [])
      |> Enum.reverse()
      |> Enum.find_value(:none, &ForgeClient.parse_route_marker/1)
    end

    def close_issue(pid, _r, _n, _o) do
      upd_issue(pid, &Map.put(&1, "state", "closed"))
      {:ok, :closed}
    end

    def get_predecessor_result(_pid, _r, _n, _o), do: :none

    # ── PR ──
    def open_pr(pid, _r, head, base, _title, _o) do
      Agent.get_and_update(pid, fn s ->
        case Enum.find(s.prs, fn {_, pr} -> open_match?(pr, head, base) end) do
          {num, _} ->
            {{:ok, num}, s}

          nil ->
            num = s.seq + 1

            pr = %{
              "number" => num,
              "head" => %{"ref" => head},
              "base" => %{"ref" => base},
              "state" => "open",
              "requested_reviewers" => [],
              "labels" => []
            }

            {{:ok, num}, %{s | seq: num, prs: Map.put(s.prs, num, pr)}}
        end
      end)
    end

    defp open_match?(pr, head, base),
      do: pr["head"]["ref"] == head and pr["base"]["ref"] == base and pr["state"] == "open"

    def get_pr_for_branch(pid, _r, head, base, _o) do
      case Enum.find(Agent.get(pid, & &1.prs), fn {_, pr} -> open_match?(pr, head, base) end) do
        {num, _} -> {:ok, num}
        nil -> {:error, :pr_not_found}
      end
    end

    def list_open_pulls(pid, _r, _o) do
      {:ok, Agent.get(pid, & &1.prs) |> Map.values() |> Enum.filter(&(&1["state"] == "open"))}
    end

    def request_review(pid, _r, pr, reviewers, _o) do
      upd_pr(pid, pr, fn p ->
        Map.put(p, "requested_reviewers", Enum.map(reviewers, &%{"login" => &1}))
      end)

      :ok
    end

    # review soumise -> Gitea retire le reviewer de requested (ici on vide : 1 reviewer a la fois) ET
    # enregistre le verdict courant (②.1d : dispatch_review lit pr_review_state pour merge/rework).
    def post_review(pid, _r, pr, ev, _body, _o) do
      upd_pr(pid, pr, fn p ->
        p
        |> Map.put("requested_reviewers", [])
        |> Map.put("review_state", review_state_of(ev))
      end)

      :ok
    end

    defp review_state_of(:approve), do: :approved
    defp review_state_of(:request_changes), do: :changes_requested
    defp review_state_of(_), do: :none

    # ②.1d : etat de review courant d'une PR (defaut :none tant qu'aucune review decisive).
    def pr_review_state(pid, _r, pr, _o) do
      case get_pr(pid, pr) do
        %{"review_state" => st} -> {:ok, st}
        _ -> {:ok, :none}
      end
    end

    # merge FF : PR merged + issue close (Closes #N).
    def merge_pr(pid, _r, pr, _o) do
      Agent.update(pid, fn s ->
        %{
          s
          | prs: Map.update!(s.prs, pr, &Map.put(&1, "state", "merged")),
            issue: Map.put(s.issue, "state", "closed")
        }
      end)

      :ok
    end
  end

  # Wrapper (les modules appellent ForgeClient.f/arity ; le pid sim vit en pdict).
  defmodule SimForge do
    def put(pid), do: Process.put(:sim, pid)
    defp p, do: Process.get(:sim)
    def add_label(r, n, l, o), do: Sim.add_label(p(), r, n, l, o)
    def remove_label(r, n, l, o), do: Sim.remove_label(p(), r, n, l, o)
    def set_state_label(r, n, s, o), do: Sim.set_state_label(p(), r, n, s, o)
    def set_assignee(r, n, l, o), do: Sim.set_assignee(p(), r, n, l, o)
    def post_comment(r, n, b, o), do: Sim.post_comment(p(), r, n, b, o)
    def post_route(r, n, pi, st, o), do: Sim.post_route(p(), r, n, pi, st, o)
    def get_route(r, n, o), do: Sim.get_route(p(), r, n, o)
    def close_issue(r, n, o), do: Sim.close_issue(p(), r, n, o)
    def get_predecessor_result(r, n, o), do: Sim.get_predecessor_result(p(), r, n, o)
    def open_pr(r, head, base, t, o), do: Sim.open_pr(p(), r, head, base, t, o)
    def get_pr_for_branch(r, head, base, o), do: Sim.get_pr_for_branch(p(), r, head, base, o)
    def list_open_pulls(r, o), do: Sim.list_open_pulls(p(), r, o)
    def request_review(r, pr, revs, o), do: Sim.request_review(p(), r, pr, revs, o)
    def post_review(r, pr, ev, body, o), do: Sim.post_review(p(), r, pr, ev, body, o)
    def merge_pr(r, pr, o), do: Sim.merge_pr(p(), r, pr, o)
    def pr_review_state(r, pr, o), do: Sim.pr_review_state(p(), r, pr, o)
  end

  defmodule CarteLoader do
    # engineer-first 2 stages : build(engineer, producteur) -> review(reviewer, juge).
    def load!("poc-mini") do
      %{
        "name" => "poc-mini",
        "stages" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "review" => %{"role" => "reviewer", "needs" => ["build"]}
        }
      }
    end

    # B (L441) : escalade gatekeeper sur le stage juge `review` (gate soft).
    def load!("gkchain") do
      %{
        "name" => "gkchain",
        "stages" => %{
          "build" => %{"role" => "engineer", "needs" => []},
          "review" => %{
            "role" => "reviewer",
            "needs" => ["build"],
            "gate" => %{"type" => "soft", "max_rounds" => 1}
          }
        }
      }
    end
  end

  defmodule CapLoader do
    # engineer = worker (mandat = body) ; reviewer/qualifier = juge (mandate_kind judge).
    def load("engineer"),
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => "engineer"},
           spec: %{}
         }}

    def load(role) when role in ["reviewer", "qualifier", "gatekeeper", "architect"],
      do:
        {:ok,
         %Fleet.CapProfile{
           kind: "CapabilityProfile",
           metadata: %{"name" => role},
           spec: %{"mandate_kind" => "judge"}
         }}

    def load(_), do: {:error, :not_found}
  end

  defmodule SpawnStub do
    def spawn_pod(_profile, ticket_id, opts) do
      send(self(), {:spawned, ticket_id, opts})
      {:ok, self()}
    end

    def wake_pod(_), do: :ok
  end

  defmodule TQStub do
    def enqueue(_pod, _attrs), do: {:ok, %{id: "t"}}
  end

  defmodule DelivStub do
    def publish(_opts) do
      {:ok,
       %{
         commit_sha: "sha-#{System.unique_integer([:positive])}",
         pushed?: true,
         mode: :git_native
       }}
    end
  end

  defp dmode,
    do: fn
      "engineer" -> "git_native"
      _ -> "payload"
    end

  defp wrap(pid), do: %{"issue" => Sim.get(pid)}

  defp completed(spawn_opts, role, result \\ nil) do
    base = %{
      "ticket_id" => "issue-1",
      "workspace" => "/ws",
      "base_sha" => "cafe",
      "role" => role,
      "pipeline" => spawn_opts[:pipeline],
      "stage" => spawn_opts[:stage]
    }

    if result, do: Map.put(base, "result", result), else: base
  end

  defp dispatch_opts do
    [
      repo: "o/r",
      forge_client: SimForge,
      loader: CapLoader,
      spawner: SpawnStub,
      task_queue: TQStub,
      clock: fn :second -> 100 end,
      project_resolver: fn _r, _o ->
        {:ok, %{"repo_path" => "x", "base_branch" => "main", "base_sha" => "cafe"}}
      end
    ]
  end

  defp hc do
    %HopConsumer{
      repo: "o/r",
      remote: "origin",
      forge_opts: [],
      role_emails: fn r -> ["#{r}@lcars.local"] end,
      hop_completer: Fleet.Pilot.HopCompleter,
      forge_client: SimForge,
      loader: CarteLoader,
      deliverable: DelivStub,
      deliverable_mode_fun: dmode(),
      max_rework_rounds: 2,
      task_queue: TQStub,
      spawner: SpawnStub,
      gatekeeper_pod_id_fun: fn -> "gk-perm" end,
      gate_evals: %{}
    }
  end

  defp new_issue do
    {:ok, pid} =
      Sim.start_link(%{
        "number" => 1,
        "state" => "open",
        # `type:poc` = trigger d'entrée carte (legacy Entry, FALL ②.3). En no-label, `decide` spawn
        # le producteur (engineer) pour toute issue assignée — pas besoin de stage-marker.
        "labels" => [%{"name" => "type:poc"}],
        "assignees" => [],
        "comments" => []
      })

    SimForge.put(pid)
    pid
  end

  defp single_open_pr do
    {:ok, [pr]} = SimForge.list_open_pulls("o/r", [])
    {pr, pr["number"]}
  end

  test "chaine engineer-first PR-driven : build(engineer) ouvre PR -> review(reviewer) -> merge close" do
    pid = new_issue()

    entry_opts = [
      repo: "o/r",
      routing: %{"type:poc" => "poc-mini"},
      forge_client: SimForge,
      loader: CarteLoader
    ]

    # 1. ENTREE : type:poc -> route build + assignee engineer (producteur)
    assert {:ok, {:entered, "engineer"}} = Entry.enter(wrap(pid), entry_opts)
    assert {:ok, {"poc-mini", "build"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "engineer"}] = Sim.get(pid)["assignees"]

    # 2. DISPATCH build -> spawn engineer (issue-assignee-driven)
    assert {:ok, {:spawned, _, "engineer"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts())

    assert_received {:spawned, "issue-1", o1}

    # 3. engineer finit -> :advance : ouvre la PR + request_review(reviewer) + route review.
    #    L'assignee de l'issue reste ENGINEER (plus de set_assignee), la suite est PR-driven.
    assert {:ok, :review_requested} = HopConsumer.maybe_complete(completed(o1, "engineer"), hc())
    assert {:ok, _pr_n} = SimForge.get_pr_for_branch("o/r", "lcars/issue-1-engineer", "main", [])
    assert {:ok, {"poc-mini", "review"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "engineer"}] = Sim.get(pid)["assignees"]
    {pr_payload, pr_n} = single_open_pr()
    assert [%{"login" => "reviewer"}] = pr_payload["requested_reviewers"]

    # 4. DISPATCH review via la PR (chemin PR-driven) -> spawn reviewer ; verrou sur la PR
    assert {:ok, {:spawned, _, "reviewer"}} =
             StageDispatcher.dispatch_review(pr_payload, dispatch_opts())

    assert_received {:spawned, "issue-1", o2}
    assert o2[:stage] == "review"
    assert Enum.any?(Sim.get_pr(pid, pr_n)["labels"], &(&1["name"] == "lcars-in-flight"))

    # 5. reviewer finit -> :promote : review APPROVED + merge -> issue close (Closes #N)
    assert {:ok, :promoted} = HopConsumer.maybe_complete(completed(o2, "reviewer"), hc())
    assert Sim.get(pid)["state"] == "closed"
    # verrou de la PR leve
    refute Enum.any?(Sim.get_pr(pid, pr_n)["labels"], &(&1["name"] == "lcars-in-flight"))
  end

  # ── B (L441) : escalade gatekeeper (gate soft sur le stage juge review) ───────
  defp drive_to_review do
    pid = new_issue()

    entry_opts = [
      repo: "o/r",
      routing: %{"type:poc" => "gkchain"},
      forge_client: SimForge,
      loader: CarteLoader
    ]

    assert {:ok, {:entered, "engineer"}} = Entry.enter(wrap(pid), entry_opts)

    assert {:ok, {:spawned, _, "engineer"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts())

    assert_received {:spawned, "issue-1", o1}

    # build (pas de gate) finit -> avance review(reviewer) : ouvre la PR + request_review.
    assert {:ok, :review_requested} = HopConsumer.maybe_complete(completed(o1, "engineer"), hc())
    assert {:ok, {"gkchain", "review"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "engineer"}] = Sim.get(pid)["assignees"]
    {pr_payload, _pr_n} = single_open_pr()

    # dispatch review via la PR -> spawn reviewer
    assert {:ok, {:spawned, _, "reviewer"}} =
             StageDispatcher.dispatch_review(pr_payload, dispatch_opts())

    assert_received {:spawned, "issue-1", o2}
    assert o2[:stage] == "review"

    # review finit AVEC gate soft -> escalade gatekeeper (mandat enqueue, PAS d'avance).
    assert {:escalate, "t", eval_ctx} =
             HopConsumer.maybe_complete(
               completed(o2, "reviewer", %{"severity_max" => "ok"}),
               hc()
             )

    assert eval_ctx.stage == "review"
    assert eval_ctx.role == "reviewer"
    assert Sim.get(pid)["state"] == "open"

    {pid, eval_ctx}
  end

  test "B escalade continue : review(soft->escalade) -> verdict continue -> merge terminal close" do
    {pid, eval_ctx} = drive_to_review()

    # verdict continue : review est le dernier stage -> :promote -> juge merge la PR du producteur.
    assert {:ok, :promoted} =
             HopConsumer.resume_gate(eval_ctx, %{"result" => %{"decision" => "continue"}}, hc())

    assert Sim.get(pid)["state"] == "closed"
  end

  test "B escalade escalate_user : lcars-awaits-human + unlock + reste ouvert (boucle fermee)" do
    {pid, eval_ctx} = drive_to_review()

    assert {:ok, :awaiting_human} =
             HopConsumer.resume_gate(
               eval_ctx,
               %{"result" => %{"decision" => "escalate_user"}},
               hc()
             )

    labels = Enum.map(Sim.get(pid)["labels"], & &1["name"])
    assert "lcars-awaits-human" in labels
    refute "lcars-in-flight" in labels
    assert Sim.get(pid)["state"] == "open"
  end
end
