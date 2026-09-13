defmodule Fleet.MCP.CreateIssueLotTest do
  @moduledoc """
  A user lot carries committed workshop files/directories, separate from the task brief.
  Publish through Deliverable so matter uses the same ancestry, identity and secret
  checks as code. An unpublishable lot refuses creation because it has no inline fallback.

  Real local Git origin/clone fixtures check the branch SHA, machine-readable pointer,
  absence of a lot, empty workshop and a detected secret. They do not enumerate every
  publication gate or exercise remote forge authentication.
  """
  use ExUnit.Case, async: false

  alias Fleet.MCP.PodTools
  alias Fleet.TestEnv

  @moduletag :tmp_dir
  @repo "fleet/demo"

  defmodule Forge do
    @behaviour Fleet.MCP.PodTools.Delegation.ForgeClient

    @impl true
    def create_issue(repo, title, body, _opts) do
      send(self(), {:created, repo, title, body})
      {:ok, 7}
    end

    @impl true
    def add_label(_r, _n, _l, _o), do: {:ok, %{}}
    @impl true
    def repo_label_id(_r, _n, _o), do: {:ok, 1}
    @impl true
    def get_issue(_r, _n, _o), do: {:ok, %{"state" => "open"}}
    @impl true
    def list_pulls(_r, _o), do: {:ok, []}
    @impl true
    def list_open_issues(_r, _o), do: {:ok, []}
    @impl true
    def parse_feature_branch(ref), do: Fleet.Forge.Protocol.parse_feature_branch(ref)
    @impl true
    def get_route(_r, _n, _o), do: :none
    @impl true
    def pr_review_state(_r, _n, _o), do: {:ok, %{}}
    @impl true
    def post_comment(_r, _n, _b, _o), do: {:ok, %{}}
    @impl true
    def close_issue(_r, _n, _o), do: {:ok, %{}}
    @impl true
    def close_pr(_r, _n, _o), do: {:ok, %{}}
    @impl true
    def merged_pr_of_issue(_r, _n, _o), do: :none
  end

  defp g(dir, args), do: System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true)

  # Use the runtime human identity so the fixture matches Deliverable's identity check.
  defp workshop_fixture(tmp, human) do
    origin = Path.join(tmp, "origin.git")
    clone = Path.join([tmp, "workshop", "demo"])
    face = Fleet.Layout.workshop_branch()

    {_, 0} =
      System.cmd("git", ["init", "-q", "--bare", "-b", face, origin], stderr_to_stdout: true)

    {_, 0} = System.cmd("git", ["clone", "-q", origin, clone], stderr_to_stdout: true)
    {_, 0} = g(clone, ["config", "user.email", human.email])
    {_, 0} = g(clone, ["config", "user.name", human.name])

    File.write!(Path.join(clone, "README.md"), "the workshop face")
    {_, 0} = g(clone, ["add", "."])
    {_, 0} = g(clone, ["commit", "-q", "-m", "face base"])
    {_, 0} = g(clone, ["push", "-q", "origin", face])

    {origin, clone}
  end

  # The matter: several files AND a directory — the shape no text field carries.
  defp commit_matter(clone) do
    File.mkdir_p!(Path.join(clone, "assets"))
    File.write!(Path.join([clone, "assets", "wireframe.svg"]), "<svg/>")
    File.write!(Path.join(clone, "protocole.md"), "# Morse\n")
    {_, 0} = g(clone, ["add", "."])
    {_, 0} = g(clone, ["commit", "-q", "-m", "matiere du lot"])
    {out, 0} = g(clone, ["rev-parse", "HEAD"])
    String.trim(out)
  end

  setup %{tmp_dir: tmp} do
    {:ok, human} = Fleet.Credentials.ForgeIdentity.human_identity()
    {origin, clone} = workshop_fixture(tmp, human)

    tokens = Path.join(tmp, "tokens")
    File.mkdir_p!(tokens)

    TestEnv.put_env_restoring(:lcars_fleet, :mcp_forge_client, Forge)
    TestEnv.put_env_restoring(:lcars_fleet, :mcp_workshop_root, Path.join(tmp, "workshop"))
    # The DIRECTORY before the token: the path is derived from it (`RoleIdentity.token_path/1`).
    TestEnv.put_env_restoring(:lcars_fleet, :credentials_role_tokens_dir, tokens)
    TestEnv.put_role_token!("architect", "tok-arch")

    TestEnv.put_env_restoring(:lcars_fleet, :mcp_pod_resolver, fn _pod_id ->
      {:ok, %{role: "architect", repo: @repo}}
    end)

    %{origin: origin, clone: clone}
  end

  defp create(args) do
    PodTools.handle_tool_call(
      "issue_create",
      Map.merge(
        %{
          "title" => "reprendre la doc du protocole",
          "brief" => "part du paquet",
          # Supply criteria so these cases reach lot publication instead of an unrelated refusal.
          "criteria" => "l'attendu : le lot est repris fidèlement"
        },
        args
      ),
      %{pod_id: "pod-arch-#{System.unique_integer([:positive])}"}
    )
  end

  describe "the nominal lot" do
    test "the commits are PUBLISHED as `lcars/lot-<slug>` and the ticket names that exact commit",
         %{origin: origin, clone: clone} do
      sha = commit_matter(clone)

      assert {:ok, _result, _state} = create(%{"lot" => "morse-ui-v2"})

      # The local bare origin must contain the exact workshop commit.
      {out, 0} = g(origin, ["rev-parse", "lcars/lot-morse-ui-v2"])
      assert String.trim(out) == sha

      assert_received {:created, @repo, _title, body}
      assert body =~ "Lot: lcars/lot-morse-ui-v2 @ #{sha}"

      # And the pointer is machine-readable by the side that consumes it, not just present.
      assert {:ok, {"lcars/lot-morse-ui-v2", ^sha}} = Fleet.Forge.Protocol.parse_lot_pointer(body)
    end

    test "a ticket WITHOUT a lot carries no lot line and pushes nothing", %{origin: origin} do
      assert {:ok, _result, _state} = create(%{})

      assert_received {:created, @repo, _title, body}
      assert :none = Fleet.Forge.Protocol.parse_lot_pointer(body)

      {_out, code} = g(origin, ["rev-parse", "--verify", "-q", "lcars/lot-morse-ui-v2"])
      assert code != 0
    end
  end

  describe "a lot that cannot be published REFUSES the ticket" do
    test "a name that is not a slug — refused before any forge write", %{clone: clone} do
      _sha = commit_matter(clone)

      assert {:error, {:lot_unpublishable, "Morse UI v2", {:invalid_slug, "Morse UI v2"}}, _state} =
               create(%{"lot" => "Morse UI v2"})

      refute_received {:created, _, _, _}
    end

    test "a lot named over an EMPTY workshop — no commit to carry, so no ticket", %{
      origin: origin
    } do
      # The face is at its base: naming a lot here means the arch believes it committed matter and
      # did not. A ticket created anyway would send a producer to a branch equal to the face head.
      assert {:error, {:lot_unpublishable, "paquet-vide", :no_deliverable_commit}, _state} =
               create(%{"lot" => "paquet-vide"})

      refute_received {:created, _, _, _}
      {_out, code} = g(origin, ["rev-parse", "--verify", "-q", "lcars/lot-paquet-vide"])
      assert code != 0
    end

    test "matter carrying a SECRET is stopped by the publication gate, like any deliverable", %{
      clone: clone,
      origin: origin
    } do
      # The point of publishing through `Deliverable` rather than pushing here: the world-side gate
      # binds matter exactly as it binds code.
      File.write!(Path.join(clone, "notes.md"), "token: sk-ant-abcdef0123456789\n")
      {_, 0} = g(clone, ["add", "."])
      {_, 0} = g(clone, ["commit", "-q", "-m", "notes"])

      assert {:error, {:lot_unpublishable, "paquet-fuite", {:secret_detected, _, _}}, _state} =
               create(%{"lot" => "paquet-fuite"})

      refute_received {:created, _, _, _}
      {_out, code} = g(origin, ["rev-parse", "--verify", "-q", "lcars/lot-paquet-fuite"])
      assert code != 0
    end
  end
end
