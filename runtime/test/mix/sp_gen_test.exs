defmodule Mix.Tasks.Lcars.SpGenTest do
  @moduledoc """
  L'ENVELOPPE de `mix lcars.sp.gen`, pas la composition.

  La composition vit dans `Fleet.SPBuilder.Blocks` (86 % couvert, plus le temoin de non-derive qui
  compare le compose au commite). Ce que personne ne mesurait : le NOM de la commande, le refus
  d'une racine qui n'en est pas une, la RESTAURATION de `catalogue_root` — la racine est un etat
  global du VM, et une tache qui la laisse deplacee empoisonne tout ce qui suit — et le refus
  d'une option inconnue. Ce dernier COUTAIT : `--catalog x` etait jete en silence et la tache
  composait la reference EMBARQUEE en ecrivant dans le catalogue systeme. Trouve en ecrivant ce
  fichier (2026-09-12).

  ⚠ AUCUN TEMOIN ICI NE COMPOSE SANS `--catalogue` : ce chemin ecrit dans `priv/` du depot.

  Decision 3 du lot E6, option B (`42-DECISIONS.md`).

  async: false — `Mix.shell/1` et `catalogue_root` sont globaux au noeud.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Lcars.Sp.Gen

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    previous = Application.fetch_env(:lcars_fleet, :catalogue_root)

    on_exit(fn ->
      case previous do
        {:ok, v} -> Application.put_env(:lcars_fleet, :catalogue_root, v)
        :error -> Application.delete_env(:lcars_fleet, :catalogue_root)
      end

      # Meme discipline que `catalogue_verify_test.exs` : rien de ce que la couche catalogue a pu
      # publier pendant une composition sous `--catalogue` ne survit a ce fichier.
      Fleet.CapProfile.Image.unpublish()
      Fleet.SPBuilder.Image.unpublish()
      Fleet.Workflow.Loader.unpublish_all_images()
    end)

    :ok
  end

  describe "le NOM de la commande" do
    test "`mix lcars.sp.gen` resout vers CE module" do
      assert Mix.Task.get("lcars.sp.gen") == Gen
      assert Mix.Task.task_name(Gen) == "lcars.sp.gen"
    end
  end

  describe "l'usage" do
    test "une option INCONNUE est refusee et nommee — `--catalog` sans son e ne compose RIEN" do
      assert_raise Mix.Error, ~r/option\(s\) inconnue\(s\) : --catalog\b/, fn ->
        Gen.run(["--catalog", "/x"])
      end

      # ⚠ ET RIEN N'A ETE COMPOSE : la boite est vide. C'est la moitie qui compte — avant, cet
      # appel imprimait « Per-role SPs generated » apres avoir ecrit dans le catalogue systeme.
      refute_received {:mix_shell, _, _}
    end

    test "`--catalogue` sur ce qui n'est pas un repertoire est refuse en le nommant" do
      absent = Fleet.TestEnv.tmp_path("sp_gen_absent")

      assert_raise Mix.Error, ~r/--catalogue .*sp_gen_absent.* is not a directory/, fn ->
        Gen.run(["--catalogue", absent])
      end
    end
  end

  describe "la racine est un etat GLOBAL, et la tache la rend comme elle l'a prise" do
    test "apres `--catalogue <dir>`, `catalogue_root` est celle d'avant — meme quand la composition a rendu" do
      dir = Fleet.TestEnv.tmp_path("sp_gen_vide")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      Application.put_env(:lcars_fleet, :catalogue_root, "/racine/d-avant")
      Gen.run(["--catalogue", dir])

      assert Application.fetch_env(:lcars_fleet, :catalogue_root) == {:ok, "/racine/d-avant"}
    end

    test "et quand elle n'etait PAS posee, elle ne l'est toujours pas apres" do
      dir = Fleet.TestEnv.tmp_path("sp_gen_vide2")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      Application.delete_env(:lcars_fleet, :catalogue_root)
      Gen.run(["--catalogue", dir])

      assert Application.fetch_env(:lcars_fleet, :catalogue_root) == :error
    end
  end
end
