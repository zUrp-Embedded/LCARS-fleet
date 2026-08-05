defmodule Mix.Tasks.Lcars.Contracts.CheckTest do
  @moduledoc """
  Smoke/regression of the `mix lcars.contracts.check` gate: `run_checks/0` runs against the REAL repo
  (single app `:lcars_fleet` post-collapse — no more umbrella, BND-112) and must pass, all checks
  green. Locks that the anti-hollow-green guards (R0-EVT-012/014: absent residue-target = fail,
  absent events.yaml = fail, malformed seam = fail) introduced no false-red, and that a future
  contract regression breaks this test. The doc-immune `code_match?/4` (BND-111) is locked by the
  dedicated describe below.

  NB: testing the fail-on-absent PATHS directly (fixture without events.yaml, malformed seam) would
  require a root-injectable `run_checks(root)` — a separate test-infra refactor, not done here.
  """
  use ExUnit.Case, async: true

  test "run_checks passes on the real repo + all checks green (hollow-green guards without false-red)" do
    assert {:pass, checks} = Mix.Tasks.Lcars.Contracts.Check.run_checks()

    ids = Enum.map(checks, & &1.id)
    # the two hardened R0-EVT-012/014 checks run
    assert "events.handlers.exist" in ids
    # MIGRATION Z3 (D-19): layering.dependency_graph is REMOVED along with its raw material
    # (in_umbrella edges of the app mix.exs files) — mechanical successor = boundary (Z4).
    # Its verifiable replacement today: boot.order_f8 (order of the root children).
    assert "boot.order_f8" in ids

    fails = Enum.filter(checks, &(&1.status != :pass))
    assert fails == [], "non-green checks: #{inspect(Enum.map(fails, &{&1.id, &1.evidence}))}"
  end

  # BL-6-45 / bench 2026-08-02: the check reads TWO lists outside `fleet/runtime`, and the image
  # BUILD stage copies fleet/runtime ALONE before running this gate — a fail-closed on their
  # absence broke the image build (measured: `forge.tf: list not readable` inside the Docker
  # build). Absence is scoped at the TREE level: no sibling tree = out of scope, SKIPPED and
  # NAMED in the note; the equality still runs on what the artifact does carry.
  test "sibling-tree lists: checked when the trees are here, SKIPPED-and-NAMED when they are not" do
    {status, checks} = Mix.Tasks.Lcars.Contracts.Check.run_checks()
    lock = Enum.find(checks, &(&1.id == "roles.provisioning_locked"))

    assert status == :pass
    assert lock.status == :pass

    # The assertion follows the ARTIFACT: a full checkout must check all four lists; a
    # runtime-only one (the image build stage copies fleet/runtime alone) must NAME what it
    # could not see — the one thing that must never happen is a silent pass on absent ground.
    # SAME derivation as the check: the runtime root, then its SIBLING tree
    # (test/mix -> runtime = "../..", then "../provisioning_v2").
    #
    # `provisioning_v2`, not `provisioning` (2026-08-05): the tofu recipe moved there with the rest
    # of the live provisioning. The old condition kept PASSING after the move — the v1 tree still
    # exists — while the check it mirrors had changed trees. It would have diverged for real the day
    # someone cleaned up `fleet/provisioning/`, which its own README now says is safe. A condition
    # that agrees by coincidence is the same defect as a comment that is true by accident.
    runtime_root = Path.expand("../..", __DIR__)

    if File.dir?(Path.expand("../provisioning_v2", runtime_root)) do
      refute lock.note =~ "NOT CHECKED"
    else
      assert lock.note =~ "NOT CHECKED"
      assert lock.note =~ "forge.tf"
    end
  end

  describe "code_match?/4 — anti-hollow-green: a marker in PROSE does not count (BND-111)" do
    @tag :tmp_dir
    test "a marker present ONLY in a @moduledoc/@doc → false (no false-green)", %{
      tmp_dir: tmp
    } do
      # The BND-111 trap: the return-value doc NAMES the `{:error, :brief_required}` tuple; if the
      # check greps the tuple without excluding @doc blocks, a regression of the EXECUTABLE guard
      # would stay green as long as the doc remains. We prove here that the tuple in prose ALONE does
      # NOT satisfy the check.
      File.write!(Path.join(tmp, "prose_only.ex"), """
      defmodule ProseOnly do
        @moduledoc \"\"\"
        Returns:
          * `{:error, :brief_required}` — one-shot pod without a brief
        \"\"\"

        @doc \"\"\"
        Otherwise `{:error, :brief_required}`.
        \"\"\"
        def spawn_pod(_), do: :ok
      end
      """)

      refute Mix.Tasks.Lcars.Contracts.Check.code_match?(
               tmp,
               "prose_only.ex",
               ~r/:brief_required/,
               [
                 ~r/:brief_required/,
                 ~r/^\s*\{:error, :brief_required\}/
               ]
             ),
             "a tuple present only in @moduledoc/@doc must NOT count as code"
    end

    @tag :tmp_dir
    test "the SAME marker on an EXECUTABLE line → true (the real guard counts)", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "real_guard.ex"), """
      defmodule RealGuard.Doc do
        @moduledoc \"\"\"
        Returns `{:error, :brief_required}` in prose here.
        \"\"\"
      end

      defmodule RealGuard do
        def spawn_pod(opts) do
          if opts[:brief], do: :ok, else: {:error, :brief_required}
        end
      end
      """)

      assert Mix.Tasks.Lcars.Contracts.Check.code_match?(
               tmp,
               "real_guard.ex",
               ~r/:brief_required/,
               [
                 ~r/:brief_required/,
                 ~r/^\s*.*\{:error, :brief_required\}/
               ]
             ),
             "the tuple on the guard's executable line must count"
    end
  end
end
