defmodule Mix.Tasks.Lcars.Contracts.EvalDoorsStdoutCheckTest do
  @moduledoc """
  Synthetic-source tests for stdout-claim detection in eval functions and Mix tasks.
  Guarded heads, captures, stderr-only writes and private Mix helpers exercise
  distinct AST shapes. Population floors detect missing scan categories.

  Fixtures are inspected, not executed: these tests do not verify actual stream
  routing, claim-before-write ordering or branch reachability.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lcars.Contracts.Check.Runtime

  # Fill the total-door and Mix-task floors independently, keeping a recognised stdout writer.
  @eval_fillers 14
  @task_fillers 6

  defp filler(:conformes) do
    Enum.map_join(1..@eval_fillers, "\n", fn i ->
      "  def eval_filler#{i}(x) do\n    Fleet.ReleaseDoor.claim_stdout!()\n" <>
        "    IO.puts(x)\n  end\n"
    end)
  end

  defp filler(:muettes) do
    Enum.map_join(1..@eval_fillers, "\n", fn i ->
      "  def eval_filler#{i}(x) do\n    IO.puts(:stderr, x)\n  end\n"
    end)
  end

  # Mix.shell calls fill the task count but are not recognised as IO.puts writers.
  defp write_task_fillers(root, n) do
    File.mkdir_p!(Path.join(root, "lib/mix/tasks"))

    for i <- 1..n do
      File.write!(
        Path.join(root, "lib/mix/tasks/filler#{i}.ex"),
        "defmodule Mix.Tasks.Filler#{i} do\n  use Mix.Task\n" <>
          "  def run(_), do: Mix.shell().info(\"rien sur stdout\")\nend\n"
      )
    end
  end

  defp tree(extra, kind, opts) do
    root = Fleet.TestEnv.tmp_path("eval_doors")
    File.mkdir_p!(Path.join(root, "lib/fleet"))

    File.write!(
      Path.join(root, "lib/fleet/doors.ex"),
      "defmodule Doors do\n#{filler(kind)}\n#{extra}\nend\n"
    )

    write_task_fillers(root, Keyword.get(opts, :tasks, @task_fillers))

    case Keyword.get(opts, :task_source) do
      nil -> :ok
      src -> File.write!(Path.join(root, "lib/mix/tasks/lcars.sujet.ex"), src)
    end

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp check(extra, kind \\ :conformes, opts \\ []),
    do: Runtime.check_eval_doors_claim_stdout(tree(extra, kind, opts))

  describe "l'instrument repond de lui-meme d'abord" do
    test "trop peu de portes : INSTRUMENT BROKEN" do
      root = Fleet.TestEnv.tmp_path("eval_few")
      File.mkdir_p!(Path.join(root, "lib"))

      File.write!(
        Path.join(root, "lib/a.ex"),
        "defmodule A do\n  def eval_one, do: IO.puts(\"x\")\nend\n"
      )

      on_exit(fn -> File.rm_rf!(root) end)

      assert %{status: :fail, evidence: [ev]} = Runtime.check_eval_doors_claim_stdout(root)
      assert ev =~ "INSTRUMENT BROKEN"
    end

    test "AUCUNE porte n'ecrit sur stdout : INSTRUMENT BROKEN, jamais un vert propre" do
      assert %{status: :fail, evidence: [ev]} = check("", :muettes)
      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "no door writes to stdout"
    end

    test "les taches Mix disparaissent du scan : INSTRUMENT BROKEN" do
      # Keep enough eval doors so only the Mix-task population floor fails.
      assert %{status: :fail, evidence: [ev]} =
               check("", :conformes, tasks: 1)

      assert ev =~ "INSTRUMENT BROKEN"
      assert ev =~ "Mix task(s) matched"
    end
  end

  describe "la seconde famille — une tache Mix est une porte, et sa portee est le MODULE" do
    defp task(body) do
      "defmodule Mix.Tasks.Lcars.Sujet do\n  use Mix.Task\n#{body}end\n"
    end

    test "une tache qui ecrit sans reclamer est NOMMEE" do
      assert %{status: :fail, evidence: [ev]} =
               check("", :conformes,
                 task_source: task("  def run(_), do: IO.puts(\"charge utile\")\n")
               )

      assert ev =~ "lcars.sujet.ex"
    end

    test "⚠ L'ECRITURE DANS UN `defp` COMPTE — c'est le cas qui a motive ce mur" do
      # Private helpers in a Mix task must enter the file-wide scan.
      assert %{status: :fail, evidence: [ev]} =
               check("", :conformes,
                 task_source:
                   task(
                     "  def run(_), do: rapport(\"x\")\n" <>
                       "  defp rapport(x), do: IO.puts(x)\n"
                   )
               )

      assert ev =~ "lcars.sujet.ex"
    end

    test "reclamer dans `run/1` couvre l'ecriture faite dans un `defp`" do
      assert %{status: :pass} =
               check("", :conformes,
                 task_source:
                   task(
                     "  def run(_) do\n    Fleet.ReleaseDoor.claim_stdout!()\n" <>
                       "    rapport(\"x\")\n  end\n" <>
                       "  defp rapport(x), do: IO.puts(x)\n"
                   )
               )
    end

    test "une tache qui n'ecrit que par `Mix.shell()` n'est pas une ecrivante" do
      assert %{status: :pass} =
               check("", :conformes,
                 task_source: task("  def run(_), do: Mix.shell().info(\"bonjour\")\n")
               )
    end

    test "⚠ UN MODULE `Mix.Tasks.*` SANS `use Mix.Task` N'EST PAS UNE TACHE" do
      assert %{status: :pass} =
               check("", :conformes,
                 task_source:
                   "defmodule Mix.Tasks.Lcars.Sujet.Support do\n" <>
                     "  def rendu(x), do: IO.puts(x)\nend\n"
               )
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
      # A guarded definition wraps its head in :when; the scanner must unwrap it.
      assert %{status: :fail, evidence: [ev]} =
               check("  def eval_source(n) when is_binary(n) do\n    IO.puts(n)\n  end\n")

      assert ev =~ "eval_source"
    end

    test "la CAPTURE `&IO.puts/1` compte comme une ecriture" do
      assert %{status: :fail, evidence: [ev]} =
               check("  def eval_main do\n    Enum.each([1], &IO.puts/1)\n  end\n")

      assert ev =~ "eval_main"
    end
  end

  describe "ce que le mur laisse passer, et c'est voulu" do
    test "`IO.puts(:stderr, x)` n'est pas une ecriture sur stdout" do
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
