defmodule Fleet.Project.Onboard.ReconcileTest do
  @moduledoc """
  Reconciliation inventory distinguishes missing declarations from failed reads.
  Two non-project repo names prevent an exclusion-by-one-name implementation from passing.
  Fixtures exercise directory presence, not Git identity or successful import completion.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard.Migration, as: ProjectOnboard

  @moduletag :tmp_dir

  # Stub only the bundled org so a differently scoped query fails visibly.
  defmodule Repo do
    def list_org_repos("fleet", _fc),
      do: {:ok, ["fleet/notes-perso", "fleet/vitrine", "fleet/catalogue"]}
  end

  defmodule MuteRepo do
    def list_org_repos("fleet", _fc), do: {:error, {:http, 503, "nope"}}
  end

  defmodule Files do
    # Successful declaration reads admit vitrine without validating this fixture's schema.
    def get_file("fleet/vitrine", ".lcars.json", fc) do
      send(self(), {:declaration_read, "fleet/vitrine", Keyword.get(fc, :ref)})
      {:ok, %{content: ~s({"schema":"declaration"}), sha: "deadbeef"}}
    end

    def get_file(_repo, ".lcars.json", _fc), do: {:error, :not_found}

    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
  end

  defmodule MuteFiles do
    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
    def get_file(_repo, ".lcars.json", _fc), do: {:error, {:http, 502, "gateway"}}
  end

  defp roots(dir) do
    [
      code_root: Path.join(dir, "code"),
      ops_root: Path.join(dir, "ops"),
      workshop_root: Path.join(dir, "workshop"),
      forge_repo: Repo,
      forge_files: Files
    ]
  end

  defp lay_faces(opts, name) do
    for key <- [:code_root, :ops_root, :workshop_root],
        do: File.mkdir_p!(Path.join(Keyword.fetch!(opts, key), name))
  end

  describe "check — lecture seule" do
    test "un projet absent du disque est MANQUE, et les non-projets ne sont pas listes", %{
      tmp_dir: dir
    } do
      assert [%{repo: "fleet/vitrine", status: :missing}] =
               ProjectOnboard.reconcile(:check, roots(dir))

      # Read main explicitly; the default HTTP ref may point at another branch.
      assert_received {:declaration_read, "fleet/vitrine", "main"}
    end

    test "les trois faces posees rendent DEJA", %{tmp_dir: dir} do
      opts = roots(dir)
      lay_faces(opts, "vitrine")

      assert [%{repo: "fleet/vitrine", status: :present}] = ProjectOnboard.reconcile(:check, opts)
    end

    # One directory must not pass the three-face presence check.
    test "une face sur trois ne suffit pas", %{tmp_dir: dir} do
      opts = roots(dir)
      File.mkdir_p!(Path.join(Keyword.fetch!(opts, :code_root), "vitrine"))

      assert [%{repo: "fleet/vitrine", status: :missing}] = ProjectOnboard.reconcile(:check, opts)
    end
  end

  describe "ce qui ne repond pas ne conclut rien" do
    test "une org illisible rend UN echec nomme, pas une liste vide", %{tmp_dir: dir} do
      opts = Keyword.put(roots(dir), :forge_repo, MuteRepo)

      assert [%{repo: "fleet/*", status: :failed, reason: {:org_unreadable, _}}] =
               ProjectOnboard.reconcile(:check, opts)
    end

    test "une declaration illisible garde le projet dans l'inventaire, en echec", %{tmp_dir: dir} do
      opts = Keyword.put(roots(dir), :forge_files, MuteFiles)

      entries = ProjectOnboard.reconcile(:check, opts)

      assert length(entries) == 3

      assert Enum.all?(entries, fn e ->
               e.status == :failed and
                 match?({:declaration_unreadable, ".lcars.json", _}, e.reason)
             end)
    end
  end

  describe "apply — le rail est `import/2`, pas un second verbe" do
    # Reach import admission through apply and observe its invalid-name refusal.
    defmodule BadNameRepo do
      def list_org_repos("fleet", _fc), do: {:ok, ["fleet/Vitrine_2"]}
    end

    defmodule BadNameFiles do
      def get_file("fleet/Vitrine_2", ".lcars.json", _fc),
        do: {:ok, %{content: "{}", sha: "cafe"}}

      def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
    end

    # These stubs stop before architect ensure and do not test apply's deferred wiring.
    # OnboardCompensationTest covers the deferred result with a real file:// forge.

    test "un depot que l'import refuse remonte en ECHEC avec la raison de l'import", %{
      tmp_dir: dir
    } do
      opts =
        roots(dir)
        |> Keyword.put(:forge_repo, BadNameRepo)
        |> Keyword.put(:forge_files, BadNameFiles)

      assert [%{repo: "fleet/Vitrine_2", status: :failed, reason: {:invalid_name, _}}] =
               ProjectOnboard.reconcile(:apply, opts)
    end
  end
end
