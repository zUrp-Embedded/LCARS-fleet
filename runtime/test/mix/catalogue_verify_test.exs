defmodule Mix.Tasks.Lcars.CatalogueVerifyTest do
  @moduledoc """
  L'ENVELOPPE de `mix lcars.catalogue.verify`, pas la logique du verificateur.

  La logique vit dans `Fleet.Application.CatalogueVerify` et ses temoins. Ce que personne ne
  mesurait : le NOM de la commande (lecon du lot B — `mix lcars.test_view` pendant que la doc
  disait `mix lcars.test.view`, et le temoin appelait le module), l'usage, le code de sortie, et le
  contrat de `-q` : « exit code only ».

  Decision 3 du lot E6, option B (`42-DECISIONS.md`).

  async: false — `Mix.shell/1` est global au noeud, et `CatalogueVerify.verify/1` PUBLIE les images
  du catalogue qu'il prouve dans `:persistent_term`.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lcars.Catalogue.Verify

  @catalogue Application.app_dir(:lcars_fleet, "priv/catalogue")

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    # ⚠ LES IMAGES PUBLIEES SONT RETIREES EN SORTANT, comme `Fleet.Application.CatalogueVerifyTest`
    # le fait. Mesure du 2026-09-13 (seed 638244) : sans ce retrait, l'image du catalogue embarque
    # restait dans `:persistent_term`, et `Fleet.Spawner.CanonProofTest` — qui isole sa racine
    # par l'env et attend « EMPTY » — lisait l'IMAGE, prouvait les vrais roles sous une racine
    # vide, et tombait sur `modop_bundle_missing`. Un temoin vert seul, rouge dans la suite, selon
    # l'ordre : la fuite d'un etat global que ce chantier a passe une journee a chasser ailleurs.
    on_exit(fn ->
      Fleet.CapProfile.Image.unpublish()
      Fleet.SPBuilder.Image.unpublish()
      Fleet.Workflow.Loader.unpublish_all_images()
    end)

    :ok
  end

  # Vide la boite : une fois par temoin, liee a une variable.
  defp mix_said(acc \\ []) do
    receive do
      {:mix_shell, kind, [msg]} -> mix_said([{kind, msg} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "le NOM de la commande" do
    test "`mix lcars.catalogue.verify` resout vers CE module" do
      assert Mix.Task.get("lcars.catalogue.verify") == Verify
      assert Mix.Task.task_name(Verify) == "lcars.catalogue.verify"
    end
  end

  describe "l'usage — un mauvais appel refuse fort, et dit quoi taper" do
    test "aucun argument, ou deux → Mix.raise avec l'usage" do
      assert_raise Mix.Error, ~r/usage: mix lcars\.catalogue\.verify/, fn -> Verify.run([]) end

      assert_raise Mix.Error, ~r/usage: mix lcars\.catalogue\.verify/, fn ->
        Verify.run(["a", "b"])
      end
    end

    test "une option INCONNUE est refusee et nommee, pas jetee en silence" do
      # `switches:` (non strict) laissait passer `--quite` : l'operateur croyait avoir demande le
      # mode silencieux et lisait le rapport entier. `strict:` la refuse.
      assert_raise Mix.Error, ~r/option\(s\) inconnue\(s\) : --quite/, fn ->
        Verify.run([@catalogue, "--quite"])
      end
    end
  end

  describe "le code de sortie et les flux" do
    test "une racine qui n'existe pas → exit 1, et le refus est sur le flux d'ERREUR" do
      assert {:shutdown, 1} = catch_exit(Verify.run([Fleet.TestEnv.tmp_path("cat_absente")]))

      said = mix_said()
      assert Enum.any?(said, fn {kind, msg} -> kind == :error and msg =~ "catalogue REFUSED" end)
    end

    test "`-q` sur un refus : exit 1 et RIEN d'imprime — « exit code only » est le contrat du moduledoc" do
      assert {:shutdown, 1} =
               catch_exit(Verify.run([Fleet.TestEnv.tmp_path("cat_absente"), "-q"]))

      assert mix_said() == []
    end

    test "le catalogue embarque passe : pas d'exit, et le rapport dit ce qu'il PROUVE et ce qu'il SUPPOSE" do
      assert :ok = Verify.run([@catalogue])

      said = mix_said()
      assert Enum.any?(said, fn {_, msg} -> msg =~ "verifier assumptions" end)
      assert Enum.any?(said, fn {kind, msg} -> kind == :info and msg =~ "catalogue OK" end)
      refute Enum.any?(said, fn {kind, _} -> kind == :error end)
    end
  end
end
