defmodule Fleet.Pilot.Poller.AdmissionTest do
  @moduledoc """
  The funnel both dispatch rails traverse.

  What is pinned here is not that the funnel WORKS — the wait rule has its own file and the tally
  is three clauses. It is that there is only ONE of it: the two rails each forgot a different
  transverse rule (the in-flight count on the pulls side, the wait convergence on the lease branch)
  and nothing said so until someone counted.
  """
  use ExUnit.Case, async: true

  alias Fleet.Pilot.Poller.Admission
  alias Fleet.Pilot.Poller.Lease

  defmodule SilentForge do
    def add_label(_repo, n, label, opts) do
      send(Keyword.get(opts, :_test_pid, self()), {:add_label, n, label})
      {:ok, :added}
    end

    def remove_label(_repo, n, label, opts) do
      send(Keyword.get(opts, :_test_pid, self()), {:remove_label, n, label})
      {:ok, :removed}
    end
  end

  defp opts, do: [forge_client: SilentForge, repo: "o/r", forge_opts: [], _test_pid: self()]

  describe "admit/5 — accounting, one mapping for both rails" do
    test "`{:ok, {:merged, _}}` counts as dispatched — the shape only the pulls rail produces" do
      # The issues rail's local mapping matched `{:ok, {:spawned, _, _}}` alone; a `{:merged, _}`
      # reaching it would have raised CaseClauseError inside a tick. One mapping, both shapes.
      assert {%{dispatched: 1, skipped: 0, errors: 0}, true} =
               Admission.admit(
                 fn -> {:ok, {:merged, 7}} end,
                 opts(),
                 nil,
                 nil,
                 Lease.zero_tally()
               )
    end

    test "an unreachable wake is an ERROR that still TOOK the lease" do
      # lock -> pod -> enqueue -> WAKE: the run IS started, so a second start on that repo would be
      # a duplicate. The two facts are independent and the funnel returns both.
      result = {:error, {:wake_unreached, "pod-1", "engineer", :boom}}

      assert {%{dispatched: 0, errors: 1}, true} =
               Admission.admit(fn -> result end, opts(), nil, nil, Lease.zero_tally())
    end

    test "a real dispatch failure took nothing" do
      assert {%{errors: 1}, false} =
               Admission.admit(
                 fn -> {:error, :boom} end,
                 opts(),
                 nil,
                 nil,
                 Lease.zero_tally()
               )
    end

    test "a skip is neither a start nor an error, and it WRITES what it was holding" do
      assert {%{skipped: 1}, false} =
               Admission.admit(
                 fn -> {:skipped, :at_capacity} end,
                 opts(),
                 42,
                 nil,
                 Lease.zero_tally()
               )

      assert_received {:add_label, 42, "wait/capacity"}
    end

    test "the ticket LOSES wait/capacity when a seat frees" do
      # The other half of the refusal, and the one that makes it safe to write at all: a label
      # nobody removes is a stale state that outlives its cause. The dispatch succeeds, the
      # convergence sees a `{:ok, _}` (no opinion to carry) against a ticket that holds one, and
      # removes it. Without this, a project that had ever been full would look permanently full.
      assert {%{dispatched: 1}, true} =
               Admission.admit(
                 fn -> {:ok, {:spawned, "pod", "engineer"}} end,
                 opts(),
                 42,
                 "wait/capacity",
                 Lease.zero_tally()
               )

      assert_received {:remove_label, 42, "wait/capacity"}
    end

    test "both saturation refusals write the SAME label — one ceiling or the other" do
      # `:at_capacity` (project ceiling, `max_fan`) and `:role_at_capacity` (the role's pool seats)
      # are two ceilings and ONE fact for the reader: not started yet. Two labels would make a
      # human learn a taxonomy to read a queue.
      Admission.refuse(:at_capacity, opts(), 1, nil, Lease.zero_tally())
      Admission.refuse(:role_at_capacity, opts(), 2, nil, Lease.zero_tally())

      assert_received {:add_label, 1, "wait/capacity"}
      assert_received {:add_label, 2, "wait/capacity"}
    end

    test "no ticket number → the dispatch is accounted, nothing is written" do
      # A foreign PR whose branch does not parse. Not our ticket: no label, and the tally still moves.
      assert {%{skipped: 1}, false} =
               Admission.admit(
                 fn -> {:skipped, :at_capacity} end,
                 opts(),
                 nil,
                 nil,
                 Lease.zero_tally()
               )

      refute_received {:add_label, _, _}
    end
  end

  describe "current_wait/1 — one derivation of what a ticket waits for" do
    test "finds the wait/* label, ignores the others, tolerates an absent list" do
      payload = %{"labels" => [%{"name" => "kind/bug"}, %{"name" => "wait/role"}]}

      assert Admission.current_wait(payload) == "wait/role"
      assert Admission.current_wait(%{"labels" => [%{"name" => "kind/bug"}]}) == nil
      assert Admission.current_wait(%{}) == nil
      assert Admission.current_wait(nil) == nil
    end
  end

  describe "THE WALL — one accounting site, measured in lib/" do
    test "no rail maps a dispatch result to a tally on its own" do
      # This is the test of the item. It does not restate the funnel — it MEASURES the code,
      # because a funnel that only documents itself protects nothing. The pattern catches the
      # shape both rails used to carry: `%{acc | dispatched: acc.dispatched + 1}` and its siblings.
      #
      # A rail that starts accounting again is a rail about to be handed a transverse rule the
      # other one will not get. That is the moment this reddens.
      rx = ~r/%\{\s*acc\d*\s*\|\s*(dispatched|skipped|errors):/

      sites =
        Path.wildcard("lib/**/*.ex")
        |> Enum.filter(fn path -> path |> File.read!() |> then(&Regex.match?(rx, &1)) end)
        |> Enum.sort()

      # Guard on the instrument itself: if it finds NOTHING, it is the instrument that broke, not
      # the code that became clean. A wall that measures nothing always passes.
      assert Enum.any?(sites),
             "the pattern matches no site at all — the instrument is broken, not the code " <>
               "(measured: 1 site, lib/fleet/pilot/poller/admission.ex, on 2026-08-03)"

      assert sites == ["lib/fleet/pilot/poller/admission.ex"],
             "a dispatch result is folded into a tally OUTSIDE the funnel: #{inspect(sites)} — " <>
               "both rails must traverse Admission, or the next transverse rule lands on one of " <>
               "the two and nothing says which"
    end
  end

  describe "max_fan/2 — the project's declaration, or the fleet's" do
    defp root_with(body) do
      root = Path.join(System.tmp_dir!(), "adm_maxfan_#{System.unique_integer([:positive])}")
      dir = Path.join(root, "p")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(root) end)
      File.write!(Path.join(dir, "intensity.json"), body)
      root
    end

    defp decl(n),
      do:
        Jason.encode!(%{
          "_schema" => "lcars/intensity-v1",
          "declared_at" => "2026-08-05",
          "declared_by" => "architect",
          "justification" => "x",
          "pipeline_default" => "brief-gate",
          "max_fan" => n
        })

    test "a declared value wins over the fleet flag" do
      Fleet.TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 7)
      assert Admission.max_fan("fleet/p", projects_root: root_with(decl(2))) == 2
    end

    test "clamped to the pool seats at both ends — a declaration is not a way past the ceiling" do
      root_hi = root_with(decl(99))
      root_lo = root_with(decl(0))

      assert Admission.max_fan("fleet/p", projects_root: root_hi) == Admission.max_fan_ceiling()
      assert Admission.max_fan("fleet/p", projects_root: root_lo) == 1
    end

    test "no project directory at all → the fleet default, quietly (legacy projects are normal)" do
      Fleet.TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 4)
      assert Admission.max_fan("fleet/nowhere", projects_root: root_with(decl(2))) == 4
    end

    test "an UNPARSEABLE declaration does not invent a throughput" do
      # `pipeline_default/2` alarms on a broken file because substituting a CARD changes the
      # judgment layer. Here the fallback changes a RATE, and a second alarm for the same file
      # would teach a reader that it means something new.
      Fleet.TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 4)
      assert Admission.max_fan("fleet/p", projects_root: root_with("{ not json")) == 4
    end

    test "a non-integer max_fan is refused rather than coerced" do
      Fleet.TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 4)
      body = decl(3) |> Jason.decode!() |> Map.put("max_fan", "beaucoup") |> Jason.encode!()
      assert Admission.max_fan("fleet/p", projects_root: root_with(body)) == 4
    end
  end
end
