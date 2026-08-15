defmodule Fleet.Project.OnboardMigrateTest do
  @moduledoc """
  Migration of a project from one catalogue to another, SUCCESS path.

  The forge half is Gitea's (one transfer call, everything survives, the old URL 301s) and is
  measured on the bench. What belongs to LCARS is the other half: the three local faces must end up
  pointing at the new URL, and a face that was never opened here must NOT turn the migration into a
  failure — the transfer has already happened, and refusing afterwards would leave the two halves in
  disagreement.

  `async: false`: activating a second catalogue writes GLOBAL app env. An async file doing that
  leaks into whatever runs beside it.
  """
  use ExUnit.Case, async: false

  alias Fleet.Project.Onboard, as: ProjectOnboard

  @old_url "http://forge.test/fleet/vitrine.git"

  defmodule RefuseUsers do
    # Refuse l'humain, et ENREGISTRE l'org sur laquelle on l'a interroge — c'est le fait mesure.
    def user_exists?(_u, _fc), do: {:ok, true}
    def team_member?(org, _t, _u, _fc), do: {:ok, put_org(org)}

    defp put_org(org),
      do:
        (
          :persistent_term.put({__MODULE__, :org}, org)
          false
        )

    def last_org, do: :persistent_term.get({__MODULE__, :org}, nil)
  end

  defmodule TransferOk do
    # The seam stands where the network would be: `migrate` is called with the OLD name and must
    # thread the target catalogue as the new owner.
    def transfer_repo("fleet/vitrine", "web", _fc), do: {:ok, "web/vitrine"}
    # A deposit is public unless a test says otherwise: the private case has its own stub below.
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

    # `fleet` resolves to the BUNDLED root, manifest included; only the second one is a fixture.
    # The name comes from the manifest, never from the directory: a catalogue carries its identity.
    web = Path.join([home, "catalogues", "web"])
    File.mkdir_p!(Path.join(web, Fleet.Catalogue.rel(:cap_profiles)))
    File.write!(Path.join(web, "catalogue.yaml"), "api_version: 1\nname: web\n")

    File.write!(Path.join(home, "catalogues.active"), "fleet\nweb\n")

    Fleet.TestEnv.put_env_restoring(
      :lcars_fleet,
      :catalogue_active_declaration,
      Path.join(home, "catalogues.active")
    )

    Fleet.TestEnv.put_env_restoring(:lcars_fleet, :catalogue_install_dirs, [
      Path.join(home, "catalogues")
    ])

    %{tmp: tmp}
  end

  # A face as it exists on a box: a real repo whose `origin` still names the OLD owner.
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

  defp opts(tmp) do
    [
      forge_repo: TransferOk,
      base_url: "http://forge.test",
      code_root: Path.join(tmp, "code"),
      workshop_root: Path.join(tmp, "workshop"),
      ops_root: Path.join(tmp, "ops")
    ]
  end

  defmodule TwoOrgs do
    # `fleet` already carries `vitrine`; `web` is empty. The human has three personal repos.
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

      # `vitrine` exists in the `fleet` org. Importing takes a COPY and leaves the original with
      # its owner, so without this filter the same repo would be offered on every pass.
      assert Enum.map(candidats, & &1["source"]) == ["lordzurp/chifoumi", "lordzurp/mon-projet"]
      assert Enum.all?(candidats, & &1["admissible"])
    end

    @tag :tmp_dir
    test "an unreachable org REFUSES instead of returning a list that is too wide" do
      # A list too wide would offer to import what is already in — fail-loud, never fail-open.
      assert {:error, {:enrolled_scan_failed, "web", _}} =
               ProjectOnboard.deposit_candidates("lordzurp", forge_repo: OrgDown)
    end

    @tag :tmp_dir
    test "a name the import would refuse is LISTED with its reason, not silently dropped" do
      # The import is too late to learn the rule: the human has already pushed everything. And
      # dropping the candidate would be worse than refusing it — a repo that is simply absent from
      # the list looks like a repo the fleet cannot see, which sends the human debugging the forge.
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
      # Le reprendre par cette porte le clonerait puis le recreerait ailleurs, alors que les verbes
      # justes existent : import/2 pour l'adopter, migrate/3 pour le changer de catalogue.
      assert {:error, {:source_already_enrolled, "fleet/vitrine", "fleet"}} =
               ProjectOnboard.import_deposit("fleet/vitrine", "web", opts(tmp))
    end

    @tag :tmp_dir
    test "un catalogue de destination absent est refuse", %{tmp: tmp} do
      assert {:error, {:catalogue_not_active, "grominet", actives}} =
               ProjectOnboard.import_deposit("lordzurp/mon-projet", "grominet", opts(tmp))

      assert "web" in actives
    end

    @tag :tmp_dir
    test "un nom qui n'est pas owner/nom est refuse avant tout le reste", %{tmp: tmp} do
      assert {:error, {:not_a_repo_name, "pas-un-chemin"}} =
               ProjectOnboard.import_deposit("pas-un-chemin", "web", opts(tmp))
    end

    @tag :tmp_dir
    test "a PRIVATE deposit is refused by name, never cloned", %{tmp: tmp} do
      # There is no config lever forcing public repos (`DEFAULT_PRIVATE` does not exist in the
      # Gitea we run), so the door is the only place this can be stopped. And it must be ASKED:
      # this runtime's git carries the system token, so the clone of a private source would
      # SUCCEED and its content would land in a public org repo with nothing said.
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

  describe "import : l'org vient du DEPOT, pas du premier catalogue actif" do
    @tag :tmp_dir
    test "un depot du SECOND catalogue passe les gardes d'org", %{tmp: tmp} do
      # Avant : `org = opts[:org] || default_org()` rendait `fleet`, donc `web/vitrine` etait refuse
      # en {:not_in_org, "web/vitrine", "fleet"} — un depot d'un catalogue actif, refuse parce qu'il
      # n'etait pas dans le PREMIER. Et l'humain etait verifie contre l'org d'un autre catalogue.
      #
      # Ce test n'attend pas un succes : l'import va plus loin (forge, faces). Il epingle ce qui
      # doit NE PLUS arriver.
      result =
        ProjectOnboard.import("web/vitrine",
          forge_users: RefuseUsers,
          base_url: "http://forge.test",
          code_root: Path.join(tmp, "code"),
          workshop_root: Path.join(tmp, "workshop"),
          ops_root: Path.join(tmp, "ops")
        )

      refute match?({:error, {:not_in_org, _, _}}, result)
      refute match?({:error, {:catalogue_not_active, _, _}}, result)

      # La garde suivante est l'admission humaine, et elle est interrogee sur l'org DU DEPOT.
      assert {:error, {:human_not_provisioned, _, _}} = result
      assert RefuseUsers.last_org() == "web"
    end
  end

  describe "migrate : le transfert forge ET le repointage local, ou rien" do
    @tag :tmp_dir
    test "les trois faces sortent pointees sur la nouvelle org", %{tmp: tmp} do
      dirs = Map.new(~w(code workshop ops), &{&1, face(tmp, &1)})

      assert {:ok, %{repo: "web/vitrine", from: "fleet/vitrine", faces: faces, absent: absent}} =
               ProjectOnboard.migrate("fleet/vitrine", "web", opts(tmp))

      assert length(faces) == 3
      assert absent == []

      for {_kind, dir} <- dirs do
        assert origin(dir) == "http://forge.test/web/vitrine.git"
      end
    end

    @tag :tmp_dir
    test "une face jamais ouverte ICI ne fait pas echouer une migration deja faite", %{tmp: tmp} do
      # Only the code face exists: the two others were never opened on this box.
      code = face(tmp, "code")

      assert {:ok, %{repo: "web/vitrine", faces: faces, absent: absent}} =
               ProjectOnboard.migrate("fleet/vitrine", "web", opts(tmp))

      assert origin(code) == "http://forge.test/web/vitrine.git"

      # Le compte rendu dit ce qui a ETE fait, pas ce qui etait vise. Mesure sur banc le
      # 2026-08-11 : la porte annoncait trois faces repointees sur une boite ou les trois etaient
      # absentes — la moitie forge etait juste, et le rapport mentait.
      assert faces == [code]
      assert length(absent) == 2
      refute code in absent
    end
  end
end
