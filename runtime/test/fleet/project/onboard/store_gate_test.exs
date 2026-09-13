defmodule Fleet.Project.Onboard.StoreGateTest do
  @moduledoc """
  Store guards use manifest identity for existing repositories and a reserved address for
  adoption's new destination. A missing manifest is admitted; unreadable is a separate refusal.
  Entry-point wiring is checked by source substrings, not complete import/migration runs.
  """
  use ExUnit.Case, async: true

  alias Fleet.Project.Onboard.Refute, as: ProjectOnboard

  @moduletag :tmp_dir

  # Manifest name matching owner identifies the store, regardless of repository basename.
  defmodule StoreFiles do
    def get_file("web/_catalogue", "catalogue.yaml", _fc),
      do: {:ok, %{content: "api_version: 1\nname: web\n", sha: "f00"}}

    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
  end

  # Same reserved-looking address, different declared catalogue: identity must decide.
  defmodule ImposterFiles do
    def get_file("web/_catalogue", "catalogue.yaml", _fc),
      do: {:ok, %{content: "api_version: 1\nname: autre-chose\n", sha: "f00"}}

    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, :not_found}
  end

  defmodule MuteFiles do
    def get_file(_repo, "catalogue.yaml", _fc), do: {:error, {:http, 503, "down"}}
  end

  describe "refute_store/2 — la question posee a un depot qui existe" do
    test "le magasin de son propre catalogue est REFUSE, et le refus nomme le bon geste" do
      assert {:error, {:repo_is_catalogue_store, "web/_catalogue", why}} =
               ProjectOnboard.refute_store("web/_catalogue", forge_files: StoreFiles)

      assert why =~ "STORE of the catalogue 'web'"
      assert why =~ "lcars catalogue install web"
    end

    test "un depot a l'ADRESSE d'un magasin qui declare un autre nom PASSE" do
      # Positive control against classifying stores by repository name alone.
      assert :ok = ProjectOnboard.refute_store("web/_catalogue", forge_files: ImposterFiles)
    end

    test "un depot ordinaire PASSE, en silence" do
      assert :ok = ProjectOnboard.refute_store("web/vitrine", forge_files: StoreFiles)
    end

    test "manifeste ILLISIBLE : refus NOMME comme illisible, jamais comme un magasin" do
      # Read failure must not be relabelled as a positive store identification.
      assert {:error, {:store_check_unreadable, "web/vitrine", why}} =
               ProjectOnboard.refute_store("web/vitrine", forge_files: MuteFiles)

      assert why =~ "unknown whether this repo is a catalogue's store"
      refute why =~ "STORE of the catalogue"
    end
  end

  describe "refute_store_address/2 — la question posee a un depot qui n'existe pas encore" do
    test "l'adresse du magasin est refusee, et le refus dit ce qui l'ecraserait" do
      store = Fleet.Catalogue.store_repo()

      assert {:error, {:store_address, full, why}} =
               ProjectOnboard.refute_store_address("web/#{store}", store)

      assert full == "web/#{store}"
      assert why =~ "force-pushes"
    end

    test "tout autre nom passe" do
      assert :ok = ProjectOnboard.refute_store_address("web/catalogue", "catalogue")
      assert :ok = ProjectOnboard.refute_store_address("web/vitrine", "vitrine")
    end
  end

  describe "LES TROIS PORTES sont cablees — une seule gardee est le defaut, pas le correctif" do
    # Inspect all family modules so moving an implementation does not hide its entry point.
    # Fixed 1400-character windows can include following functions; this is not control-flow proof.
    @src ["lib/fleet/project/onboard.ex" | Path.wildcard("lib/fleet/project/onboard/*.ex")]

    test "`import/2` interroge l'identite de sa cible" do
      assert door_preamble("import") =~ "refute_store(full_name, opts)"
    end

    test "`migrate/3` interroge l'identite de sa cible" do
      assert door_preamble("migrate") =~ "refute_store(full_name, opts)"
    end

    test "`adopt_project/2` refuse l'ADRESSE, parce qu'il n'y a rien a interroger" do
      corps = door_preamble("adopt_project")

      assert corps =~ "refute_store_address(full_name, name)"

      # A new destination has no manifest; probing it would admit a not_found and miss the reservation.
      refute corps =~ "refute_store(full_name"
    end

    defp door_preamble(verb) do
      motif = ~r/^  def #{verb}\(/m

      corps =
        for f <- @src, source = File.read!(f), Regex.match?(motif, source) do
          [_, body] = String.split(source, motif, parts: 2)
          String.slice(body, 0, 1400)
        end

      case corps do
        [body] -> body
        [] -> flunk("`def #{verb}(` introuvable dans la famille onboarding")
        n -> flunk("`def #{verb}(` defini #{length(n)} fois : le temoin ne sait pas lequel lire")
      end
    end
  end
end
