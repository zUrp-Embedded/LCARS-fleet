defmodule Fleet.Project.OnboardCompensationTest do
  @moduledoc """
  Compensation of a FAILED onboard/import — the mid-sequence failure must not leave half-created
  state that wedges the retry (repo 409 + dir-exists walls, host rm the only way out — seen LIVE).

  E2E against a REAL `file://` forge: the stubbed `:forge_repo` creates an actual bare repo on
  disk (create), fails `protect_branch` (the LAST step — everything is built when the failure
  lands), and records `delete_repo`. Git (clone/scaffold/commit/push) runs for real.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard, as: ProjectOnboard

  @moduletag :tmp_dir

  # Forge stub over a real on-disk `file://` forge. Runs IN the test process (onboard is plain
  # function calls) → coordination via the process dictionary + self-messages.
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

    # `:raise` is a THIRD outcome, and it is the point of one of the tests below: an onboard can
    # die by exception, not only by `{:error, _}`, and the compensation must cover both exits.
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

    # Answered from the bare repo this forge actually holds. Hardcoded `false`, it sent the
    # import RETRY into re-pushing a freshly recreated orphan `ops` — a no-op only while
    # the new commit lands on the same SHA, i.e. within the same SECOND (git timestamps are
    # second-granular). Under load the second flips, the SHA differs, and the push is refused
    # non-fast-forward: a test whose verdict came from the clock. Answering truthfully also
    # exercises the `ops` idempotence `import/2` promises, instead of bypassing it.
    # JG-121/124 — trois etats : `{:ok, bool}` sur une lecture aboutie, comme la vraie forge.
    # `:branch_exists_error` fait tomber la lecture d'UNE face nommee : c'est ainsi qu'on met
    # `workshop` en echec APRES que `ops` a ete publiee, le scenario exact de 6-124.
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

    # 6-124 — la suppression est REELLE sur le depot nu, pour que l'etat distant final soit
    # observable et pas seulement declare. `:delete_branch_result` fait echouer la compensation
    # elle-meme, qui est le seul cas ou l'appelant ne doit PAS croire a un retry propre.
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
    def user_exists?(_h, _fc), do: {:ok, true}
    def team_member?(_org, _team, _h, _fc), do: {:ok, true}
  end

  defp opts(tmp) do
    forge_root = Path.join(tmp, "forge")
    File.mkdir_p!(forge_root)
    Process.put(:file_forge_root, forge_root)

    [
      code_root: Path.join(tmp, "projects"),
      ops_root: Path.join(tmp, "work"),
      workshop_root: Path.join(tmp, "doc"),
      base_url: "file://" <> forge_root,
      forge_repo: FileForge,
      forge_users: Humans,
      sleeper: fn _ms -> :ok end,
      ensure_labels: fn repo, _o -> send(self(), {:labels_seeded, repo}) && :ok end,
      ensure_architect: fn _repo, _o -> {:ok, "arch-stub"} end
    ]
  end

  test "BL-6-33: the BARE fallback SEEDS the protocol labels (a workable repo, not a decorative one)",
       %{tmp_dir: tmp} do
    # FileForge.generate_repo → :template_missing → the bare path. The generate path inherits
    # the labels from the template; the fallback must seed them itself or the first genre/doc
    # ticket dies on {:genre_label_unresolved, _} (measured on a real bench).
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

    # Inside the compensated window: the forge repo this call created is unwound, dirs absent —
    # the retry hits no wall (409 / refute_existing).
    assert_received {:forge_deleted, "fleet/nolabel"}
    refute File.exists?(Path.join(o[:code_root], "nolabel"))
    refute File.exists?(Path.join(o[:ops_root], "nolabel"))
    refute File.exists?(Path.join(o[:workshop_root], "nolabel"))
  end

  test "a LATE onboard failure (protect_branch) compensates: forge repo deleted, dirs removed, retry possible",
       %{tmp_dir: tmp} do
    o = opts(tmp)
    Process.put(:protect_result, {:error, {:http, 500, "boom"}})

    assert {:error, {:protect_main, _}} = ProjectOnboard.onboard("phoenix", o)

    # The unwind: the forge repo THIS call created is deleted, both dirs are gone — nothing left to
    # wedge a retry on the refute_existing / create_repo-409 walls.
    assert_received {:forge_deleted, "fleet/phoenix"}
    refute File.exists?(Path.join(o[:code_root], "phoenix"))
    refute File.exists?(Path.join(o[:ops_root], "phoenix"))
    refute File.exists?(Path.join(o[:workshop_root], "phoenix"))

    # The RETRY of the same onboard now goes through cleanly (fresh create, full sequence).
    Process.put(:protect_result, {:ok, :created})
    assert {:ok, %{repo: "fleet/phoenix"}} = ProjectOnboard.onboard("phoenix", o)
    assert File.dir?(Path.join(o[:code_root], "phoenix"))
    assert File.dir?(Path.join(o[:ops_root], "phoenix"))
    assert File.dir?(Path.join(o[:workshop_root], "phoenix"))
  end

  test "an onboard that RAISES compensates too — and the crash stays a crash", %{tmp_dir: tmp} do
    # The exit compensation did not cover, found on a bench: /home/projects.workshop absent →
    # `mkdir_p!` raised → the forge repo, the code face and the ops face all survived a failed
    # onboard, and the caller saw only `tool_crashed`. The stub raises the very same exception.
    o = opts(tmp)
    Process.put(:protect_result, :raise)

    assert_raise File.Error, fn -> ProjectOnboard.onboard("vulcan", o) end

    # RE-RAISED, so the caller still sees a crash — and the machine is clean anyway.
    assert_received {:forge_deleted, "fleet/vulcan"}
    refute File.exists?(Path.join(o[:code_root], "vulcan"))
    refute File.exists?(Path.join(o[:ops_root], "vulcan"))
    refute File.exists?(Path.join(o[:workshop_root], "vulcan"))

    # And the retry is possible — which is the whole reason compensation exists.
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
    # The repo pre-exists on the forge (created out-of-band, as an import target is).
    {:ok, "fleet/heritage"} = FileForge.create_repo("heritage", [])
    Process.put(:protect_result, {:error, {:http, 500, "boom"}})

    assert {:error, {:protect_main, _}} = ProjectOnboard.import("fleet/heritage", o)

    # Dirs unwound; the repo was NOT ours to delete.
    refute_received {:forge_deleted, _}
    refute File.exists?(Path.join(o[:code_root], "heritage"))
    refute File.exists?(Path.join(o[:ops_root], "heritage"))
    assert File.dir?(Path.join([tmp, "forge", "fleet", "heritage.git"]))

    # ⚠ 6-124 — CE TEST EPINGLAIT LE DEFAUT. Il assertait ici `ops` TOUJOURS SUR LA FORGE apres
    # l'echec, en expliquant que le retry devait la voir et sauter le re-push. C'est precisement le
    # residu que la fiche decrit : les deux faces ont ete poussees par CETTE tentative, sur un depot
    # tiers, et l'appel a repondu « repo untouched ». Elles sont desormais retirees, et l'etat
    # distant final egale l'etat initial : `main` seule, celle que le depot avait.
    assert FileForge.branch_exists?("fleet/heritage", "ops", []) == {:ok, false}
    assert FileForge.branch_exists?("fleet/heritage", "workshop", []) == {:ok, false}
    assert FileForge.branch_exists?("fleet/heritage", "main", []) == {:ok, true}
    assert_received {:branch_deleted, "fleet/heritage", "ops"}
    assert_received {:branch_deleted, "fleet/heritage", "workshop"}

    # Retry clean — sur une forge revenue a son etat initial, donc un vrai chemin de creation et
    # non un re-push dont le succes dependrait de la seconde ou il tombe.
    Process.put(:protect_result, {:ok, :created})
    assert {:ok, %{repo: "fleet/heritage"}} = ProjectOnboard.import("fleet/heritage", o)
  end

  test "6-124: ops pushed then workshop fails → ops is removed, and the return keeps its clean retry",
       %{tmp_dir: tmp} do
    # Le scenario LITTERAL de la fiche : les faces sont posees en sequence, donc `ops` est deja
    # sur la forge quand `workshop` tombe. C'est le seul point du programme ou une mutation
    # partielle d'un depot tiers existe.
    o = opts(tmp)
    {:ok, "fleet/legacy"} = FileForge.create_repo("legacy", [])
    Process.put(:branch_exists_error, "workshop")

    assert {:error, {:branch_unreadable, "workshop", {:http, 503, "down"}}} =
             ProjectOnboard.import("fleet/legacy", o)

    assert_received {:branch_deleted, "fleet/legacy", "ops"}
    assert FileForge.branch_exists?("fleet/legacy", "ops", []) == {:ok, false}
    assert FileForge.branch_exists?("fleet/legacy", "main", []) == {:ok, true}

    # L'erreur passe INTACTE : la compensation a abouti, donc « a clean retry is possible » est
    # redevenu vrai et il n'y a rien de plus a dire a l'appelant.
    Process.delete(:branch_exists_error)
    assert {:ok, %{repo: "fleet/legacy"}} = ProjectOnboard.import("fleet/legacy", o)
  end

  test "6-124: a writer branch that was ALREADY the repo's is never deleted", %{tmp_dir: tmp} do
    # L'autre moitie de la preuve, et la plus chere a rater : une compensation qui supprime ce
    # qu'elle n'a pas cree detruit le travail d'un tiers sur un chemin d'erreur.
    o = opts(tmp)
    {:ok, "fleet/tenant"} = FileForge.create_repo("tenant", [])
    bare = Path.join([tmp, "forge", "fleet", "tenant.git"])
    {_, 0} = System.cmd("git", ["-C", bare, "branch", "ops", "main"], stderr_to_stdout: true)

    Process.put(:branch_exists_error, "workshop")

    assert {:error, {:branch_unreadable, "workshop", _}} =
             ProjectOnboard.import("fleet/tenant", o)

    # `ops` a ete CLONEE, pas publiee — elle n'entre donc pas dans l'inventaire, et aucune
    # suppression n'est meme tentee.
    refute_received {:branch_deleted, _, _}
    assert FileForge.branch_exists?("fleet/tenant", "ops", []) == {:ok, true}
  end

  test "6-124: a compensation that FAILS is named in the RETURN, not only in a log", %{
    tmp_dir: tmp
  } do
    # La condition de la fiche : « si la compensation echoue, le signaler dans le resultat, pas
    # seulement dans un log ». L'appelant deduit du RETOUR qu'il peut retenter proprement ; c'est
    # cette deduction-la qui doit casser, pas une ligne qu'il ne lit pas.
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
    # The 30s stdio bridge times a mutation out while the effect completes; the agent re-emits the
    # SAME call. Before this, the retry of an onboard that FULLY SUCCEEDED died on refute_existing:
    # an operation reported FAILED to the caller with its whole effect in place. That lie is what the
    # in-memory memoize was papering over.

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

      # Nothing re-created, nothing re-scaffolded, no second repo.
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
      # The reason the bar is higher than `open/2`'s: converging on mere EXISTENCE would let a create
      # silently adopt a same-basename project of another owner. Far worse than the bug being fixed.
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
      # `ops` is the LAST step of the sequence, so it standing is what proves the whole sequence
      # ran. Missing, the residue is a half-onboard and answering success would be the same lie in
      # the other direction — a caller told 'created' over a project that has no ops.
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
      # `refute_existing/1` is what stops an onboard from writing over a residue. Dropping the doc
      # face from the paths it checks left the whole suite green (measured 2026-08-08): every
      # existing case here happens to leave a code or ops dir behind too, so no fixture could tell
      # a two-face check from a three-face one. A doc dir alone is exactly the residue a compensated
      # onboard can leave — the face is built LAST.
      o = opts(tmp)
      doc_dir = Path.join(o[:workshop_root], "apollo")
      File.mkdir_p!(doc_dir)

      assert {:error, {:already_exists, ^doc_dir}} = ProjectOnboard.onboard("apollo", o)
    end

    test "a landed onboard whose DOC branch vanished is NOT satisfied — no idempotent 'done'", %{
      tmp_dir: tmp
    } do
      # The twin of the ops case above, and it has to be stated per face: convergence answers
      # "already realized" and creates nothing, so a face missing from what it verifies is a face
      # that never gets built while the caller is told the project is ready.
      {o, _proj, _work} = landed_onboard(tmp)
      bare = Path.join([tmp, "forge", "fleet", "apollo.git"])
      {_, 0} = System.cmd("git", ["-C", bare, "update-ref", "-d", "refs/heads/workshop"])
      assert FileForge.branch_exists?("fleet/apollo", "workshop", []) == {:ok, false}

      assert {:error, {:already_exists, _}} = ProjectOnboard.onboard("apollo", o)
    end
  end
end
