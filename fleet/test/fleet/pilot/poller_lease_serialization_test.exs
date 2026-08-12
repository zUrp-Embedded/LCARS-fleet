defmodule Fleet.Pilot.PollerLeaseSerializationTest do
  @moduledoc """
  `max_fan` — how many workflow_runs one PROJECT holds in flight at once.

  It replaces the `:repo_serialized_lease` boolean, and these tests changed with it rather than
  passing unchanged: they used to set a boolean and assert "one or all". The boolean and the
  counter were the same parameter at two resolutions — **serial IS this ceiling at 1** — and the
  `false` side was genuinely unbounded, which is what the ceiling ends.

  async: false — the knob is a global config.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Poller.Admission
  alias Fleet.Pilot.Poller.Lease
  alias Fleet.TestEnv

  defmodule NoRouteForge do
    # L'admission lit les preconditions avant de DEMARRER un ticket : un stub sans cette lecture
    # ne peut pas voir la porte, et la laisserait disparaitre sans qu'un test rougisse.
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}

    # No `wfmap/*` route engraved: every issue is a fresh one → QUEUED, never ENGAGED. The lease
    # DERIVES the route from the labels it already holds, so `:none` here is the answer to a
    # question asked without I/O — a stub of `get_route/3` would answer one nobody asks anymore.
    def route_from_labels(_labels), do: :none

    # The refusal now WRITES: a full project says so on the ticket instead of skipping in silence.
    def add_label(_repo, n, label, _opts) do
      send(self(), {:add_label, n, label})
      {:ok, :added}
    end

    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
  end

  defmodule CountingDispatcher do
    # Stands in for StepDispatcher: says WHICH ticket the lease let through.
    #
    # It used to read `payload["number"]`, which is always nil: the lease wraps the issue
    # (`%{"issue" => issue, "repository" => …}`), the shape the real dispatcher reads. Every test
    # here asserted counts only, so the broken identity read cost nothing and said nothing — until
    # an order test needed it and got `{:dispatched, nil}` three times.
    def dispatch_issue(payload, _opts) do
      send(self(), {:dispatched, get_in(payload, ["issue", "number"])})
      {:ok, {:spawned, "pod", "engineer"}}
    end
  end

  defp seams(repo \\ "fleet/p") do
    %Lease.Seams{
      forge: NoRouteForge,
      repo: repo,
      forge_opts: [],
      workflow_map_loader: Fleet.Workflow.Loader,
      incident_fun: fn _, _, _, _ -> :ok end,
      dispatcher: CountingDispatcher
    }
  end

  defp opts(extra \\ []),
    do: [forge_client: NoRouteForge, repo: "fleet/p", forge_opts: []] ++ extra

  # A projects root holding one declaration per project, the shape `ProjectIntensity` reads.
  defp declare(decls) do
    root = Path.join(System.tmp_dir!(), "maxfan_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    Enum.each(decls, fn {repo, body} ->
      dir = Path.join(root, Fleet.Layout.project_name(repo))
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, ".intensity.json"),
        Jason.encode!(
          Map.merge(
            %{
              "_schema" => "lcars/intensity-v1",
              "declared_at" => "2026-08-05",
              "declared_by" => "architect",
              "justification" => "banc",
              "pipeline_default" => "brief-gate"
            },
            body
          )
        )
      )
    end)

    root
  end

  defp issues, do: for(n <- [41, 42, 43], do: %{"number" => n, "labels" => []})

  test "max_fan = 1 IS serialization → ONE run starts, the rest waits" do
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 1)

    tally = Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert tally.dispatched == 1
    assert tally.skipped == 2
  end

  test "a refused ticket carries wait/capacity — the ceiling is not silent" do
    # The lease branch never converged its wait label: a ticket held back was indistinguishable
    # from a forgotten one. It is the same refusal as the ceiling's, so it is the same label.
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 1)

    Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert_received {:add_label, 42, "wait/capacity"}
    assert_received {:add_label, 43, "wait/capacity"}
    refute_received {:add_label, 41, _}
  end

  test "max_fan = 3 → the three queued tickets start in the same tick" do
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 3)

    tally = Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert tally.dispatched == 3
    assert tally.skipped == 0
  end

  test "max_fan = 2 → two start, the third waits (the counter is not a boolean)" do
    # The shape the boolean could not express, and the reason for the item: "one" and "all" were
    # the only two answers it had.
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 2)

    tally = Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert tally.dispatched == 2
    assert tally.skipped == 1
  end

  test "a ticket already in its JURY phase eats a seat" do
    # 5.1's repair, read through the ceiling: in-flight crosses both rails, so a jury ticket fills
    # the project as surely as a producer does.
    TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 2)

    # #41 carries an open fleet PR → skipped on this rail, but it counts.
    tally = Lease.process_issues(issues(), MapSet.new([41]), opts(), seams())

    assert tally.dispatched == 1
    assert tally.skipped == 2
  end

  describe "admission order — ascending ticket, decided here" do
    test "three tickets 12/7/30 and ONE seat → the 7 starts" do
      # The listing carries no `sort`, so the order was the forge's default ("most recently
      # touched" under Gitea): the last seat went to whichever ticket someone had just commented
      # on. A rule nobody wrote, that changes when a human types.
      TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 1)

      out_of_order = for n <- [12, 7, 30], do: %{"number" => n, "labels" => []}

      tally = Lease.process_issues(out_of_order, MapSet.new(), opts(), seams())

      assert tally.dispatched == 1
      assert_received {:dispatched, 7}
      refute_received {:dispatched, 12}
      refute_received {:dispatched, 30}
    end

    test "the refused ticket keeps its place at the next tick" do
      # Ascending id is stable across ticks, which is what makes a queue a queue: a ticket refused
      # today is not overtaken tomorrow by one that merely got touched. Two seats, so 7 and 12 go
      # and 30 waits — twice, identically.
      TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 2)

      out_of_order = for n <- [12, 7, 30], do: %{"number" => n, "labels" => []}

      for _tick <- 1..2 do
        Lease.process_issues(out_of_order, MapSet.new(), opts(), seams())

        assert_received {:dispatched, 7}
        assert_received {:dispatched, 12}
        refute_received {:dispatched, 30}
      end
    end
  end

  describe "max_fan/0 — the reader clamps, it does not report" do
    test "absent → the default 5" do
      TestEnv.restore_env_on_exit(:fleet_pilot, :max_fan)
      Application.delete_env(:fleet_pilot, :max_fan)

      assert Admission.max_fan() == 5
    end

    test "the SHELL door and the rail hold the SAME ceiling" do
      # `bin/fleet_v2 --max-fan` validates at the door and cannot call into the BEAM, so the bound
      # is duplicated there. Duplication is fine when it is CHECKED: without this, the door would
      # accept 20 the day the rail moves to 20, or keep refusing 16 the day it drops to 10 — and
      # the operator would meet a flag that argues with the fleet.
      literal =
        "bin/fleet_v2"
        |> File.read!()
        |> then(&Regex.run(~r/^MAX_FAN_CEILING=(\d+)$/m, &1))

      assert literal, "MAX_FAN_CEILING= not found in bin/fleet_v2 — the instrument is broken"
      [_, n] = literal

      assert String.to_integer(n) == Admission.max_fan_ceiling(),
             "the shell door bounds --max-fan at #{n} while the rail clamps at " <>
               "#{Admission.max_fan_ceiling()} — one of the two is lying to the operator"
    end

    test "below 1 or above the ceiling → clamped, never zero and never a slot that does not exist" do
      # A ceiling of 0 would be a fleet that dispatches nothing while reporting healthy; above 15 is
      # a producer asking for a pool seat `PoolSlot` does not have. Clamped HERE because this is read
      # on every dispatch decision: a bad value must fail at a DOOR, once, not every thirty seconds.
      TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 0)
      assert Admission.max_fan() == 1

      Application.put_env(:fleet_pilot, :max_fan, 999)
      assert Admission.max_fan() == Admission.max_fan_ceiling()

      Application.put_env(:fleet_pilot, :max_fan, "trois")
      assert Admission.max_fan() == 5
    end
  end

  describe "the ceiling is PER PROJECT — the counter always was, the knob was not" do
    test "a project that declares 1 serializes ALONE while the fleet default stays 3" do
      # The item, in one test. `--max-fan 1` to watch one pipeline end to end used to serialize
      # every other project in the fleet: a brake laid on unrelated work.
      TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 3)
      root = declare(%{"fleet/p" => %{"max_fan" => 1}})

      declared = Lease.process_issues(issues(), MapSet.new(), opts(code_root: root), seams())
      assert declared.dispatched == 1
      assert declared.skipped == 2

      # Same tick, same fleet, a project that declared nothing: untouched by its neighbour's choice.
      other =
        Lease.process_issues(
          issues(),
          MapSet.new(),
          opts(code_root: root, repo: "fleet/other"),
          seams("fleet/other")
        )

      assert other.dispatched == 3
    end

    test "a declaration ABOVE the hard ceiling is clamped, never granted" do
      # 16 producers means a 16th pool seat, and seats are 1..15. A project cannot declare its way
      # into a slot that does not exist.
      TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 1)
      root = declare(%{"fleet/p" => %{"max_fan" => 99}})

      tally = Lease.process_issues(issues(), MapSet.new(), opts(code_root: root), seams())

      assert tally.dispatched == 3
      assert Admission.max_fan("fleet/p", code_root: root) == Admission.max_fan_ceiling()
    end

    test "a project with a declaration that names no throughput falls back to the fleet default" do
      TestEnv.put_env_restoring(:fleet_pilot, :max_fan, 2)
      root = declare(%{"fleet/p" => %{}})

      tally = Lease.process_issues(issues(), MapSet.new(), opts(code_root: root), seams())

      # Absent is not zero and not one: the key was never written, so the fleet answers.
      assert tally.dispatched == 2
    end
  end
end
