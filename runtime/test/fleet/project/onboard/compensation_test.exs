defmodule Fleet.Project.OnboardCompensationTest do
  @moduledoc """
  Onboard/import compensation over real file:// Git repositories.
  Forge API stubs inject returned errors and exceptions; branch deletions mutate the bare repo.
  Checks cover successful cleanup/retry, retained pre-existing branches and reported cleanup
  failures. Protection calls are stubbed, so this is not a full remote-state rollback proof.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard, as: ProjectOnboard
  alias Fleet.Project.Onboard.Faces

  @moduletag :tmp_dir

  # Calls run in the test process; failure injection uses its dictionary and messages.
  defmodule FileForge do
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

    def protect_branch(_repo, _rule, _fc) do
      case Process.get(:protect_result, {:ok, :created}) do
        :raise ->
          raise File.Error, reason: :eacces, action: "make directory (with -p)", path: "/x"

        other ->
          other
      end
    end

    def default_branch(full_name, _fc) do
      if File.dir?(bare_path(full_name)), do: {:ok, "main"}, else: {:error, {:http, 404, "gone"}}
    end

    def delete_repo(full_name, _fc) do
      File.rm_rf!(bare_path(full_name))
      send(self(), {:forge_deleted, full_name})
      :ok
    end

    # Read actual refs: hardcoded absence caused retry success to depend on same-second commit SHAs.
    # A named branch error can fail workshop after ops has already published.
    def branch_exists?(full_name, branch, _fc) do
      if Process.get(:branch_exists_error) == branch do
        {:error, {:http, 503, "down"}}
      else
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
    end

    # Delete real bare refs so cleanup assertions observe remote state; allow deletion failure.
    def delete_branch(full_name, branch, _fc) do
      case Process.get(:delete_branch_result) do
        nil ->
          {_, 0} =
            System.cmd(
              "git",
              ["-C", bare_path(full_name), "update-ref", "-d", "refs/heads/#{branch}"],
              stderr_to_stdout: true
            )

          send(self(), {:branch_deleted, full_name, branch})
          {:ok, :deleted}

        other ->
          send(self(), {:branch_delete_refused, full_name, branch})
          other
      end
    end

    defp bare_path(full_name), do: Path.join(Process.get(:file_forge_root), "#{full_name}.git")
  end

  defmodule Humans do
    def org_exists?(_o, _fc), do: {:ok, true}
  end

  # Explicitly report these targets as non-catalogues; unreadable store checks would refuse
  # before reaching the compensation paths under test.
  defmodule Files do
    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
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
      forge_repo: FileForge,
      forge_users: Humans,
      forge_files: Files,
      sleeper: fn _ms -> :ok end,
      ensure_labels: fn repo, _o ->
        send(self(), {:labels_seeded, repo})
        :ok
      end,
      ensure_architect: fn _repo, _o -> {:ok, "arch-stub"} end
    ]
  end

  test "BL-6-33: the BARE fallback SEEDS the protocol labels (a workable repo, not a decorative one)",
       %{tmp_dir: tmp} do
    # Bare creation must seed protocol labels; it does not inherit them from a template.
    o = opts(tmp)

    assert {:ok, %{repo: "fleet/labelled"}} = ProjectOnboard.onboard("labelled", o)
    assert_received {:labels_seeded, "fleet/labelled"}
  end

  test "BL-6-33: a label seeding that cannot be proven FAILS the onboard — and compensates",
       %{tmp_dir: tmp} do
    o =
      Keyword.put(opts(tmp), :ensure_labels, fn _repo, _o ->
        {:error, {:labels_missing_after_ensure, ["destination/workshop"]}}
      end)

    assert {:error, {:protocol_labels, {:labels_missing_after_ensure, ["destination/workshop"]}}} =
             ProjectOnboard.onboard("nolabel", o)

    assert_received {:forge_deleted, "fleet/nolabel"}
    refute File.exists?(Path.join(o[:code_root], "nolabel"))
    refute File.exists?(Path.join(o[:ops_root], "nolabel"))
    refute File.exists?(Path.join(o[:workshop_root], "nolabel"))
  end

  test "6-125: an unknown workflow_map refuses BEFORE anything is created — no forge, no dirs",
       %{tmp_dir: tmp} do
    # Unknown card refusal must precede repository creation, not rely on later compensation.
    o = opts(tmp)

    assert {:error, {:unknown_card, "wfmap/ghost"}} =
             ProjectOnboard.onboard("ghostcard", Keyword.put(o, :workflow_map, "wfmap/ghost"))

    refute File.exists?(Path.join([tmp, "forge", "fleet", "ghostcard.git"]))
    refute File.exists?(Path.join(o[:code_root], "ghostcard"))
    refute File.exists?(Path.join(o[:ops_root], "ghostcard"))
    refute File.exists?(Path.join(o[:workshop_root], "ghostcard"))
    refute_received {:forge_deleted, _}
  end

  test "a LATE onboard failure (protect_branch) compensates: forge repo deleted, dirs removed, retry possible",
       %{tmp_dir: tmp} do
    o = opts(tmp)
    Process.put(:protect_result, {:error, {:http, 500, "boom"}})

    assert {:error, {:protect_main, _}} = ProjectOnboard.onboard("phoenix", o)

    assert_received {:forge_deleted, "fleet/phoenix"}
    refute File.exists?(Path.join(o[:code_root], "phoenix"))
    refute File.exists?(Path.join(o[:ops_root], "phoenix"))
    refute File.exists?(Path.join(o[:workshop_root], "phoenix"))

    Process.put(:protect_result, {:ok, :created})
    assert {:ok, %{repo: "fleet/phoenix"}} = ProjectOnboard.onboard("phoenix", o)
    assert File.dir?(Path.join(o[:code_root], "phoenix"))
    assert File.dir?(Path.join(o[:ops_root], "phoenix"))
    assert File.dir?(Path.join(o[:workshop_root], "phoenix"))
  end

  test "an onboard that RAISES compensates too — and the crash stays a crash", %{tmp_dir: tmp} do
    # Inject File.Error during protection: the same exception class as the observed mkdir failure,
    # but a later injection point after the local faces have been built.
    o = opts(tmp)
    Process.put(:protect_result, :raise)

    assert_raise File.Error, fn -> ProjectOnboard.onboard("vulcan", o) end

    assert_received {:forge_deleted, "fleet/vulcan"}
    refute File.exists?(Path.join(o[:code_root], "vulcan"))
    refute File.exists?(Path.join(o[:ops_root], "vulcan"))
    refute File.exists?(Path.join(o[:workshop_root], "vulcan"))

    Process.put(:protect_result, {:ok, :created})
    assert {:ok, %{repo: "fleet/vulcan"}} = ProjectOnboard.onboard("vulcan", o)
    assert File.dir?(Path.join(o[:workshop_root], "vulcan"))
  end

  test "a successful onboard compensates NOTHING (dirs + repo stay)", %{tmp_dir: tmp} do
    o = opts(tmp)
    Process.put(:protect_result, {:ok, :created})

    assert {:ok, %{repo: "fleet/apollo", architect: %{status: "up"}}} =
             ProjectOnboard.onboard("apollo", o)

    refute_received {:forge_deleted, _}
    assert File.dir?(Path.join(o[:code_root], "apollo"))
    assert File.dir?(Path.join(o[:ops_root], "apollo"))
    assert File.dir?(Path.join(o[:workshop_root], "apollo"))
  end

  test "a LATE import failure compensates the DIRS and the branches it pushed — the pre-existing repo is NEVER deleted",
       %{tmp_dir: tmp} do
    o = opts(tmp)

    {:ok, "fleet/heritage"} = FileForge.create_repo("heritage", [])
    Process.put(:protect_result, {:error, {:http, 500, "boom"}})

    assert {:error, {:protect_main, _}} = ProjectOnboard.import("fleet/heritage", o)

    refute_received {:forge_deleted, _}
    refute File.exists?(Path.join(o[:code_root], "heritage"))
    refute File.exists?(Path.join(o[:ops_root], "heritage"))
    assert File.dir?(Path.join([tmp, "forge", "fleet", "heritage.git"]))

    # Both newly published writer branches must disappear while pre-existing main remains.
    # Local assertions above cover code and ops, not workshop.
    assert FileForge.branch_exists?("fleet/heritage", "ops", []) == {:ok, false}
    assert FileForge.branch_exists?("fleet/heritage", "workshop", []) == {:ok, false}
    assert FileForge.branch_exists?("fleet/heritage", "main", []) == {:ok, true}
    assert_received {:branch_deleted, "fleet/heritage", "ops"}
    assert_received {:branch_deleted, "fleet/heritage", "workshop"}

    Process.put(:protect_result, {:ok, :created})
    assert {:ok, %{repo: "fleet/heritage"}} = ProjectOnboard.import("fleet/heritage", o)
  end

  test "6-124: ops pushed then workshop fails → ops is removed, and the return keeps its clean retry",
       %{tmp_dir: tmp} do
    # Fail the workshop probe after ops publication to exercise partial remote cleanup.
    o = opts(tmp)
    {:ok, "fleet/legacy"} = FileForge.create_repo("legacy", [])
    Process.put(:branch_exists_error, "workshop")

    assert {:error, {:branch_unreadable, "workshop", {:http, 503, "down"}}} =
             ProjectOnboard.import("fleet/legacy", o)

    assert_received {:branch_deleted, "fleet/legacy", "ops"}
    assert FileForge.branch_exists?("fleet/legacy", "ops", []) == {:ok, false}
    assert FileForge.branch_exists?("fleet/legacy", "main", []) == {:ok, true}

    Process.delete(:branch_exists_error)
    assert {:ok, %{repo: "fleet/legacy"}} = ProjectOnboard.import("fleet/legacy", o)
  end

  test "6-124: a writer branch that was ALREADY the repo's is never deleted", %{tmp_dir: tmp} do
    # Pre-existing branches must survive compensation of a later error.
    o = opts(tmp)
    {:ok, "fleet/tenant"} = FileForge.create_repo("tenant", [])
    bare = Path.join([tmp, "forge", "fleet", "tenant.git"])
    {_, 0} = System.cmd("git", ["-C", bare, "branch", "ops", "main"], stderr_to_stdout: true)

    Process.put(:branch_exists_error, "workshop")

    assert {:error, {:branch_unreadable, "workshop", _}} =
             ProjectOnboard.import("fleet/tenant", o)

    refute_received {:branch_deleted, _, _}
    assert FileForge.branch_exists?("fleet/tenant", "ops", []) == {:ok, true}
  end

  test "6-124: a compensation that FAILS is named in the RETURN, not only in a log", %{
    tmp_dir: tmp
  } do
    # Branch deletion failure must be visible in the return, not just the log.
    o = opts(tmp)
    {:ok, "fleet/stuck"} = FileForge.create_repo("stuck", [])
    Process.put(:protect_result, {:error, {:http, 500, "boom"}})
    Process.put(:delete_branch_result, {:error, {:http, 403, "protected"}})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:import_not_compensated, {:protect_main, _}, left}} =
                 ProjectOnboard.import("fleet/stuck", o)

        assert [{"ops", {:error, {:http, 403, "protected"}}} | _] = left
      end)

    assert log =~ "REPO MUTATED"
    assert_received {:branch_delete_refused, "fleet/stuck", "ops"}
    assert FileForge.branch_exists?("fleet/stuck", "ops", []) == {:ok, true}
  end

  describe "convergent re-emit — a mutation whose effect landed answers with it, never a refusal" do
    # A caller can time out after creation has completed and then repeat the request.

    defp landed_onboard(tmp) do
      o = opts(tmp)
      assert {:ok, %{repo: "fleet/apollo"}} = ProjectOnboard.onboard("apollo", o)
      {o, Path.join(o[:code_root], "apollo"), Path.join(o[:ops_root], "apollo")}
    end

    test "re-emit of a fully landed onboard → {:ok, idempotent}, nothing created", %{tmp_dir: tmp} do
      {o, proj, work} = landed_onboard(tmp)
      before_head = File.read!(Path.join([proj, ".git", "HEAD"]))

      assert {:ok, %{repo: "fleet/apollo", idempotent: true, project_dir: ^proj, work_dir: ^work}} =
               ProjectOnboard.onboard("apollo", o)

      # HEAD-file equality checks symbolic refs, not commit IDs; it cannot prove no new commits.
      refute_received {:forge_deleted, _}
      assert File.read!(Path.join([proj, ".git", "HEAD"])) == before_head
      assert File.dir?(Path.join([tmp, "forge", "fleet", "apollo.git"]))
    end

    test "re-emit of a fully landed import → {:ok, idempotent}", %{tmp_dir: tmp} do
      o = opts(tmp)
      {:ok, "fleet/legacy"} = FileForge.create_repo("legacy", [])
      assert {:ok, %{repo: "fleet/legacy"}} = ProjectOnboard.import("fleet/legacy", o)

      assert {:ok, %{repo: "fleet/legacy", idempotent: true}} =
               ProjectOnboard.import("fleet/legacy", o)
    end

    test "dirs of a HOMONYM project → still REFUSED (converging on existence would adopt it)", %{
      tmp_dir: tmp
    } do
      # Existing directories alone cannot distinguish an unrelated owner's same-basename project.
      {o, proj, _work} = landed_onboard(tmp)

      {_, 0} =
        System.cmd(
          "git",
          [
            "-C",
            proj,
            "remote",
            "set-url",
            "origin",
            "file:///elsewhere/someone-else/apollo.git"
          ],
          stderr_to_stdout: true
        )

      assert {:error, {:already_exists, _}} = ProjectOnboard.onboard("apollo", o)
    end

    test "a HALF onboard (ops never published) → still REFUSED, never answered 'done'", %{
      tmp_dir: tmp
    } do
      # Missing ops must refuse convergence; its presence alone does not prove full onboarding.
      {o, _proj, _work} = landed_onboard(tmp)
      bare = Path.join([tmp, "forge", "fleet", "apollo.git"])
      {_, 0} = System.cmd("git", ["-C", bare, "update-ref", "-d", "refs/heads/ops"])
      assert FileForge.branch_exists?("fleet/apollo", "ops", []) == {:ok, false}

      assert {:error, {:already_exists, _}} = ProjectOnboard.onboard("apollo", o)
    end

    test "dirs ours but the forge repo is GONE → still REFUSED (not a satisfied intention)", %{
      tmp_dir: tmp
    } do
      {o, _proj, _work} = landed_onboard(tmp)
      File.rm_rf!(Path.join([tmp, "forge", "fleet", "apollo.git"]))

      assert {:error, {:already_exists, _}} = ProjectOnboard.onboard("apollo", o)
    end

    test "the DOC face alone on disk is enough to refuse — the door counts every face", %{
      tmp_dir: tmp
    } do
      # Isolate workshop residue: fixtures also containing code/ops cannot catch its omitted guard.
      o = opts(tmp)
      doc_dir = Path.join(o[:workshop_root], "apollo")
      File.mkdir_p!(doc_dir)

      assert {:error, {:already_exists, ^doc_dir}} = ProjectOnboard.onboard("apollo", o)
    end

    test "a landed onboard whose DOC branch vanished is NOT satisfied — no idempotent 'done'", %{
      tmp_dir: tmp
    } do
      # Check the remote workshop branch separately from local directory presence.
      {o, _proj, _work} = landed_onboard(tmp)
      bare = Path.join([tmp, "forge", "fleet", "apollo.git"])
      {_, 0} = System.cmd("git", ["-C", bare, "update-ref", "-d", "refs/heads/workshop"])
      assert FileForge.branch_exists?("fleet/apollo", "workshop", []) == {:ok, false}

      assert {:error, {:already_exists, _}} = ProjectOnboard.onboard("apollo", o)
    end
  end

  # An eval caller without running supervisors can return deferred explicitly.
  # This test injects that callback result; it does not simulate missing supervisors.
  test "un appelant SANS fleet differe l'architecte — ni up, ni failed", %{tmp_dir: tmp} do
    o =
      Keyword.put(opts(tmp), :ensure_architect, fn _repo, _o ->
        {:deferred, "aucune fleet dans cette VM"}
      end)

    assert {:ok, %{repo: "fleet/differe", architect: arch}} =
             ProjectOnboard.onboard("differe", o)

    assert arch == %{status: "deferred", reason: "aucune fleet dans cette VM"}
  end

  describe "le MODE des faces d'ecriture" do
    # Shared-group workshop writes require 2775 while ops stays 2755. Assert both root modes:
    # without chmod one expected value could pass by coinciding with the process umask.
    defp face_mode(dir), do: Bitwise.band(File.stat!(dir).mode, 0o7777)

    test "creees : workshop est g+w, ops ne l'est pas", %{tmp_dir: tmp} do
      o = opts(tmp)
      {:ok, "fleet/neuf"} = FileForge.create_repo("neuf", [])

      assert {:ok, %{repo: "fleet/neuf"}} = ProjectOnboard.import("fleet/neuf", o)

      assert face_mode(Path.join(o[:workshop_root], "neuf")) == 0o2775
      assert face_mode(Path.join(o[:ops_root], "neuf")) == 0o2755
    end

    test "CLONEES : le mode est pose sur l'autre branche aussi", %{tmp_dir: tmp} do
      # Existing branches exercise clone-path chmod as well as creation-path chmod.
      o = opts(tmp)
      {:ok, "fleet/rejoint"} = FileForge.create_repo("rejoint", [])
      bare = Path.join([tmp, "forge", "fleet", "rejoint.git"])
      {_, 0} = System.cmd("git", ["-C", bare, "branch", "ops", "main"], stderr_to_stdout: true)

      {_, 0} =
        System.cmd("git", ["-C", bare, "branch", "workshop", "main"], stderr_to_stdout: true)

      assert {:ok, %{repo: "fleet/rejoint"}} = ProjectOnboard.import("fleet/rejoint", o)

      assert face_mode(Path.join(o[:workshop_root], "rejoint")) == 0o2775
      assert face_mode(Path.join(o[:ops_root], "rejoint")) == 0o2755
    end

    # A chmod clamps the mask of any ACL the deployment placed on the face, so a conforming mode is
    # measured and left alone. ctime moves on a metadata write and on that write only; the second
    # assertion is the control that proves the instrument can see a write at all.
    defp ctime(dir), do: dir |> then(&System.cmd("stat", ["-c", "%.9Z", &1])) |> elem(0)

    test "un mode deja conforme n'est pas reecrit", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "face")
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o2775)
      avant = ctime(dir)

      assert :ok = Faces.chmod_face(dir, 0o2775)
      assert ctime(dir) == avant
      assert face_mode(dir) == 0o2775

      assert :ok = Faces.chmod_face(dir, 0o2755)
      assert ctime(dir) != avant
      assert face_mode(dir) == 0o2755
    end

    test "un dossier illisible est un refus nomme, jamais un mode pose a l'aveugle", %{
      tmp_dir: tmp
    } do
      assert {:error, {:face_mode_unreadable, _dir, :enoent}} =
               Faces.chmod_face(Path.join(tmp, "absente"), 0o2775)
    end
  end
end
