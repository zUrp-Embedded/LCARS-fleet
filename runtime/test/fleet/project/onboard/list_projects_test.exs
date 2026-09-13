defmodule Fleet.Project.Onboard.ListProjectsTest do
  @moduledoc """
  Disk listing must distinguish a declared card from its fallback, and unknown parking
  state from open. Fixtures are directories, not Git repos; they exercise placeholder org
  naming and do not establish origin-based identity.
  """
  # This suite mutates global mcp_pod_resolver; run synchronously to avoid clobbering other suites.
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
      # Use the declaration writer so the reader is checked against a real produced record.
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
