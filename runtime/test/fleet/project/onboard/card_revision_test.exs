defmodule Fleet.Project.Onboard.CardRevisionTest do
  @moduledoc """
  Card revision over real local Git repositories created by onboard.
  Inspect the bare repo for landed changes and recorded calls for protection lift/restore;
  the stub does not enforce forge protection.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard, as: ProjectOnboard

  @moduletag :tmp_dir

  defmodule RecordingFileForge do
    def generate_repo(_template, _name, _opts), do: {:error, :template_missing}

    def create_repo(name, _opts) do
      root = Process.get(:file_forge_root)
      src = Path.join(root, "_src_#{name}_#{System.unique_integer([:positive])}")
      bare = Path.join([root, "fleet", "#{name}.git"])
      File.mkdir_p!(src)
      File.mkdir_p!(Path.dirname(bare))

      {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", src], stderr_to_stdout: true)
      File.write!(Path.join(src, "SEED"), "seed")
      {_, 0} = System.cmd("git", ["-C", src, "add", "."], stderr_to_stdout: true)

      {_, 0} =
        System.cmd(
          "git",
          ["-C", src, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "init"],
          stderr_to_stdout: true
        )

      {_, 0} = System.cmd("git", ["clone", "-q", "--bare", src, bare], stderr_to_stdout: true)
      {:ok, "fleet/#{name}"}
    end

    def protect_branch(repo, rule, _fc) do
      send(self(), {:protect_branch, repo, rule})
      Process.get(:protect_result, {:ok, :created})
    end

    def default_branch(full_name, _fc) do
      if File.dir?(bare_path(full_name)), do: {:ok, "main"}, else: {:error, {:http, 404, "gone"}}
    end

    def delete_repo(full_name, _fc) do
      File.rm_rf!(bare_path(full_name))
      :ok
    end

    def branch_exists?(full_name, branch, _fc) do
      path = bare_path(full_name)

      {:ok,
       File.dir?(path) and
         match?(
           {_, 0},
           System.cmd(
             "git",
             ["-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
             stderr_to_stdout: true
           )
         )}
    end

    defp bare_path(full_name), do: Path.join(Process.get(:file_forge_root), "#{full_name}.git")
  end

  defmodule Humans do
    def org_exists?(_o, _fc), do: {:ok, true}
  end

  defp opts(tmp) do
    forge_root = Path.join(tmp, "forge")
    File.mkdir_p!(forge_root)
    Process.put(:file_forge_root, forge_root)

    [
      org: "fleet",
      code_root: Path.join(tmp, "projects"),
      ops_root: Path.join(tmp, "work"),
      workshop_root: Path.join(tmp, "doc"),
      base_url: "file://" <> forge_root,
      forge_repo: RecordingFileForge,
      forge_users: Humans,
      sleeper: fn _ms -> :ok end,
      ensure_labels: fn _repo, _o -> :ok end,
      ensure_architect: fn _repo, _o -> {:ok, "arch-stub"} end
    ]
  end

  # Sync uses a fixture pull --ff-only, not WorktreeSync's full reset/error behavior.
  defp revision_opts(o, extra) do
    base = [
      justification: "le poc est devenu serieux",
      revised_by: "starfleet",
      sync_showcase: fn repo ->
        name = repo |> String.split("/") |> List.last()
        dir = Path.join(o[:code_root], name)

        {_, 0} =
          System.cmd("git", ["-C", dir, "pull", "-q", "--ff-only", "origin", "main"],
            stderr_to_stdout: true
          )

        send(self(), {:showcase_synced, repo})
        :ok
      end
    ]

    o ++ base ++ extra
  end

  defp flush_protects do
    receive do
      {:protect_branch, _, _} -> flush_protects()
    after
      0 -> :ok
    end
  end

  defp bare_path(o, repo), do: Path.join([Keyword.fetch!(o, :base_url_root), "#{repo}.git"])

  defp bare_git!(o, repo, args) do
    {out, 0} = System.cmd("git", ["-C", bare_path(o, repo) | args], stderr_to_stdout: true)
    out
  end

  setup %{tmp_dir: tmp} do
    o = opts(tmp)

    assert {:ok, %{repo: "fleet/tetris"}} =
             ProjectOnboard.onboard("tetris", Keyword.put(o, :workflow_map, "c0-poc"))

    # Drop the onboarding's own lock_main record — the tests below assert the REVISION's calls.
    flush_protects()

    {:ok, o: Keyword.put(o, :base_url_root, Path.join(tmp, "forge"))}
  end

  test "a revision CARRIES FORWARD what it does not restate — it never erases the human's framing",
       %{
         o: o
       } do
    # Revision must carry max_fan forward; Declaration.compose reads only supplied options.
    proj = Path.join([o[:code_root], "tetris"])

    :ok =
      Fleet.Project.Declaration.write(proj,
        workflow_map: "c0-poc",
        justification: "entretien de cadrage",
        max_fan: 4,
        onboarded_by: "human"
      )

    # Explicit Git identity keeps commits independent of the developer's ~/.gitconfig.
    {_, 0} =
      System.cmd(
        "git",
        [
          "-C",
          proj,
          "-c",
          "user.email=t@t",
          "-c",
          "user.name=t",
          "commit",
          "-aqm",
          "seed declaration"
        ],
        stderr_to_stdout: true
      )

    {_, 0} =
      System.cmd("git", ["-C", proj, "push", "-q", "origin", "main"], stderr_to_stdout: true)

    assert {:ok, %{outcome: :revised}} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "c1-light")
             )

    landed = Jason.decode!(bare_git!(o, "fleet/tetris", ["show", "main:.lcars.json"]))

    assert landed["pipeline_default"] == "c1-light"
    assert landed["justification"] == "le poc est devenu serieux"

    assert landed["max_fan"] == 4

    refute Map.has_key?(landed, "level")
    refute Map.has_key?(landed, "nature")
  end

  test "a revision that REDUCES the jury names it — in the commit, the log and the payload", %{
    o: o
  } do
    # A two-to-zero jury reduction remains allowed but must be reported.
    assert {:ok, %{outcome: :revised}} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "standard-qa")
             )

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{jury_delta: -2}} =
                 ProjectOnboard.revise_card(
                   "fleet/tetris",
                   revision_opts(o, workflow_map: "c0-poc")
                 )
      end)

    assert log =~ "REDUCES the jury by 2"

    msg = bare_git!(o, "fleet/tetris", ["log", "-1", "--format=%s", "main"])
    assert msg =~ "JURY REDUIT DE 2"
  end

  test "a PREVIOUS card the catalogue no longer carries yields nil — never a delta of zero", %{
    o: o
  } do
    # An old card can disappear from the catalogue while the local declaration still names it.
    # A failed lookup must return nil, not the reassuring but false delta zero.
    proj = Path.join([o[:code_root], "tetris"])
    declaration = Path.join(proj, ".lcars.json")

    File.write!(
      declaration,
      File.read!(declaration)
      |> String.replace(
        ~s("pipeline_default": "c0-poc"),
        ~s("pipeline_default": "carte-disparue")
      )
    )

    assert {:ok, %{jury_delta: nil, previous_card: "carte-disparue"}} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "standard-qa")
             )

    msg = bare_git!(o, "fleet/tetris", ["log", "-1", "--format=%s", "main"])
    refute msg =~ "JURY REDUIT"
  end

  test "a revision that does NOT shrink the jury says nothing about it", %{o: o} do
    # Both fixture cards have empty juries; zero must not produce a reduction warning.
    assert {:ok, %{jury_delta: 0}} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "audit-only")
             )

    msg = bare_git!(o, "fleet/tetris", ["log", "-1", "--format=%s", "main"])
    refute msg =~ "JURY REDUIT"
  end

  test "revision lands on the forge main — attributed, lift then sized restore, showcase synced",
       %{o: o} do
    assert {:ok, result} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "audit-only")
             )

    assert %{
             repo: "fleet/tetris",
             outcome: :revised,
             card: "audit-only",
             previous_card: "c0-poc",
             protection: :restored
           } = result

    raw = bare_git!(o, "fleet/tetris", ["show", "main:.lcars.json"])
    assert raw =~ ~s("pipeline_default": "audit-only")
    assert raw =~ ~s("declared_by": "starfleet")

    log = bare_git!(o, "fleet/tetris", ["log", "-1", "--format=%an|%s", "main"])
    assert log =~ "system_starfleet"
    assert log =~ "card revision: c0-poc -> audit-only"

    # Recorded lift precedes restore; the test checks an integer approval count, not its size.
    assert_received {:protect_branch, "fleet/tetris", lift}
    assert lift[:enable_push] == true
    assert lift[:enable_push_whitelist] == true
    assert lift[:push_whitelist_usernames] == ["system_starfleet"]
    refute Map.has_key?(lift, :required_approvals)

    assert_received {:protect_branch, "fleet/tetris", restore}
    assert restore[:enable_push] == false
    assert is_integer(restore[:required_approvals])

    assert_received {:showcase_synced, "fleet/tetris"}

    assert File.read!(Path.join([o[:code_root], "tetris", ".lcars.json"])) =~
             "audit-only"
  end

  test "identical re-declaration is an honest no-op — no lift, nothing pushed", %{o: o} do
    ropts = revision_opts(o, workflow_map: "audit-only")
    assert {:ok, %{outcome: :revised}} = ProjectOnboard.revise_card("fleet/tetris", ropts)
    flush_protects()

    sha_before = bare_git!(o, "fleet/tetris", ["rev-parse", "main"])

    assert {:ok, %{outcome: :unchanged, card: "audit-only", previous_card: "audit-only"}} =
             ProjectOnboard.revise_card("fleet/tetris", ropts)

    assert bare_git!(o, "fleet/tetris", ["rev-parse", "main"]) == sha_before
    refute_received {:protect_branch, _, _}
  end

  test "an unloadable card REFUSES before any touch — a typo must not reach the fallback",
       %{o: o} do
    sha_before = bare_git!(o, "fleet/tetris", ["rev-parse", "main"])

    assert {:error, {:unknown_card, "carte-fantome"}} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "carte-fantome")
             )

    assert bare_git!(o, "fleet/tetris", ["rev-parse", "main"]) == sha_before
    refute_received {:protect_branch, _, _}
  end

  test "a refused push restores the rule and reports — the forge main is untouched", %{o: o} do
    hook = Path.join([bare_path(o, "fleet/tetris"), "hooks", "pre-receive"])
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)

    sha_before = bare_git!(o, "fleet/tetris", ["rev-parse", "main"])

    assert {:error, {:card_push_failed, _}} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "audit-only")
             )

    assert bare_git!(o, "fleet/tetris", ["rev-parse", "main"]) == sha_before

    # Push failure still requests restoration; the stub does not enforce the rule.
    assert_received {:protect_branch, "fleet/tetris", lift}
    assert lift[:enable_push] == true
    assert_received {:protect_branch, "fleet/tetris", restore}
    assert restore[:enable_push] == false
    refute_received {:showcase_synced, _}
  end

  test "a TICKET-scoped card is refused as a project declaration — loadable is not declarable", %{
    o: o
  } do
    # A loadable ticket card is still invalid as a project declaration.
    sha_before = bare_git!(o, "fleet/tetris", ["rev-parse", "main"])

    assert {:error, {:card_not_project_scoped, "workshop-direct", "ticket"}} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "workshop-direct")
             )

    assert bare_git!(o, "fleet/tetris", ["rev-parse", "main"]) == sha_before
    refute_received {:protect_branch, "fleet/tetris", _}
    refute_received {:showcase_synced, _}
  end

  test "a revision without its WHY is refused — the untraced mutation this path exists to prevent",
       %{o: o} do
    assert {:error, :justification_required} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               o ++ [workflow_map: "audit-only", revised_by: "starfleet"]
             )

    refute_received {:protect_branch, _, _}
  end

  test "a project not on the machine is refused", %{o: o} do
    assert {:error, {:not_on_machine, "fleet/ghost"}} =
             ProjectOnboard.revise_card(
               "fleet/ghost",
               revision_opts(o, workflow_map: "audit-only")
             )

    refute_received {:protect_branch, _, _}
  end
end
