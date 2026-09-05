defmodule Fleet.Project.Onboard.ListProjectsTest do
  @moduledoc """
  The onboarder could destroy a project it had no way to name.

  `require_onboarder` opened create / open / import / adopt / close / delete / revise, and there
  were zero occurrences of any listing anywhere in the surface. Not a filter to widen — a half that
  was never built.

  Two things this listing must NOT do, and they are the same mistake twice: report a fallback as if
  it were a declaration, and report an unreadable state as if it were a known one. Both turn
  "we do not know" into a confident answer, in front of the actor that can delete the subject.
  """
  # `async: false`, and it is the SEAM that decides it, not a preference. `:pod_resolver` is a
  # GLOBAL app-env key: this file and `list_projects_test` both set it, to different roles, and
  # `put_env_restoring` RESTORES it when a test ends — so one suite's teardown blanks the other's
  # seam mid-flight and `resolve_identity` answers `:pod_unknown`, which is neither role but the
  # absence of one. Observed once on 2026-08-05 as a lone red in an otherwise green suite; proven by
  # construction on 2026-08-06 rather than by catching it again. The six other suites touching this
  # key were already `async: false` — these two were the outliers.
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard, as: ProjectOnboard

  @moduletag :tmp_dir

  defmodule OpenForge do
    def list_open_issues(_repo, _opts), do: {:ok, [%{"title" => "chore: something"}]}
  end

  defmodule ParkedForge do
    def list_open_issues(_repo, _opts),
      do: {:ok, [%{"title" => Fleet.Forge.Protocol.parked_issue_title()}]}
  end

  defmodule MuteForge do
    def list_open_issues(_repo, _opts), do: {:error, :forge_unreachable}
  end

  defp project(root, name, declaration \\ nil) do
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    if declaration, do: File.write!(Path.join(dir, ".lcars.json"), declaration)
    dir
  end

  defp list(root, forge \\ OpenForge),
    do: ProjectOnboard.list_projects(code_root: root, forge_issues: forge)

  describe "enumeration" do
    test "every project directory is listed, sorted, with its repo name", %{tmp_dir: tmp} do
      project(tmp, "zeta")
      project(tmp, "alpha")
      File.write!(Path.join(tmp, "not-a-project.txt"), "x")

      assert {:ok, [alpha, zeta]} = list(tmp)
      assert alpha["name"] == "alpha"
      assert alpha["repo"] == "fleet/alpha"
      assert zeta["name"] == "zeta"
    end

    test "an unreadable projects root is a NAMED error, never an empty listing", %{tmp_dir: tmp} do
      assert {:error, {:code_root_unreadable, _, :enoent}} =
               list(Path.join(tmp, "nowhere"))
    end
  end

  describe "the card is reported as DECLARED or not — never as its fallback" do
    test "a declared card carries who declared it — never the fallback", %{tmp_dir: tmp} do
      # THE FIXTURE IS WRITTEN BY THE WRITER, and that is the point of this test as much as the
      # assertions are: a fixture hand-shaped like the reader proves the reader agrees with itself.
      # Naming a card IS the declaration now — there is no separate level to carry (crit_quarantine).
      dir = project(tmp, "alpha")

      :ok =
        Fleet.Project.Declaration.write(dir,
          workflow_map: "standard-qa",
          justification: "cadrage",
          onboarded_by: "starfleet"
        )

      assert {:ok, [p]} = list(tmp)
      assert p["card"] == "standard-qa"
      assert p["card_source"] == "declared"
      assert p["declared_by"] == "starfleet"
    end

    test "an UNDECLARED project reports null, not the card it would burn on", %{tmp_dir: tmp} do
      project(tmp, "alpha")

      assert {:ok, [p]} = list(tmp)
      assert p["card"] == nil
      assert p["card_source"] == "undeclared"
    end

    test "an unparseable declaration says INVALID — it is not the same as undeclared", %{
      tmp_dir: tmp
    } do
      project(tmp, "alpha", "{ this is not json")

      assert {:ok, [p]} = list(tmp)
      assert p["card_source"] == "invalid"
      assert p["card"] == nil
    end

    test "a declaration without a card is invalid too — the key is what governs the burn", %{
      tmp_dir: tmp
    } do
      project(tmp, "alpha", ~s({"justification":"pas de carte nommée"}))

      assert {:ok, [p]} = list(tmp)
      assert p["card_source"] == "invalid"
    end
  end

  describe "the state comes from the forge, and admits when it cannot" do
    test "an open parked marker IS the parked state", %{tmp_dir: tmp} do
      project(tmp, "alpha")

      assert {:ok, [p]} = list(tmp, ParkedForge)
      assert p["state"] == "parked"
      refute Map.has_key?(p, "state_error")
    end

    test "INVERSE TWIN — open issues that are not the marker leave the project open", %{
      tmp_dir: tmp
    } do
      project(tmp, "alpha")

      assert {:ok, [p]} = list(tmp, OpenForge)
      assert p["state"] == "open"
    end

    test "a mute forge yields UNKNOWN with its reason — never a confident 'open'", %{tmp_dir: tmp} do
      project(tmp, "alpha")

      assert {:ok, [p]} = list(tmp, MuteForge)
      assert p["state"] == "unknown"
      assert p["state_error"] =~ "forge_unreachable"
    end
  end

  describe "the gate" do
    test "a pod without the onboarder capability is refused before anything is read" do
      Fleet.TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _ ->
        {:ok, %{role: "engineer", repo: "fleet/demo"}}
      end)

      assert {:error, reason} =
               Fleet.MCP.PodTools.Delegation.Portfolio.list_projects(%{pod_id: "pod-eng"})

      assert reason in [:forbidden_not_onboarder, :forbidden_not_architect]
    end
  end
end
