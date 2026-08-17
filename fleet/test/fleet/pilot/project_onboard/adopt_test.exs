defmodule Fleet.Project.Onboard.AdoptTest do
  @moduledoc """
  `adopt_project/2` (BL-6-32 — the disk→forge inverse of import). The fixture is the measured
  wedge itself: a real local git pair that NO other verb could handle. The landing is asserted
  on the BARE forge repo (what the forge holds is the truth), the refusals on the untouched
  local state.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard, as: ProjectOnboard

  @moduletag :tmp_dir

  # Adopt-shaped forge: `create_repo` makes an EMPTY bare (auto_init: false is the adopt
  # contract — a seeded main would break the local fast-forward push, so the stub PINS it).
  defmodule AdoptForge do
    def generate_repo(_template, _name, _opts), do: {:error, :template_missing}

    def create_repo(name, opts) do
      false = Keyword.get(opts, :auto_init, true)
      bare = Path.join([Process.get(:file_forge_root), "fleet", "#{name}.git"])
      File.mkdir_p!(Path.dirname(bare))
      {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "main", bare])
      send(self(), {:repo_created, "fleet/#{name}"})
      {:ok, "fleet/#{name}"}
    end

    def protect_branch(repo, rule, _fc) do
      send(self(), {:protect_branch, repo, rule})
      {:ok, :created}
    end

    def default_branch(full_name, _fc) do
      path = bare_path(full_name)

      with true <- File.dir?(path),
           {out, 0} <-
             System.cmd(
               "git",
               ["-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/main"],
               stderr_to_stdout: true
             ),
           true <- String.trim(out) != "" do
        {:ok, "main"}
      else
        _ -> {:error, {:http, 404, "gone"}}
      end
    end

    def delete_repo(full_name, _fc) do
      File.rm_rf!(bare_path(full_name))
      send(self(), {:forge_deleted, full_name})
      :ok
    end

    # JG-121/124 — trois etats : `{:ok, bool}` sur une lecture aboutie, comme la vraie forge.
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
    # Le preflight forge ne pose plus qu'UNE question depuis le 2026-08-17 : l'org de ce
    # catalogue existe-t-elle. Le couple `user_exists?`/`team_member?` verifiait l'humain,
    # garde morte avec son motif.
    def org_exists?(_o, _fc), do: {:ok, true}
  end

  defp opts(tmp) do
    forge_root = Path.join(tmp, "forge")
    File.mkdir_p!(forge_root)
    Process.put(:file_forge_root, forge_root)

    [
      # ⚖ L'ORG EST OBLIGATOIRE DEPUIS LE 2026-08-17 : elle fixe le catalogue d'un projet POUR SA
      # VIE, donc elle s'enonce. Ces fixtures s'appuyaient sur le defaut « premier catalogue
      # installe » — un devineur, mort avec lui.
      org: "fleet",
      code_root: Path.join(tmp, "projects"),
      ops_root: Path.join(tmp, "work"),
      workshop_root: Path.join(tmp, "doc"),
      base_url: "file://" <> forge_root,
      forge_repo: AdoptForge,
      forge_users: Humans,
      sleeper: fn _ms -> :ok end,
      ensure_labels: fn repo, _o -> send(self(), {:labels_seeded, repo}) && :ok end,
      ensure_architect: fn repo, _o ->
        send(self(), {:arch_ensured, repo})
        {:ok, "arch-stub"}
      end
    ]
  end

  # The measured wedge: a LOCAL project that exists nowhere else — a git repo on main with
  # real content, no origin, no forge repo.
  defp build_local_main(o, name) do
    dir = Path.join(o[:code_root], name)
    File.mkdir_p!(dir)
    g = fn args -> {_, 0} = System.cmd("git", ["-C", dir] ++ args, stderr_to_stdout: true) end
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "main", dir], stderr_to_stdout: true)
    g.(["config", "user.email", "t@lcars.local"])
    g.(["config", "user.name", "test"])
    File.write!(Path.join(dir, "code.txt"), "the user's real content")
    g.(["add", "."])
    g.(["commit", "-q", "-m", "local work"])
    dir
  end

  defp bare_git!(o, repo, args) do
    bare = Path.join([Path.dirname(o[:code_root]), "forge", "#{repo}.git"])
    {out, 0} = System.cmd("git", ["-C", bare | args], stderr_to_stdout: true)
    out
  end

  test "nominal adopt: main published AS-IS, labels seeded, ops created, protection, arch",
       %{tmp_dir: tmp} do
    o = opts(tmp)
    build_local_main(o, "garage")

    assert {:ok, %{repo: "fleet/garage", architect: %{status: "up"}}} =
             ProjectOnboard.adopt_project("garage", o)

    # The forge main IS the local content (never scaffolded over) + the intensity declaration
    # this call committed (absent locally → written + committed before the single push).
    assert bare_git!(o, "fleet/garage", ["show", "main:code.txt"]) =~ "the user's real content"
    assert bare_git!(o, "fleet/garage", ["show", "main:.lcars.json"]) =~ "pipeline_default"

    # The bare-create lesson (BL-6-33) applies to adopt too.
    assert_received {:labels_seeded, "fleet/garage"}

    # The ops face exists on the forge; the protection landed; the arch is up.
    # `== {:ok, true}` et non une simple verite : depuis JG-121 la fonction rend un triplet d'etats,
    # et `assert` seul passerait aussi sur `{:ok, false}`.
    assert AdoptForge.branch_exists?("fleet/garage", "ops", []) == {:ok, true}
    assert_received {:protect_branch, "fleet/garage", _rule}
    assert_received {:arch_ensured, "fleet/garage"}
  end

  test "a PRESENT ops git dir is pushed AS-IS (no scaffold over the user's work)",
       %{tmp_dir: tmp} do
    o = opts(tmp)
    build_local_main(o, "garage")

    wdir = Path.join(o[:ops_root], "garage")
    File.mkdir_p!(wdir)
    g = fn args -> {_, 0} = System.cmd("git", ["-C", wdir] ++ args, stderr_to_stdout: true) end
    {_, 0} = System.cmd("git", ["init", "-q", "-b", "ops", wdir], stderr_to_stdout: true)
    g.(["config", "user.email", "t@lcars.local"])
    g.(["config", "user.name", "test"])
    File.write!(Path.join(wdir, "notes.md"), "briefs existants")
    g.(["add", "."])
    g.(["commit", "-q", "-m", "ops history"])

    assert {:ok, _} = ProjectOnboard.adopt_project("garage", o)
    assert bare_git!(o, "fleet/garage", ["show", "ops:notes.md"]) =~ "briefs existants"
  end

  test "refusals name the right verb, nothing touched", %{tmp_dir: tmp} do
    o = opts(tmp)

    # No local main → nothing to adopt.
    assert {:error, {:not_adoptable, {:no_local_main, _}}} =
             ProjectOnboard.adopt_project("ghost", o)

    # Origin naming ANOTHER repo → identity conflict.
    dir = build_local_main(o, "stolen")
    {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", "http://x/other/repo.git"])

    assert {:error, {:origin_conflict, "other/repo"}} = ProjectOnboard.adopt_project("stolen", o)

    # Repo already on the forge → that project wants import/open, not adopt.
    build_local_main(o, "taken")
    AdoptForge.create_repo("taken", auto_init: false)
    bare = Path.join([tmp, "forge", "fleet", "taken.git"])
    src = Path.join(tmp, "_seed")
    File.mkdir_p!(src)
    {_, 0} = System.cmd("git", ["clone", "-q", bare, src], stderr_to_stdout: true)
    File.write!(Path.join(src, "x"), "x")

    for args <- [
          ["config", "user.email", "t@t"],
          ["config", "user.name", "t"],
          ["add", "."],
          ["commit", "-q", "-m", "seed"],
          ["push", "-q", "origin", "HEAD:main"]
        ],
        do: {_, 0} = System.cmd("git", ["-C", src] ++ args, stderr_to_stdout: true)

    assert {:error, {:repo_already_exists, "fleet/taken"}} =
             ProjectOnboard.adopt_project("taken", o)

    refute_received {:labels_seeded, _}
  end

  test "a mid-adopt failure compensates the repo + the CREATED work_dir — never the user's proj_dir",
       %{tmp_dir: tmp} do
    o = Keyword.put(opts(tmp), :ensure_labels, fn _r, _o -> {:error, :forge_down} end)
    proj = build_local_main(o, "garage")

    assert {:error, {:protocol_labels, :forge_down}} = ProjectOnboard.adopt_project("garage", o)

    assert_received {:forge_deleted, "fleet/garage"}
    # The user's local content is sacred — untouched through the unwind.
    assert File.exists?(Path.join(proj, "code.txt"))
    refute File.exists?(Path.join(o[:ops_root], "garage"))
  end
end
