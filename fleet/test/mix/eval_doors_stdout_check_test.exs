defmodule Mix.Tasks.Lcars.Contracts.EvalDoorsStdoutCheckTest do
  @moduledoc """
  Le mur `runtime.eval_doors_claim_stdout`, prouvé contre des arbres FABRIQUÉS.

  Une porte `eval` a un flux de sortie CONTRACTUEL : `catalogue-source` rend `<dépôt> <branche>
  <sha>` que l'appelant donne à `git clone`, `roles-tfvars` rend du JSON redirigé dans un fichier
  que tofu lit. Le handler Logger par défaut écrit sur le MÊME flux, et
  `Fleet.ReleaseDoor.claim_stdout!/0` est le seul geste qui les sépare.

  ⚖ Mesure du 2026-08-23 sur un poste : `lcars catalogue install web-demo` a rendu
  `fatal: repository 'http://127.0.0.1:21000/.git/' not found`. La porte avait imprimé une ligne
  vide, un `Logger.info`, puis sa réponse ; `read -r repo branch sha` a lu la première.

  ## Pourquoi ces témoins-ci, et pas la porte

  La porte tourne sur l'arbre RÉEL, qui est propre depuis le correctif : elle ne peut prouver ni que
  `IO.puts(:stderr, …)` est correctement ignoré, ni que la capture `&IO.puts/1` est vue, ni qu'un
  instrument aveugle se dénonce. Un comportement qu'aucun témoin ne rougit est un comportement que
  le prochain lecteur supprimera en croyant simplifier.

  Le témoin de la forme `when` est le plus important du fichier : la première écriture de la sonde
  ne dépliait pas le `:when`, donc elle ne scannait AUCUN corps et rendait un vert parfait sur un
  arbre qui portait trois portes nues.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check

  # Le plancher d'instrument est de 6 portes, ET au moins une ecriture sur stdout : une population
  # muette ne se distingue pas d'un scanner casse. Les porteuses sont donc CONFORMES — elles
  # ecrivent et reclament — et l'appelant ajoute celle dont il veut parler.
  defp filler(:conformes) do
    Enum.map_join(1..6, "\n", fn i ->
      "  def eval_filler#{i}(x) do\n    Fleet.ReleaseDoor.claim_stdout!()\n" <>
        "    IO.puts(x)\n  end\n"
    end)
  end

  # Le meme plancher, mais sans aucune ecriture sur stdout — pour exercer le garde d'instrument.
  defp filler(:muettes) do
    Enum.map_join(1..6, "\n", fn i ->
      "  def eval_filler#{i}(x) do\n    IO.puts(:stderr, x)\n  end\n"
    end)
  end

  defp tree(extra, kind \\ :conformes) do
    root = Fleet.TestEnv.tmp_path("eval_doors")
    File.mkdir_p!(Path.join(root, "lib/fleet"))

    File.write!(
      Path.join(root, "lib/fleet/doors.ex"),
      "defmodule Doors do\n#{filler(kind)}\n#{extra}\nend\n"
    )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(extra, kind \\ :conformes),
    do: Check.check_eval_doors_claim_stdout(tree(extra, kind))

  describe "l'instrument repond de lui-meme d'abord" do
    test "moins de 6 portes : INSTRUMENT BROKEN" do
      root = Fleet.TestEnv.tmp_path("eval_few")
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(
        Path.join(root, "lib/a.ex"),
        "defmodule A do\n  def eval_one, do: IO.puts(\"x\")\nend\n"
      )

      on_exit(fn -> File.rm_rf!(root) end)

      assert %{status: :fail, evidence: [ev]} = Check.check_eval_doors_claim_stdout(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end

    test "AUCUNE porte n'ecrit sur stdout : INSTRUMENT BROKEN, jamais un vert propre" do
      # ⚠ C'EST LE CAS QU'A PRODUIT LA PREMIERE ECRITURE DE LA SONDE. Elle ne depliait pas le
      # `:when`, donc elle ne voyait aucun `IO.puts` — et rendait exactement le meme vert qu'un
      # arbre conforme, sur un arbre qui portait trois portes nues.
      assert %{status: :fail, evidence: [ev]} = check("", :muettes)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "no `eval*` function writes to stdout"
    end
  end

  describe "ce que le mur ATTRAPE" do
    test "une porte qui ecrit sans reclamer est NOMMEE" do
      assert %{status: :fail, evidence: [ev]} =
               check("  def eval_source(n) do\n    IO.puts(n)\n  end\n")

      assert ev =~ "eval_source"
      assert ev =~ "doors.ex"
    end

    test "la forme `when` est scannee — c'est celle de la porte qui a casse" do
      # ⚠ LE TEMOIN CENTRAL. `def f(x) when g` enveloppe sa tete dans un `:when` ; sans depliage, le
      # corps n'est jamais atteint. La porte reelle (`eval_source(name) when is_binary(name)`) porte
      # exactement cette forme, et c'est elle qui a laisse passer une ligne de log dans une URL.
      assert %{status: :fail, evidence: [ev]} =
               check("  def eval_source(n) when is_binary(n) do\n    IO.puts(n)\n  end\n")

      assert ev =~ "eval_source"
    end

    test "la CAPTURE `&IO.puts/1` compte comme une ecriture" do
      # `Enum.each(lines, &IO.puts/1)` est la forme de `eval_main/0` : un appel n'apparait nulle
      # part dans l'AST, seule la capture le trahit.
      assert %{status: :fail, evidence: [ev]} =
               check("  def eval_main do\n    Enum.each([1], &IO.puts/1)\n  end\n")

      assert ev =~ "eval_main"
    end
  end

  describe "ce que le mur laisse passer, et c'est voulu" do
    test "`IO.puts(:stderr, x)` n'est pas une ecriture sur stdout" do
      # Les refus d'une porte partent sur stderr par contrat — les compter ferait exiger le geste
      # d'une porte qui n'ecrit jamais le flux qu'il protege.
      assert %{status: :pass} =
               check("  def eval_source(n) do\n    IO.puts(:stderr, n)\n  end\n")
    end

    test "une porte qui ecrit ET reclame passe" do
      assert %{status: :pass} =
               check(
                 "  def eval_source(n) when is_binary(n) do\n" <>
                   "    Fleet.ReleaseDoor.claim_stdout!()\n    IO.puts(n)\n  end\n"
               )
    end

    test "une fonction qui ne s'appelle pas `eval*` n'est pas une porte" do
      assert %{status: :pass} = check("  def render(n) do\n    IO.puts(n)\n  end\n")
    end
  end
end
