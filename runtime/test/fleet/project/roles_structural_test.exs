defmodule Fleet.Project.RolesStructuralTest do
  @moduledoc """
  Resolution par capability sur des profils temporaires derives du canon.
  async:false : le setup remplace les racines de catalogue et depublie l'image,
  deux etats globaux que la restauration seule n'isole pas des lecteurs concurrents.
  """
  use ExUnit.Case, async: false

  alias Fleet.CapProfile.Image
  alias Fleet.Project.Roles

  # Exercer les refus sans fournir d'override de role.
  setup do
    tmp = Fleet.TestEnv.tmp_path("roles-cat")
    File.mkdir_p!(tmp)
    # Isoler aussi la racine systeme pour ne pas ajouter des roles hors fixture.
    Fleet.Test.CatalogueIsolation.isolate!(tmp)

    # Retirer l'image pour mesurer le disque et restaurer l'image precedente a la sortie.
    published_before = Image.published()

    on_exit(fn ->
      File.rm_rf(tmp)

      case published_before do
        %{} = image -> Image.republish(image)
        _ -> :ok
      end
    end)

    Image.unpublish()
    {:ok, dir: tmp}
  end

  # Un profil canon garde la fixture schema-valide : un profil invalide mesurerait
  # un echec de chargement au lieu de l'ambiguite de capability voulue.
  @canon_dir Path.join(File.cwd!(), "priv/catalogue/cap_profile/cap-profiles")

  defp write_role!(dir, name, caps) do
    body =
      @canon_dir
      |> Path.join("engineer.yaml")
      |> File.read!()
      |> String.replace(~r/^  name: .*$/m, "  name: #{name}")
      |> String.replace(
        ~r/^  capabilities: \[.*\]$/m,
        "  capabilities: [#{Enum.join(caps, ", ")}]"
      )

    File.write!(Path.join(dir, "#{name}.yaml"), body)
  end

  test "aucun role ne declare la capability → refus nomme", %{dir: dir} do
    write_role!(dir, "someone", ["onboarder"])

    assert_raise RuntimeError, ~r/no catalogue role declares the producer capability/, fn ->
      Roles.producer_role()
    end
  end

  test "PLUSIEURS producteurs est un catalogue legitime — le boot l'accepte", %{dir: dir} do
    # Plusieurs producteurs sont valides au boot puisque la carte choisit par step.
    write_role!(dir, "eng-hw", ["producer"])
    write_role!(dir, "eng-sw", ["producer"])
    # La fixture met deux capabilities sur un profil ; ce resolveur ne verifie
    # pas la separation worker/judge des consommateurs.
    write_role!(dir, "sealer", ["exception_judge", "conflict_resolver"])
    write_role!(dir, "arbitre", ["project_delegate"])

    assert %{
             producers: ["eng-hw", "eng-sw"],
             gatekeeper: "sealer",
             conflict_resolver: "sealer",
             project_delegate: "arbitre"
           } = Roles.resolve_structural_roles!()
  end

  test "un catalogue SANS delegue est refuse au BOOT, plus au premier create_project", %{dir: dir} do
    # Le resolveur de boot doit detecter l'absence du delegue avant un appel d'onboarding.
    write_role!(dir, "eng", ["producer"])
    write_role!(dir, "sealer", ["exception_judge", "conflict_resolver"])

    assert_raise RuntimeError,
                 ~r/no catalogue role declares the project delegate capability/,
                 fn ->
                   Roles.resolve_structural_roles!()
                 end
  end

  test "deux delegues : le boot refuse, et il les NOMME", %{dir: dir} do
    write_role!(dir, "eng", ["producer"])
    write_role!(dir, "sealer", ["exception_judge", "conflict_resolver"])
    write_role!(dir, "arch-hw", ["project_delegate"])
    write_role!(dir, "arch-sw", ["project_delegate"])

    assert_raise RuntimeError, ~r/"arch-hw".*"arch-sw"/, fn ->
      Roles.resolve_structural_roles!()
    end
  end

  test "le motif d'unicite est celui du role, pas celui du scelleur recopie", %{dir: dir} do
    # Le motif d'unicite du delegue doit parler d'escalade, pas du signataire du merge.
    write_role!(dir, "arch-hw", ["project_delegate"])
    write_role!(dir, "arch-sw", ["project_delegate"])

    assert_raise RuntimeError, ~r/single addressee of a project escalation/, fn ->
      Roles.project_delegate_role()
    end
  end

  test "…mais le repli de DERNIER RECOURS refuse de deviner lequel", %{dir: dir} do
    # Le repli sans carte ni branche ne peut pas choisir parmi plusieurs producteurs.
    write_role!(dir, "eng-hw", ["producer"])
    write_role!(dir, "eng-sw", ["producer"])

    assert_raise RuntimeError, ~r/LAST-RESORT path/, fn -> Roles.producer_role() end
  end

  test "deux scelleurs restent un refus : le singleton est PAR CONCEPTION", %{dir: dir} do
    write_role!(dir, "alpha", ["exception_judge"])
    write_role!(dir, "beta", ["exception_judge"])

    assert_raise RuntimeError, ~r/unique BY DESIGN/, fn -> Roles.gatekeeper_role() end
  end

  # JG-025 : comparer disque et image avec un ReservedSeat effectivement indexe.
  # Le schema interdit deja spec sur ce type ; son filtre d'image rend l'exclusion
  # locale sans dependre uniquement de cet invariant voisin.
  test "JG-025: les deux regimes rendent la MEME reponse sur un catalogue portant un siege", %{
    dir: dir
  } do
    write_role!(dir, "alpha", ["exception_judge"])

    File.write!(
      Path.join(dir, "seat.yaml"),
      "kind: ReservedSeat\nmetadata:\n  name: vulcan\n  role_index: 8\n"
    )

    # Regime DISQUE (le setup a depublie l'image).
    disque = Fleet.CapProfile.roles_with_capability(:exception_judge)
    assert {:ok, ["alpha"]} == disque

    # Verifier que le siege est indexe avant d'observer son exclusion de la resolution.
    Image.publish!()
    on_exit(fn -> Image.unpublish() end)

    assert %{index: index} = Image.published()

    assert Map.has_key?(index, "vulcan"),
           "le siege doit etre dans l'index, sinon on ne teste rien"

    assert disque == Fleet.CapProfile.roles_with_capability(:exception_judge),
           "les deux branches de la meme fonction rendent deux reponses selon qu'une image est " <>
             "publiee ou non"
  end

  test "JG-025: L'INVARIANT QUI FERMAIT DEJA LA DIVERGENCE — un siege ne peut pas porter de spec",
       %{
         dir: dir
       } do
    # Temoin du schema qui empechait deja un siege de porter une capability.
    seat_with_spec = %{
      "kind" => "ReservedSeat",
      "metadata" => %{"name" => "vulcan", "role_index" => 8},
      "spec" => %{"capabilities" => ["exception_judge"]}
    }

    assert {:error, :invalid_schema} =
             Fleet.CapProfile.Schema.validate(seat_with_spec, :reserved_seat)

    _ = dir
  end

  test "une capability legitimement multiple n'est PAS une erreur", %{dir: dir} do
    # L'unicite appartient au resolveur structurel, pas a toute capability.
    # onboarder est utilise comme predicat sur le pod appelant.
    write_role!(dir, "alpha", ["onboarder"])
    write_role!(dir, "beta", ["onboarder"])

    assert {:ok, ["alpha", "beta"]} == Fleet.CapProfile.roles_with_capability(:onboarder)
  end

  test "le delegue per-projet est resolu par capability, exactement un", %{dir: dir} do
    # Delegate resolution shares the authority used by Architect and escalation callers.
    write_role!(dir, "arbitre", ["project_delegate"])
    assert "arbitre" == Roles.project_delegate_role()
  end

  test "deux delegues : ambiguite sur QUI arbitre, pas une specialisation", %{dir: dir} do
    # No step card selects a project delegate to disambiguate two holders.
    write_role!(dir, "arch-hw", ["project_delegate"])
    write_role!(dir, "arch-sw", ["project_delegate"])

    assert_raise RuntimeError, ~r/unique BY DESIGN/, fn -> Roles.project_delegate_role() end
  end
end
