defmodule Fleet.Pilot.ChainIntegrationTest do
  @moduledoc """
  Intégration A2 : la chaîne multi-stage de bout en bout, modules RÉELS (Entry, StageDispatcher,
  HopConsumer, HopCompleter, CarteNav) contre un **sim forge stateful**, en synchrone (pas de Bus ni
  pods réels — on simule `pod.completed` en construisant le payload depuis les opts de spawn
  capturées, ce que `pod.ex` ferait). Prouve le CÂBLAGE de la boucle : entrée → spawn → fin-de-hop
  (route gravée) → reassign → spawn suivant → terminal close. Les unités sont testées ailleurs ;
  ici on teste qu'elles s'enchaînent.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.{Entry, StageDispatcher, HopConsumer, ForgeClient}

  # ── Sim forge stateful (1 issue, clé fixe 1) ──────────────────────────────
  defmodule Sim do
    use Agent

    def start_link(issue), do: Agent.start_link(fn -> issue end)
    def get(pid), do: Agent.get(pid, & &1)
    defp upd(pid, f), do: Agent.update(pid, f)

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

    def get_predecessor_result(pid, _r, _n, _o) do
      (get(pid)["comments"] || [])
      |> Enum.reverse()
      |> Enum.find_value(:none, &ForgeClient.parse_result_block/1)
    end

    def close_issue(pid, _r, _n, _o) do
      upd(pid, fn i -> Map.put(i, "state", "closed") end)
      {:ok, :closed}
    end
  end

  # Wrapper module (les modules de la chaîne appellent ForgeClient.f/arity ; le pid sim vit en pdict).
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
    def get_predecessor_result(r, n, o), do: Sim.get_predecessor_result(p(), r, n, o)
    def close_issue(r, n, o), do: Sim.close_issue(p(), r, n, o)
  end

  defmodule CarteLoader do
    # 2 stages linéaires : triage(architect) → build(engineer)
    def load!("poc-mini") do
      %{
        "name" => "poc-mini",
        "stages" => %{
          "triage" => %{"role" => "architect", "needs" => []},
          "build" => %{"role" => "engineer", "needs" => ["triage"]}
        }
      }
    end

    # A2.3b : chaîne avec gatekeeper-stage explicite : triage(architect) →
    # review(gatekeeper, gate soft = verdict) → build(engineer).
    def load!("gkchain") do
      %{
        "name" => "gkchain",
        "stages" => %{
          "triage" => %{"role" => "architect", "needs" => []},
          "review" => %{
            "role" => "gatekeeper",
            "needs" => ["triage"],
            "gate" => %{"type" => "soft", "max_rounds" => 1}
          },
          "build" => %{"role" => "engineer", "needs" => ["review"]}
        }
      }
    end
  end

  defmodule CapLoader do
    def load(role) when role in ["architect", "engineer", "gatekeeper"],
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

  @routing %{"type:poc" => "poc-mini"}

  defp wrap(pid), do: %{"issue" => Sim.get(pid)}

  # Reconstruit le payload pod.completed (ce que pod.ex produit) : pipeline+stage des opts de spawn,
  # role explicite (le test sait quel stage vient de finir).
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

  test "chaîne 2 stages : entrée → triage(architect) → build(engineer) → terminal close" do
    {:ok, pid} =
      Sim.start_link(%{
        "number" => 1,
        "state" => "open",
        "labels" => [%{"name" => "type:poc"}],
        "assignees" => [],
        "comments" => []
      })

    SimForge.put(pid)

    dispatch_opts = [
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

    entry_opts = [repo: "o/r", routing: @routing, forge_client: SimForge, loader: CarteLoader]

    hc = %HopConsumer{
      repo: "o/r",
      remote: "origin",
      forge_opts: [],
      role_emails: fn r -> ["#{r}@lcars.local"] end,
      hop_completer: Fleet.Pilot.HopCompleter,
      forge_client: SimForge,
      loader: CarteLoader,
      deliverable: DelivStub
    }

    # 1. ENTRÉE : type:poc → route triage + assignee architect
    assert {:ok, {:entered, "architect"}} = Entry.enter(wrap(pid), entry_opts)
    assert {:ok, {"poc-mini", "triage"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "architect"}] = Sim.get(pid)["assignees"]

    # 2. DISPATCH triage → spawn architect (opts portent pipeline+stage)
    assert {:ok, {:spawned, _, "architect"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts)

    assert_received {:spawned, "issue-1", o1}
    assert o1[:pipeline] == "poc-mini" and o1[:stage] == "triage"

    # 3. pod.completed(triage) → HopConsumer → HopCompleter : reassign engineer + route build
    assert {:ok, :reassigned} = HopConsumer.maybe_complete(completed(o1, "architect"), hc)
    assert {:ok, {"poc-mini", "build"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "engineer"}] = Sim.get(pid)["assignees"]
    assert Sim.get(pid)["state"] == "open"
    # verrou retiré entre les hops
    refute Enum.any?(Sim.get(pid)["labels"], &(&1["name"] == "lcars-in-flight"))

    # 4. DISPATCH build → spawn engineer
    assert {:ok, {:spawned, _, "engineer"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts)

    assert_received {:spawned, "issue-1", o2}
    assert o2[:stage] == "build"

    # 5. pod.completed(build) → terminal → close
    assert {:ok, :completed} = HopConsumer.maybe_complete(completed(o2, "engineer"), hc)
    assert Sim.get(pid)["state"] == "closed"

    # trace : un comment signé par rôle
    comments = Sim.get(pid)["comments"]
    assert Enum.any?(comments, &String.contains?(&1, "[hop:architect:"))
    assert Enum.any?(comments, &String.contains?(&1, "[hop:engineer:"))
  end

  # ── A2.3b : chaîne avec gatekeeper-stage explicite (gkchain) ──────────────────
  defp gk_opts do
    {:ok, pid} =
      Sim.start_link(%{
        "number" => 1,
        "state" => "open",
        "labels" => [%{"name" => "type:poc"}],
        "assignees" => [],
        "comments" => []
      })

    SimForge.put(pid)

    dispatch_opts = [
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

    entry_opts = [
      repo: "o/r",
      routing: %{"type:poc" => "gkchain"},
      forge_client: SimForge,
      loader: CarteLoader
    ]

    hc = %HopConsumer{
      repo: "o/r",
      remote: "origin",
      forge_opts: [],
      role_emails: fn r -> ["#{r}@lcars.local"] end,
      hop_completer: Fleet.Pilot.HopCompleter,
      forge_client: SimForge,
      loader: CarteLoader,
      deliverable: DelivStub,
      max_rework_rounds: 2
    }

    {pid, dispatch_opts, entry_opts, hc}
  end

  # entrée → triage(architect) spawn → triage finit (outputs) → review(gatekeeper) spawn.
  # Renvoie {pid, dispatch_opts, hc, review_spawn_opts}.
  defp drive_to_review do
    {pid, dispatch_opts, entry_opts, hc} = gk_opts()

    assert {:ok, {:entered, "architect"}} = Entry.enter(wrap(pid), entry_opts)

    assert {:ok, {:spawned, _, "architect"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts)

    assert_received {:spawned, "issue-1", o1}

    # triage finit avec des outputs → avance vers review(gatekeeper) ; le comment porte result_K
    assert {:ok, :reassigned} =
             HopConsumer.maybe_complete(completed(o1, "architect", %{"severity_max" => "ok"}), hc)

    assert {:ok, {"gkchain", "review"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "gatekeeper"}] = Sim.get(pid)["assignees"]
    assert Enum.any?(Sim.get(pid)["comments"], &String.contains?(&1, "```result"))

    # dispatch review → spawn gatekeeper (rôle connu via CapLoader)
    assert {:ok, {:spawned, _, "gatekeeper"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts)

    assert_received {:spawned, "issue-1", o2}
    assert o2[:stage] == "review"
    # item 5 : le mandat du gatekeeper = brief GateBrief = result_K à juger + contrat verdict.
    assert o2[:mandate] =~ "severity_max"
    assert o2[:mandate] =~ "gate-decision-v1.json"
    assert o2[:mandate] =~ "continue"

    {pid, dispatch_opts, hc, o2}
  end

  test "gatekeeper continue : triage → review(verdict continue) → build → close" do
    {pid, dispatch_opts, hc, o2} = drive_to_review()

    # verdict continue → avance vers build(engineer)
    assert {:ok, :reassigned} =
             HopConsumer.maybe_complete(
               completed(o2, "gatekeeper", %{"decision" => "continue"}),
               hc
             )

    assert {:ok, {"gkchain", "build"}} = SimForge.get_route("o/r", 1, [])
    assert [%{"login" => "engineer"}] = Sim.get(pid)["assignees"]

    # dispatch build → spawn engineer → finit → terminal close
    assert {:ok, {:spawned, _, "engineer"}} =
             StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts)

    assert_received {:spawned, "issue-1", o3}
    assert {:ok, :completed} = HopConsumer.maybe_complete(completed(o3, "engineer"), hc)
    assert Sim.get(pid)["state"] == "closed"

    comments = Sim.get(pid)["comments"]
    assert Enum.any?(comments, &String.contains?(&1, "[hop:gatekeeper:"))
  end

  test "gatekeeper escalate_user : lcars-awaits-human + unlock + poller SKIP (boucle fermée)" do
    {pid, dispatch_opts, hc, o2} = drive_to_review()

    # verdict escalate_user → await-human
    assert {:ok, :awaiting_human} =
             HopConsumer.maybe_complete(
               completed(o2, "gatekeeper", %{"decision" => "escalate_user"}),
               hc
             )

    labels = Enum.map(Sim.get(pid)["labels"], & &1["name"])
    assert "lcars-awaits-human" in labels
    refute "lcars-in-flight" in labels
    assert Sim.get(pid)["state"] == "open"

    # LE POINT CLÉ : le poller NE re-dispatche PAS (assignee=gatekeeper mais awaits-human).
    assert {:skipped, :awaits_human} = StageDispatcher.dispatch_issue(wrap(pid), dispatch_opts)
  end
end
