defmodule Fleet.Pilot.Poller.LeaseSerializationTest do
  @moduledoc """
  Checks entry counts and issue ordering under max_fan, including jury seats and
  awaiting-architect routes. Poller supplies per-human scope; these fixtures contain
  one supplied issue set. Serialized because configuration changes are global.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Poller.Admission
  alias Fleet.Pilot.Poller.Lease
  alias Fleet.TestEnv

  defmodule NoRouteForge do
    # Queued starts read dependencies; supply that production capability in the stub.
    def issue_dependencies(_repo, _n, _opts), do: {:ok, []}

    # Derive route state from listed labels; a network get_route stub would not be called.
    def route_from_labels(_labels), do: :none

    # The refusal now WRITES: a full project says so on the ticket instead of skipping in silence.
    def add_label(_repo, n, label, _opts) do
      send(self(), {:add_label, n, label})
      {:ok, :added}
    end

    def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
  end

  defmodule CountingDispatcher do
    # Report the nested issue number, not the absent top-level field, so ordering
    # assertions identify tickets instead of counting indistinguishable nil messages.
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

  # A projects root holding one declaration per project, the shape `ProjectDeclaration` reads.
  defp declare(decls) do
    root = TestEnv.tmp_path("maxfan")
    on_exit(fn -> File.rm_rf!(root) end)

    Enum.each(decls, fn {repo, body} ->
      dir = Path.join(root, Fleet.Layout.project_name(repo))
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, ".lcars.json"),
        Jason.encode!(
          Map.merge(
            %{
              "_schema" => "lcars/declaration",
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
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 1)

    tally = Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert tally.dispatched == 1
    assert tally.skipped == 2
  end

  test "a refused ticket carries wait/capacity — the ceiling is not silent" do
    # Pre-dispatch refusal must be visible on the refused ticket.
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 1)

    Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert_received {:add_label, 42, "wait/capacity"}
    assert_received {:add_label, 43, "wait/capacity"}
    refute_received {:add_label, 41, _}
  end

  test "max_fan = 3 → the three queued tickets start in the same tick" do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 3)

    tally = Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert tally.dispatched == 3
    assert tally.skipped == 0
  end

  test "max_fan = 2 → two start, the third waits (the counter is not a boolean)" do
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 2)

    tally = Lease.process_issues(issues(), MapSet.new(), opts(), seams())

    assert tally.dispatched == 2
    assert tally.skipped == 1
  end

  test "a ticket already in its JURY phase eats a seat" do
    # Jury work still occupies a workflow-run seat.
    TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 2)

    # #41 carries an open fleet PR → skipped on this rail, but it counts.
    tally = Lease.process_issues(issues(), MapSet.new([41]), opts(), seams())

    assert tally.dispatched == 1
    assert tally.skipped == 2
  end

  describe "admission order — ascending ticket, decided here" do
    test "three tickets 12/7/30 and ONE seat → the 7 starts" do
      # Input order must not decide who gets the last seat.
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 1)

      out_of_order = for n <- [12, 7, 30], do: %{"number" => n, "labels" => []}

      tally = Lease.process_issues(out_of_order, MapSet.new(), opts(), seams())

      assert tally.dispatched == 1
      assert_received {:dispatched, 7}
      refute_received {:dispatched, 12}
      refute_received {:dispatched, 30}
    end

    test "the refused ticket keeps its place at the next tick" do
      # Repeat identical input to check stable admission order; the stub does not
      # persist the started runs between calls.
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 2)

      out_of_order = for n <- [12, 7, 30], do: %{"number" => n, "labels" => []}

      for _tick <- 1..2 do
        Lease.process_issues(out_of_order, MapSet.new(), opts(), seams())

        assert_received {:dispatched, 7}
        assert_received {:dispatched, 12}
        refute_received {:dispatched, 30}
      end
    end
  end

  describe "max_fan/0 — the default, and the shell door's ceiling (the clamp is admission_test's)" do
    test "absent → the default 5" do
      TestEnv.restore_env_on_exit(:lcars_fleet, :pilot_max_fan)
      Application.delete_env(:lcars_fleet, :pilot_max_fan)

      assert Admission.max_fan() == 5
    end

    test "the SHELL door and the rail hold the SAME ceiling" do
      # The shell cannot call BEAM here; compare its duplicated ceiling with Admission's.
      literal =
        "bin/fleet"
        |> File.read!()
        |> then(&Regex.run(~r/^MAX_FAN_CEILING=(\d+)$/m, &1))

      assert literal, "MAX_FAN_CEILING= not found in bin/fleet — the instrument is broken"
      [_, n] = literal

      assert String.to_integer(n) == Admission.max_fan_ceiling(),
             "the shell door bounds --max-fan at #{n} while the rail clamps at " <>
               "#{Admission.max_fan_ceiling()} — one of the two is lying to the operator"
    end
  end

  describe "the ceiling is PER PROJECT — the counter always was, the knob was not" do
    test "a project that declares 1 serializes ALONE while the fleet default stays 3" do
      # A project declaration must not serialize unrelated projects.
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 3)
      root = declare(%{"fleet/p" => %{"max_fan" => 1}})

      declared = Lease.process_issues(issues(), MapSet.new(), opts(code_root: root), seams())
      assert declared.dispatched == 1
      assert declared.skipped == 2

      # A separate call for another project retains the fleet default.
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
      # A declaration cannot bypass the hard ceiling.
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 1)
      root = declare(%{"fleet/p" => %{"max_fan" => 99}})

      tally = Lease.process_issues(issues(), MapSet.new(), opts(code_root: root), seams())

      assert tally.dispatched == 3
      # Three tickets saturate at any ceiling ≥ 3: the tally alone cannot tell « 99 clamped to
      # 15 » from « 99 granted ». The reader's answer is what makes the name of this test true.
      assert Admission.max_fan("fleet/p", code_root: root) == Admission.max_fan_ceiling()
    end

    test "a project with a declaration that names no throughput falls back to the fleet default" do
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 2)
      root = declare(%{"fleet/p" => %{}})

      tally = Lease.process_issues(issues(), MapSet.new(), opts(code_root: root), seams())

      # Absent is not zero and not one: the key was never written, so the fleet answers.
      assert tally.dispatched == 2
    end
  end

  describe "⚖ a ticket parked under lcars-awaits-arch holds a seat iff its route is advanced (2026-09-05)" do
    # The route is read off the labels by the REAL parser; `standard-qa`'s root is `brief-review`,
    # `build` comes after it. The parked ticket carries the HIGHEST number, so that « ENGAGED, seat
    # already counted » and « QUEUED, takes the first seat » cannot produce the same messages.
    defmodule RouteForge do
      def issue_dependencies(_repo, _n, _opts), do: {:ok, []}
      defdelegate route_from_labels(labels), to: Fleet.Forge.Client

      def add_label(_repo, n, label, _opts) do
        send(self(), {:add_label, n, label})
        {:ok, :added}
      end

      def remove_label(_repo, _n, _label, _opts), do: {:ok, :removed}
    end

    # Honours `decide/1` for the one label that matters here: a parked ticket is never dispatched.
    defmodule ParkAwareDispatcher do
      def dispatch_issue(payload, _opts) do
        issue = payload["issue"]

        if Enum.any?(issue["labels"] || [], &(&1["name"] == "lcars-awaits-arch")) do
          {:skipped, :awaits_arch}
        else
          send(self(), {:dispatched, issue["number"]})
          {:ok, {:spawned, "pod", "engineer"}}
        end
      end
    end

    defp parked_at(stage) do
      %{
        "number" => 44,
        "labels" => [
          %{"name" => "wfmap/standard-qa"},
          %{"name" => "stage/#{stage}"},
          %{"name" => "lcars-awaits-arch"}
        ]
      }
    end

    defp run_serial(parked) do
      TestEnv.put_env_restoring(:lcars_fleet, :pilot_max_fan, 1)
      fresh = for n <- [41, 42], do: %{"number" => n, "labels" => []}

      Lease.process_issues(
        fresh ++ [parked],
        MapSet.new(),
        opts(),
        %{seams() | forge: RouteForge, dispatcher: ParkAwareDispatcher}
      )
    end

    test "parked with an ADVANCED route: the only seat is held, the fresh tickets wait" do
      tally = run_serial(parked_at("build"))

      assert tally.dispatched == 0
      assert tally.skipped == 3
      assert_received {:add_label, 41, "wait/capacity"}
      assert_received {:add_label, 42, "wait/capacity"}
      refute_received {:dispatched, _}
    end

    test "parked at the ROOT (a refused brief): no seat held, the next ticket starts" do
      tally = run_serial(parked_at("brief-review"))

      assert tally.dispatched == 1
      assert_received {:dispatched, 41}
      assert_received {:add_label, 42, "wait/capacity"}
      # The parked root ticket competes like any queued one: refused at capacity, and told so.
      assert_received {:add_label, 44, "wait/capacity"}
    end
  end
end
