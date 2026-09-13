defmodule Fleet.Project.OnboardMigrateTest do
  @moduledoc """
  Migration repoints real local Git origins after a stubbed forge transfer.
  It reports absent faces without testing forge metadata, redirects or rollback.
  Despite the migration group's title, the operation is not atomic.

  Deposit tests cover candidate naming/visibility and refusal paths, not successful copying.
  Synchronous because catalogue discovery uses global app configuration.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard, as: ProjectOnboard

  @old_url "http://forge.test/fleet/vitrine.git"

  defmodule RefuseUsers do
    # Record the org queried so a wrong first-catalogue default is observable.
    def org_exists?(org, _fc), do: {:ok, put_org(org)}

    defp put_org(org),
      do:
        (
          :persistent_term.put({__MODULE__, :org}, org)
          false
        )

    def last_org, do: :persistent_term.get({__MODULE__, :org}, nil)
  end

  defmodule TransferOk do
    # Match both source and target at the transfer seam.
    def transfer_repo("fleet/vitrine", "web", _fc), do: {:ok, "web/vitrine"}

    def private?(_repo, _fc), do: {:ok, false}
  end

  defmodule PrivateSource do
    def private?("lordzurp/secret", _fc), do: {:ok, true}
  end

  defmodule VisibilityDown do
    def private?(_repo, _fc), do: {:error, {:transport, :econnrefused}}
  end

  setup %{tmp_dir: tmp} do
    home = Path.join(tmp, "operator")
    File.mkdir_p!(Path.join(home, "catalogues"))

    # The bundled catalogue already has its manifest; the second fixture needs one for discovery.
    web = Path.join([home, "catalogues", "web"])
    File.mkdir_p!(Path.join(web, Fleet.Catalogue.rel(:cap_profiles)))
    File.write!(Path.join(web, "catalogue.yaml"), "api_version: 1\nname: web\n")

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [
      Path.join(home, "catalogues")
    ])

    %{tmp: tmp}
  end

  defp face(tmp, kind) do
    dir = Path.join([tmp, kind, "vitrine"])
    File.mkdir_p!(dir)
    {_, 0} = System.cmd("git", ["-C", dir, "init", "-q"])
    {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", @old_url])
    dir
  end

  defp origin(dir) do
    {url, 0} = System.cmd("git", ["-C", dir, "remote", "get-url", "origin"])
    String.trim(url)
  end

  # Admit the fixtures as non-stores so tests reach their intended guards instead of a real API read.
  defmodule NotCatalogues do
    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
  end

  defp opts(tmp) do
    [
      forge_repo: TransferOk,
      forge_files: NotCatalogues,
      base_url: "http://forge.test",
      code_root: Path.join(tmp, "code"),
      workshop_root: Path.join(tmp, "workshop"),
      ops_root: Path.join(tmp, "ops")
    ]
  end

  defmodule TwoOrgs do
    def list_user_repos("lordzurp", _fc),
      do: {:ok, ["lordzurp/vitrine", "lordzurp/mon-projet", "lordzurp/chifoumi"]}

    def list_org_repos("fleet", _fc), do: {:ok, ["fleet/vitrine", "fleet/lcars"]}
    def list_org_repos("web", _fc), do: {:ok, []}
  end

  defmodule OrgDown do
    def list_user_repos(_l, _fc), do: {:ok, ["lordzurp/x"]}
    def list_org_repos("fleet", _fc), do: {:ok, []}
    def list_org_repos("web", _fc), do: {:error, {:transport, :econnrefused}}
  end

  defmodule BadName do
    def list_user_repos(_l, _fc), do: {:ok, ["lordzurp/Mon_Projet"]}
    def list_org_repos(_o, _fc), do: {:ok, []}
  end

  describe "deposit_candidates — the LOCATION is the state" do
    @tag :tmp_dir
    test "a personal repo a catalogue org already carries is no longer a candidate" do
      assert {:ok, candidats} =
               ProjectOnboard.deposit_candidates("lordzurp", forge_repo: TwoOrgs)

      # Source copies remain personal: suppress already-enrolled basenames to avoid repeated offers.
      assert Enum.map(candidats, & &1["source"]) == ["lordzurp/chifoumi", "lordzurp/mon-projet"]
      assert Enum.all?(candidats, & &1["admissible"])
    end

    @tag :tmp_dir
    test "an unreachable org REFUSES instead of returning a list that is too wide" do
      assert {:error, {:enrolled_scan_failed, "web", _}} =
               ProjectOnboard.deposit_candidates("lordzurp", forge_repo: OrgDown)
    end

    @tag :tmp_dir
    test "a name the import would refuse is LISTED with its reason, not silently dropped" do
      # Keep inadmissible candidates visible with a reason; omission would look like a discovery failure.
      assert {:ok, [candidat]} =
               ProjectOnboard.deposit_candidates("lordzurp", forge_repo: BadName)

      assert candidat["source"] == "lordzurp/Mon_Projet"
      refute candidat["admissible"]
      assert candidat["reason"] =~ "kebab-case"
    end
  end

  describe "import_deposit : les refus d'admission, avant tout effet de bord" do
    @tag :tmp_dir
    test "un depot DEJA dans une org de catalogue n'est pas un depot", %{tmp: tmp} do
      assert {:error, {:source_already_enrolled, "fleet/vitrine", "fleet"}} =
               ProjectOnboard.import_deposit("fleet/vitrine", "web", opts(tmp))
    end

    @tag :tmp_dir
    test "un catalogue de destination absent est refuse", %{tmp: tmp} do
      assert {:error, {:catalogue_not_installed, "grominet", gestures}} =
               ProjectOnboard.import_deposit("lordzurp/mon-projet", "grominet", opts(tmp))

      assert gestures =~ "web"
    end

    @tag :tmp_dir
    test "un nom qui n'est pas owner/nom est refuse avant tout le reste", %{tmp: tmp} do
      assert {:error, {:not_a_repo_name, "pas-un-chemin"}} =
               ProjectOnboard.import_deposit("pas-un-chemin", "web", opts(tmp))
    end

    @tag :tmp_dir
    test "a PRIVATE deposit is refused by name, never cloned", %{tmp: tmp} do
      # Authenticated cloning can succeed on private sources; visibility must be checked explicitly.
      assert {:error, {:deposit_not_public, "lordzurp/secret"}} =
               ProjectOnboard.import_deposit(
                 "lordzurp/secret",
                 "web",
                 Keyword.put(opts(tmp), :forge_repo, PrivateSource)
               )
    end

    @tag :tmp_dir
    test "an unreadable visibility REFUSES — fail-closed, never assumed public", %{tmp: tmp} do
      assert {:error, {:deposit_visibility_unreadable, "lordzurp/mon-projet", _}} =
               ProjectOnboard.import_deposit(
                 "lordzurp/mon-projet",
                 "web",
                 Keyword.put(opts(tmp), :forge_repo, VisibilityDown)
               )
    end
  end

  describe "import : l'org vient du DEPOT, pas du premier catalogue installe" do
    @tag :tmp_dir
    test "un depot du SECOND catalogue passe les gardes d'org", %{tmp: tmp} do
      # Import must query the source owner's catalogue, even when it is not the first installed one.
      result =
        ProjectOnboard.import("web/vitrine",
          forge_users: RefuseUsers,
          forge_files: NotCatalogues,
          base_url: "http://forge.test",
          code_root: Path.join(tmp, "code"),
          workshop_root: Path.join(tmp, "workshop"),
          ops_root: Path.join(tmp, "ops")
        )

      refute match?({:error, {:not_in_org, _, _}}, result)

      # The subsequent forge refusal records which org was queried.
      assert {:error, {:catalogue_not_installed, _, _}} = result
      assert RefuseUsers.last_org() == "web"
    end
  end

  describe "migrate : le transfert forge ET le repointage local, ou rien" do
    @tag :tmp_dir
    test "les trois faces sortent pointees sur la nouvelle org", %{tmp: tmp} do
      dirs = Map.new(~w(code workshop ops), &{&1, face(tmp, &1)})

      assert {:ok, %{repo: "web/vitrine", from: "fleet/vitrine", faces: faces, absent: absent}} =
               ProjectOnboard.Migration.migrate("fleet/vitrine", "web", opts(tmp))

      assert length(faces) == 3
      assert absent == []

      for {_kind, dir} <- dirs do
        assert origin(dir) == "http://forge.test/web/vitrine.git"
      end
    end

    @tag :tmp_dir
    test "une face jamais ouverte ICI ne fait pas echouer une migration deja faite", %{tmp: tmp} do
      code = face(tmp, "code")

      assert {:ok, %{repo: "web/vitrine", faces: faces, absent: absent}} =
               ProjectOnboard.Migration.migrate("fleet/vitrine", "web", opts(tmp))

      assert origin(code) == "http://forge.test/web/vitrine.git"

      # Report actual repoints rather than claiming all three intended faces were changed.
      assert faces == [code]
      assert length(absent) == 2
      refute code in absent
    end
  end
end
