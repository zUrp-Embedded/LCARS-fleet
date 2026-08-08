defmodule Fleet.Pilot.ProjectOnboard.CardRevisionTest do
  @moduledoc """
  `revise_card/2` (BL-6-29) over a REAL on-disk `file://` forge — the fixture is built by the
  REAL `onboard/2` (declared card engraved at birth), then revised. The protection lift/restore
  is asserted on the RECORDED `protect_branch` calls; the landing is asserted on the BARE repo
  (what the forge holds is the truth, never the discarded scratch clone).
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.ProjectOnboard

  @moduletag :tmp_dir

  # Forge stub over a real on-disk `file://` forge (same shape as the compensation suite's
  # FileForge), with `protect_branch` RECORDING its calls — the lift/restore sequence is the
  # subject under test here, not a tunable side effect.
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

      File.dir?(path) and
        match?(
          {_, 0},
          System.cmd(
            "git",
            ["-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/#{branch}"],
            stderr_to_stdout: true
          )
        )
    end

    defp bare_path(full_name), do: Path.join(Process.get(:file_forge_root), "#{full_name}.git")
  end

  defmodule Humans do
    def user_exists?(_h, _fc), do: {:ok, true}
    def team_member?(_org, _team, _h, _fc), do: {:ok, true}
  end

  defp opts(tmp) do
    forge_root = Path.join(tmp, "forge")
    File.mkdir_p!(forge_root)
    Process.put(:file_forge_root, forge_root)

    [
      projects_root: Path.join(tmp, "projects"),
      work_root: Path.join(tmp, "work"),
      doc_root: Path.join(tmp, "doc"),
      base_url: "file://" <> forge_root,
      forge_repo: RecordingFileForge,
      forge_users: Humans,
      sleeper: fn _ms -> :ok end,
      ensure_labels: fn _repo, _o -> :ok end,
      ensure_architect: fn _repo, _o -> {:ok, "arch-stub"} end
    ]
  end

  # Revision opts on top of the machine opts. The `:sync_showcase` seam does what the code-face
  # WorktreeSync does (pull the showcase forward) — the burn reads the card THERE, so the test
  # asserts the sync ran and the showcase file moved.
  defp revision_opts(o, extra) do
    base = [
      justification: "le poc est devenu serieux",
      revised_by: "starfleet",
      sync_showcase: fn repo ->
        name = repo |> String.split("/") |> List.last()
        dir = Path.join(o[:projects_root], name)

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

  test "a revision that REDUCES the jury names it — in the commit, the log and the payload", %{
    o: o
  } do
    # `standard-qa` carries two judges, `c0-poc` carries none. The message used to read
    # `card revision: standard-qa -> c0-poc` — a wall coming down, written in the vocabulary of a
    # rename. Everything auditable, nothing legible: the card NAME does not say what the card does.
    #
    # NOT refused. The criticality level is the human's declaration and a project that genuinely
    # became less critical must be able to say so. What a downgrade may not be is quiet.
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
    # THE GUARD I WROTE WITH ITS REASON, AND NOTHING HELD IT: making an unloadable card read as 0
    # left the whole suite green (measured 2026-08-08). Zero MEANS "the jury did not change", and a
    # delta nobody could compute is not that — it is "I could not tell". Collapsing the two puts a
    # reassuring number on the exact case where a wall may have moved unseen.
    #
    # Reachable: a project declares a card, the operator's catalogue drops it, the project keeps
    # naming it in `intensity.json` until the next revision. The NEW card is guarded
    # (`require_loadable_card`); the previous one never was.
    proj = Path.join([o[:projects_root], "tetris"])
    intensity = Path.join(proj, "intensity.json")

    File.write!(
      intensity,
      File.read!(intensity)
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

    # And nothing claims a reduction it could not measure.
    msg = bare_git!(o, "fleet/tetris", ["log", "-1", "--format=%s", "main"])
    refute msg =~ "JURY REDUIT"
  end

  test "a revision that does NOT shrink the jury says nothing about it", %{o: o} do
    # One meaning per shape: a suffix on every ordinary revision would be noise, and noise is what a
    # reader learns to skip before the one time it matters. `c0-poc` and `doc-direct` both carry an
    # empty jury — a delta of zero is not a reduction.
    assert {:ok, %{jury_delta: 0}} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "doc-direct")
             )

    msg = bare_git!(o, "fleet/tetris", ["log", "-1", "--format=%s", "main"])
    refute msg =~ "JURY REDUIT"
  end

  test "revision lands on the forge main — attributed, lift then sized restore, showcase synced",
       %{o: o} do
    assert {:ok, result} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               revision_opts(o, workflow_map: "doc-direct")
             )

    assert %{
             repo: "fleet/tetris",
             outcome: :revised,
             card: "doc-direct",
             previous_card: "c0-poc",
             protection: :restored
           } = result

    # The forge's main carries the NEW declaration, attributed to the revising role.
    raw = bare_git!(o, "fleet/tetris", ["show", "main:intensity.json"])
    assert raw =~ ~s("pipeline_default": "doc-direct")
    assert raw =~ ~s("declared_by": "starfleet")

    # The commit is the ledger entry: old -> new in the message, system account as author.
    log = bare_git!(o, "fleet/tetris", ["log", "-1", "--format=%an|%s", "main"])
    assert log =~ "lcars-system"
    assert log =~ "card revision: c0-poc -> doc-direct"

    # Lift FIRST (push door reduced to the system account), canonical restore AFTER (door
    # closed, jury re-sized on the card the showcase now declares).
    assert_received {:protect_branch, "fleet/tetris", lift}
    assert lift[:enable_push] == true
    assert lift[:enable_push_whitelist] == true
    assert lift[:push_whitelist_usernames] == ["lcars-system"]
    refute Map.has_key?(lift, :required_approvals)

    assert_received {:protect_branch, "fleet/tetris", restore}
    assert restore[:enable_push] == false
    assert is_integer(restore[:required_approvals])

    # The showcase moved: the next burn reads the NEW card.
    assert_received {:showcase_synced, "fleet/tetris"}

    assert File.read!(Path.join([o[:projects_root], "tetris", "intensity.json"])) =~
             "doc-direct"
  end

  test "identical re-declaration is an honest no-op — no lift, nothing pushed", %{o: o} do
    ropts = revision_opts(o, workflow_map: "doc-direct")
    assert {:ok, %{outcome: :revised}} = ProjectOnboard.revise_card("fleet/tetris", ropts)
    flush_protects()

    sha_before = bare_git!(o, "fleet/tetris", ["rev-parse", "main"])

    assert {:ok, %{outcome: :unchanged, card: "doc-direct", previous_card: "doc-direct"}} =
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
               revision_opts(o, workflow_map: "doc-direct")
             )

    assert bare_git!(o, "fleet/tetris", ["rev-parse", "main"]) == sha_before

    # The door was opened, and CLOSED again on the failure path — never left lifted.
    assert_received {:protect_branch, "fleet/tetris", lift}
    assert lift[:enable_push] == true
    assert_received {:protect_branch, "fleet/tetris", restore}
    assert restore[:enable_push] == false
    refute_received {:showcase_synced, _}
  end

  test "a revision without its WHY is refused — the untraced mutation this path exists to prevent",
       %{o: o} do
    assert {:error, :justification_required} =
             ProjectOnboard.revise_card(
               "fleet/tetris",
               o ++ [workflow_map: "doc-direct", revised_by: "starfleet"]
             )

    refute_received {:protect_branch, _, _}
  end

  test "a project not on the machine is refused", %{o: o} do
    assert {:error, {:not_on_machine, "fleet/ghost"}} =
             ProjectOnboard.revise_card(
               "fleet/ghost",
               revision_opts(o, workflow_map: "doc-direct")
             )

    refute_received {:protect_branch, _, _}
  end
end
