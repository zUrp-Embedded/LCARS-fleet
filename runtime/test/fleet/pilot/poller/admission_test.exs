defmodule Fleet.Pilot.Poller.AdmissionTest do
  @moduledoc """
  Checks shared dispatch accounting, wait writes and max_fan resolution.
  A source regex detects known tally-update syntax outside Admission; it does not
  prove every possible accounting implementation passes through this module.
  """
  # Serialized because max_fan tests mutate global application configuration.
  use ExUnit.Case, async: false

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
      # Successful dispatch must clear a previous wait label to avoid stale capacity state.
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
      # Project-entry and role-pool saturation share the user's wait/capacity label.
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
      # Scan for the established map-update form; rewriting its syntax can evade this guard.
      rx = ~r/%\{\s*acc\d*\s*\|\s*(dispatched|skipped|errors):/

      sites =
        Path.wildcard("lib/**/*.ex")
        |> Enum.filter(fn path -> path |> File.read!() |> then(&Regex.match?(rx, &1)) end)
        |> Enum.sort()

      # Require a positive match so an ineffective pattern cannot pass vacuously.
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
      root = Fleet.TestEnv.tmp_path("adm_maxfan")
      dir = Path.join(root, "p")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(root) end)
      File.write!(Path.join(dir, ".lcars.json"), body)
      root
    end

    defp decl(n),
      do:
        Jason.encode!(%{
          "_schema" => "lcars/declaration",
          "declared_at" => "2026-08-05",
          "declared_by" => "architect",
          "justification" => "x",
          "pipeline_default" => "brief-gate",
          "max_fan" => n
        })

    test "a declared value wins over the fleet flag" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 7)
      assert Admission.max_fan("fleet/p", code_root: root_with(decl(2))) == 2
    end

    test "clamped to the pool seats at both ends — a declaration is not a way past the ceiling" do
      root_hi = root_with(decl(99))
      root_lo = root_with(decl(0))

      assert Admission.max_fan("fleet/p", code_root: root_hi) == Admission.max_fan_ceiling()
      assert Admission.max_fan("fleet/p", code_root: root_lo) == 1
    end

    test "no project directory at all → the fleet default, quietly (legacy projects are normal)" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 4)
      assert Admission.max_fan("fleet/nowhere", code_root: root_with(decl(2))) == 4
    end

    test "an UNPARSEABLE declaration does not invent a throughput" do
      # Throughput fallback is quiet here; card-resolution diagnostics are a separate concern.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 4)
      assert Admission.max_fan("fleet/p", code_root: root_with("{ not json")) == 4
    end

    test "a non-integer max_fan is refused rather than coerced" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 4)
      body = decl(3) |> Jason.decode!() |> Map.put("max_fan", "beaucoup") |> Jason.encode!()
      assert Admission.max_fan("fleet/p", code_root: root_with(body)) == 4
    end
  end

  describe "max_fan/0 — the reader clamps, it does not report" do
    test "below 1 or above the ceiling → clamped, never zero and never a slot that does not exist" do
      # Clamp at this hot-path reader; configuration/CLI entry owns invalid-value reporting.
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 0)
      assert Admission.max_fan() == 1

      Application.put_env(:lcars_fleet, :pilot_max_fan, 999)
      assert Admission.max_fan() == Admission.max_fan_ceiling()

      Application.put_env(:lcars_fleet, :pilot_max_fan, "trois")
      assert Admission.max_fan() == 5
    end
  end

  describe "write_wait — a label that cannot be posted never blocks a dispatch" do
    defmodule RaisingLabelForge do
      def add_label(_repo, _n, _label, _opts), do: raise("forge label boom")
      def remove_label(_repo, _n, _label, _opts), do: raise("forge label boom")
    end

    test "add_label RAISES → the skip is accounted, the tick stands, the loss is said" do
      raising = [forge_client: RaisingLabelForge, repo: "o/r", forge_opts: []]

      {result, log} =
        ExUnit.CaptureLog.with_log(fn ->
          Admission.admit(fn -> {:skipped, :at_capacity} end, raising, 7, nil, Lease.zero_tally())
        end)

      assert {%{skipped: 1, dispatched: 0, errors: 0}, false} = result
      assert log =~ "wait label"
      assert log =~ "dispatch unaffected"
    end
  end
end
