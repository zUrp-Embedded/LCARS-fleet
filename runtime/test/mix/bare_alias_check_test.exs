defmodule Mix.Tasks.Lcars.Contracts.BareAliasCheckTest do
  @moduledoc """
  Tests unresolved short module names used as values, aliases and Boundary exemptions.
  Synthetic files exercise the scanner; a separate case checks the real tree.
  These tests do not establish lexical-scope or alias-target validation.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Runtime

  @moduletag :tmp_dir

  # Filler files cross the file/reference population floors with resolvable names.
  defp arbre(fichiers, n_remplissage \\ 120) do
    root = Fleet.TestEnv.tmp_path("bare_alias")
    lib = Path.join(root, "lib/fleet")
    File.mkdir_p!(lib)

    Enum.each(1..n_remplissage//1, fn i ->
      File.write!(Path.join(lib, "filler_#{i}.ex"), """
      defmodule Filler#{i} do
        def a, do: {Enum, String}
      end
      """)
    end)

    Enum.each(fichiers, fn {nom, corps} -> File.write!(Path.join(lib, nom), corps) end)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  describe "contre le depot reel" do
    test "il passe, et sa note dit ce qu'il a mesure" do
      result = Runtime.check_bare_alias_resolves(File.cwd!())

      assert result.status == :pass
      assert result.note =~ "single-segment references over"
    end
  end

  describe "il mord" do
    test "un nom court passe comme VALEUR, sans alias — la forme exacte qui a coute 34 temoins" do
      root =
        arbre(%{
          "coupable.ex" => """
          defmodule Coupable do
            def a(impl), do: conforming(JamaisAliasee, impl)
            defp conforming(b, i), do: {b, i}
          end
          """
        })

      result = Runtime.check_bare_alias_resolves(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "coupable.ex" and &1 =~ "JamaisAliasee"))
    end

    test "le meme nom ALIASE ne dit plus rien — le mur mesure la resolution, pas l'orthographe" do
      root =
        arbre(%{
          "innocent.ex" => """
          defmodule Innocent do
            alias Mix.Tasks.Lcars.Contracts.Check.Runtime, as: JamaisAliasee
            def a(impl), do: conforming(JamaisAliasee, impl)
            defp conforming(b, i), do: {b, i}
          end
          """
        })

      assert Runtime.check_bare_alias_resolves(root).status == :pass
    end

    test "les `exports:` d'un `use Boundary` sont RELATIFS a la frontiere — pas des noms casses" do
      root =
        arbre(%{
          "domaine.ex" => """
          defmodule Domaine do
            use Boundary, deps: [], exports: [PasUnModuleGlobal]
          end
          """
        })

      assert Runtime.check_bare_alias_resolves(root).status == :pass
    end
  end

  describe "il refuse de repondre sur rien" do
    test "un arbre trop petit rend INSTRUMENT BROKEN, jamais un `pass`" do
      root = arbre(%{}, 3)
      result = Runtime.check_bare_alias_resolves(root)

      assert result.status == :fail
      assert Enum.any?(result.evidence, &(&1 =~ "INSTRUMENT BROKEN"))
    end
  end
end
