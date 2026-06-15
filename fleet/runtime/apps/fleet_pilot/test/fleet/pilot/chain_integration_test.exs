defmodule Fleet.Pilot.ChainIntegrationTest do
  @moduledoc """
  Integration A2 / Corr.3 : la chaine multi-stage de bout en bout, modules REELS (Entry,
  StageDispatcher, HopConsumer, HopCompleter, CarteNav) contre un sim forge stateful PR-aware, en
  synchrone (pas de Bus ni pods reels — on simule pod.completed depuis les opts de spawn capturees).
  Prouve le CABLAGE de la boucle PR-natif engineer-first : entree -> spawn -> producteur ouvre la PR
  -> route+assignee du juge -> spawn juge -> merge terminal -> issue close (Closes #N).
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.{Entry, StageDispatcher, HopConsumer, ForgeClient}

  # ── Sim forge stateful (1 issue + PRs) ────────────────────────────────────
  defmodule Sim do
    use Agent

    def start_link(issue), do: Agent.start_link(fn -> %{issue: issue, prs: [], seq: 0} end)
    def get(pid), do: Agent.get(pid, & &1.issue)
    defp upd(pid, f), do: Agent.update(pid, fn s -> %{s | issue: f.(s.issue)} end)

    def add_label(pid, _r, _n, l, _o) do
      upd(pid, fn i ->
        ls = i["labels"] || []

        if Enum.any?(ls, &(&1["name"] == l)),
          do: i,
          else: Map.put(i, "labels", ls ++ [%{"name" => l}])
      end)

      {:ok, :added}
    end

    def remove_label(pid, _r, _n, l, _o) do
      upd(pid, fn i ->
        Map.put(i, "labels", Enum.reject(i["labels"] || [], &(&1["name"] == l)))
      end)

      {:ok, :removed}
    end

    def set_state_label(pid, _r, _n, st, _o) do
      upd(pid, fn i ->
        kept = Enum.reject(i["labels"] || [], &String.starts_with?(&1["name"], "state:"))
        Map.put(i, "labels", kept ++ [%{"name" => st}])
      end)

      {:ok, :set}
    end

    def set_assignee(pid, _r, _n, login, _o) do
      upd(pid, fn i -> Map.put(i, "assignees", [%{"login" => login}]) end)
      {:ok, :set}
    end

    def post_comment(pid, _r, _n, body, _o) do
      upd(pid, fn i -> Map.put(i, "comments", (i["comments"] || []) ++ [body]) end)
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
      upd(pid, fn i -> Map.put(i, "state", "closed") end)
      {:ok, :closed}
    end

    # ── PR (Corr.3) ──
    def open_pr(pid, _r, head, base, _title, _o) do
      Agent.get_and_update(pid, fn s ->
        case Enum.find(s.prs, &(&1.head == head and &1.base == base and &1.state == :open)) do
          %{number: num} ->
            {{:ok, num}, s}

          nil ->
            num = s.seq + 1
            pr = %{number: num, head: head, base: base, state: :open}
            {{:ok, num}, %{s | seq: num, prs: s.prs ++ [pr]}}
        end
      end)
    end

    def get_pr_for_branch(pid, _r, head, base, _o) do
      case Enum.find(
             Agent.get(pid, & &1.prs),
             &(&1.head == head and &1.base == base and &1.state == :open)
           ) do
        %{number: num} -> {:ok, num}
        nil -> {:error, :pr_not_found}
      end
    end

    def request_review(_pid, _r, _pr, _revs, _o), do: :ok
    def post_review(_pid, _r, _pr, _ev, _body, _o), do: :ok

    # merge FF : marque la PR merged + ferme l'issue (Closes #N).
    def merge_pr(pid, _r, pr, _o) do
      Agent.update(pid, fn s ->
        prs = Enum.map(s.prs, fn p -> if p.number == pr, do: %{p | state: :merged}, else: p end)
        %{s | prs: prs, issue: Map.put(s.issue, "state", "closed")}
      end)

      :ok
    end
  end

  # Wrapper (les modules de la chaine appellent ForgeClient.f/arity ; le pid sim vit en pdict).
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
    def open_pr(r, head, base, t, o), do: Sim.open_pr(p(), r, head, base, t, o)
    def get_pr_for_branch(r, head, base, o), do: Sim.get_pr_for_branch(p(), r, head, base, o)
    def request_review(r, pr, revs, o), do: Sim.request_review(p(), r, pr, revs, o)
    def post_review(r, pr, ev, body, o), do: Sim.post_review(p(), r, pr, ev, body, o)
    def merge_pr(r, pr, o), do: Sim.merge_pr(p(), r, pr, o)
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

    # B (L441) : escalade gatekeeper sur le stage juge `review` (gate soft). Le producteur
    # (engineer) ouvre la PR en tete ; le verdict revient async (resume_gate).
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
    def load(role) when role in ["architect", "engineer", "reviewer", "gatekeeper"],
      do:
        {:ok,
         %Fleet.CapProfile{kind: "CapabilityProfile", metadata: %{"name" => role}, spec: %{}}}

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

  @routing %{"type:poc" => "poc-mini"}

  defp wrap(pid), do: %{"issue" => Sim.get(pid)}

  # Reconstruit le payload pod.completed (ce que pod.ex produit) : pipeline+stage des opts de spawn.
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
        "labels" => [%{"name" => "type:poc"}],
        "assignees" => [],
        "comments" => []
      })

    SimForge.put(pid)
    pid
  end

  test "chaine engineer-first : entree -> build(engineer) ouvre PR -> review(reviewer) -> merge close" do
    pid = new_issue()
    entry_opts = [repo: "o/r", routing: @routing, forge_client: SimForge, loader: CarteLoader]

    # 1. ENTREE : type:poc -> route build + assignee engineer (1er stage = producteur)
    assert {:ok, {:entered, "engineer"}} = Entry.enter(wrap(pid), entry_opts)
    assert {:ok, {"poc-mini", "build"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "engineer"}] = Sim.get(pid)["assignees"]

    # 2. DISPATCH build -> spawn engineer (opts portent pipeline+stage)
    assert {:ok, {:spawned, _, "engineer"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts())

    assert_received {:spawned, "issue-1", o1}
    assert o1[:pipeline] == "poc-mini" and o1[:stage] == "build"

    # 3. pod.completed(build) -> producteur :advance : ouvre la PR, route+assignee reviewer, unlock
    assert {:ok, :review_requested} = HopConsumer.maybe_complete(completed(o1, "engineer"), hc())
    assert {:ok, {"poc-mini", "review"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "reviewer"}] = Sim.get(pid)["assignees"]
    assert {:ok, _pr} = SimForge.get_pr_for_branch("o/r", "lcars/issue-1-engineer", "main", [])
    assert Sim.get(pid)["state"] == "open"
    refute Enum.any?(Sim.get(pid)["labels"], &(&1["name"] == "lcars-in-flight"))

    # 4. DISPATCH review -> spawn reviewer
    assert {:ok, {:spawned, _, "reviewer"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts())

    assert_received {:spawned, "issue-1", o2}
    assert o2[:stage] == "review"

    # 5. pod.completed(review) -> juge :promote : review approve + merge -> issue close (Closes #N)
    assert {:ok, :promoted} = HopConsumer.maybe_complete(completed(o2, "reviewer"), hc())
    assert Sim.get(pid)["state"] == "closed"
  end

  # ── B (L441) : escalade gatekeeper (gate soft sur le stage juge review) ───────
  # entree -> build(engineer) ouvre PR -> review(reviewer) finit soft -> ESCALADE.
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

    # build (pas de gate) finit -> avance review(reviewer), PR ouverte par le producteur.
    assert {:ok, :review_requested} = HopConsumer.maybe_complete(completed(o1, "engineer"), hc())
    assert {:ok, {"gkchain", "review"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "reviewer"}] = Sim.get(pid)["assignees"]

    # dispatch review -> spawn reviewer
    assert {:ok, {:spawned, _, "reviewer"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts())

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
    assert [%{"login" => "reviewer"}] = Sim.get(pid)["assignees"]
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

  test "B escalade escalate_user : lcars-awaits-human + unlock + poller SKIP (boucle fermee)" do
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

    # le poller NE re-dispatche PAS (assignee=reviewer mais awaits-human).
    assert {:skipped, :awaits_human} = StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts())
  end
end
