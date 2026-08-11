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

  defmodule TransferOk do
    # The seam stands where the network would be: `migrate` is called with the OLD name and must
    # thread the target catalogue as the new owner.
    def transfer_repo("fleet/vitrine", "web", _fc), do: {:ok, "web/vitrine"}
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
      :fleet_catalogue,
      :active_declaration,
      Path.join(home, "catalogues.active")
    )

    Fleet.TestEnv.put_env_restoring(:fleet_catalogue, :install_dirs, [
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

  describe "migrate : le transfert forge ET le repointage local, ou rien" do
    @tag :tmp_dir
    test "les trois faces sortent pointees sur la nouvelle org", %{tmp: tmp} do
      dirs = Map.new(~w(code workshop ops), &{&1, face(tmp, &1)})

      assert {:ok, %{repo: "web/vitrine", from: "fleet/vitrine", faces: faces}} =
               ProjectOnboard.migrate("fleet/vitrine", "web", opts(tmp))

      assert length(faces) == 3

      for {_kind, dir} <- dirs do
        assert origin(dir) == "http://forge.test/web/vitrine.git"
      end
    end

    @tag :tmp_dir
    test "une face jamais ouverte ICI ne fait pas echouer une migration deja faite", %{tmp: tmp} do
      # Only the code face exists: the two others were never opened on this box.
      code = face(tmp, "code")

      assert {:ok, %{repo: "web/vitrine"}} =
               ProjectOnboard.migrate("fleet/vitrine", "web", opts(tmp))

      assert origin(code) == "http://forge.test/web/vitrine.git"
    end
  end
end
