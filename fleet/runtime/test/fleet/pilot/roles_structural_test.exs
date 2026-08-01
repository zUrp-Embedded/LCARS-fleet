defmodule Fleet.Pilot.RolesStructuralTest do
  @moduledoc """
  Resolution des roles STRUCTURELS par capability, et son refus des deux cotes.

  `async: false` — DELIBERE et load-bearing. Ces tests repointent `:fleet_cap_profile, :root_dir` et
  depublient l'image : deux etats GLOBAUX. En async ils ont fait tomber trois suites voisines
  (StepDispatcher, StepRunCompleter, StepRunConsumerGate) qui resolvent le producteur pendant ce
  temps-la. C'est la raison pour laquelle ce fichier est separe de `roles_test.exs`, qui reste async
  parce qu'il ne touche a rien de partage.
  """
  use ExUnit.Case, async: false

  alias Fleet.Pilot.Roles

  # Un defaut est une exigence qui a renonce a etre verifiee : avant, un catalogue sans producteur
  # bootait VERT et mourait au premier dispatch. Ces deux tests sont la seule raison pour laquelle
  # le litteral a ete retire.
  setup do
    prev = Application.get_env(:fleet_cap_profile, :root_dir)
    tmp = Path.join(System.tmp_dir!(), "roles-cat-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:fleet_cap_profile, :root_dir, tmp)

    on_exit(fn ->
      File.rm_rf(tmp)

      if prev,
        do: Application.put_env(:fleet_cap_profile, :root_dir, prev),
        else: Application.delete_env(:fleet_cap_profile, :root_dir)
    end)

    # L'image publiee court-circuiterait le disque : on la retire pour ce bloc.
    Fleet.CapProfile.Image.unpublish()
    {:ok, dir: tmp}
  end

  # Les fixtures DERIVENT d'un profil canon reel : `load/1` valide contre le schema, donc un YAML
  # minimal echouerait a charger et `roles_with_capability` — fail-closed par contrat — le compterait
  # comme ne declarant rien. Le test mesurerait alors le mauvais refus.
  @canon_dir Path.join(File.cwd!(), "priv/cap_profile/canon/cap-profiles")

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
    # Le cas `eng_hw` + `eng_sw`. La carte nomme son producteur par step (`role`, schema-required)
    # et le run le porte dans la branche `lcars/issue-N-<producer>` : exiger un singleton fleet-wide
    # refuserait la readiness a une fleet specialisee, pour une politique que personne n'a demandee.
    write_role!(dir, "eng-hw", ["producer"])
    write_role!(dir, "eng-sw", ["producer"])
    write_role!(dir, "sealer", ["exception_judge"])

    assert %{producers: ["eng-hw", "eng-sw"], gatekeeper: "sealer"} =
             Roles.resolve_structural_roles!()
  end

  test "…mais le repli de DERNIER RECOURS refuse de deviner lequel", %{dir: dir} do
    # `producer_role/0` n'est pas « qui produit » : c'est le repli d'un seul appelant, quand la
    # branche du run est illisible. La, avec deux producteurs, aucune reponse n'existe — et signer
    # sous le mauvais producteur est pire que le dire.
    write_role!(dir, "eng-hw", ["producer"])
    write_role!(dir, "eng-sw", ["producer"])

    assert_raise RuntimeError, ~r/LAST-RESORT path/, fn -> Roles.producer_role() end
  end

  test "deux scelleurs restent un refus : le singleton est PAR CONCEPTION", %{dir: dir} do
    write_role!(dir, "alpha", ["exception_judge"])
    write_role!(dir, "beta", ["exception_judge"])

    assert_raise RuntimeError, ~r/unique BY DESIGN/, fn -> Roles.gatekeeper_role() end
  end

  test "une capability legitimement multiple n'est PAS une erreur", %{dir: dir} do
    # `onboarder` est porte par architect ET starfleet dans le canon : l'unicite est une propriete
    # du concept APPELANT (le role structurel), pas du catalogue.
    write_role!(dir, "alpha", ["onboarder"])
    write_role!(dir, "beta", ["onboarder"])

    assert {:ok, ["alpha", "beta"]} == Fleet.CapProfile.roles_with_capability(:onboarder)
  end
end
