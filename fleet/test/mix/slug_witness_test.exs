defmodule Mix.Tasks.Lcars.SlugWitnessTest do
  @moduledoc """
  The witness that saw nothing, for as long as it existed.

  `mix lcars.slug_witness` confronts `SeedStore.slugify/1` — our frozen mirror of the vendor's
  slugification — with what the vendor ACTUALLY wrote under `<pod>/.claude/projects/<slug>`. Its
  whole moduledoc is a careful argument about not over-claiming a green.

  It found ZERO witnesses on every tree, always: `Path.wildcard/2` refuses to traverse a segment
  starting with a dot unless `match_dot: true`, and the path it walks contains `.claude`. Measured
  on a real tree: 0 with the default, 8 with the flag. The task then printed "0 témoins … rien ne
  contredit le miroir" — a reassuring sentence about a directory it never opened.

  These tests hold the two halves that failed together: it must SEE, and a count of zero must not
  read as a verdict.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defp run(args) do
    Mix.shell(Mix.Shell.Process)
    Mix.Tasks.Lcars.SlugWitness.run(args)
  after
    Mix.shell(Mix.Shell.IO)
  end

  defp said do
    Enum.map_join(collect(), "\n", fn {_kind, msg} -> msg end)
  end

  defp collect(acc \\ []) do
    receive do
      {:mix_shell, kind, [msg]} -> collect([{kind, msg} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp witness(root, rel_pod, slug) do
    dir = Path.join([root, rel_pod, ".claude", "projects", slug])
    File.mkdir_p!(dir)
    dir
  end

  test "it SEES a witness under a dot directory — the regression that made it blind", %{
    tmp_dir: tmp
  } do
    # Nested exactly like a real pod_dir: <root>/pods/pod_x/.claude/projects/<slug>. The `**` has to
    # cross `pods/pod_x` AND then a literal `.claude`, which is where the default flag stopped it.
    witness(tmp, "pods/pod_alpha", "-home-alpha")

    run(["--root", tmp])

    assert said() =~ "1 temoin(s) d'accord"
    refute said() =~ "AUCUN TEMOIN"
  end

  test "ZERO witnesses is NOT a verdict — it says it measured nothing", %{tmp_dir: tmp} do
    # The failure mode: a count of zero printed in the same breath as "rien ne contredit", which
    # reads as a measurement. An empty tree must produce the OTHER sentence, and on the error rail.
    run(["--root", tmp])

    out = said()
    assert out =~ "AUCUN TEMOIN"
    assert out =~ "ne mesure RIEN"
    refute out =~ "aucun temoin ne DISTINGUE"
  end

  test "a witness that DISCRIMINATES is counted as such", %{tmp_dir: tmp} do
    # `--` is the trace of the frozen algorithm: it does NOT collapse consecutive dashes, where a
    # naive slugify would. A tree of `-home-tetris` proves nothing; this one does.
    witness(tmp, "pods/pod_beta", "-home-beta")
    witness(tmp, "pods/pod_gamma", "-tmp-x--home-y")

    run(["--root", tmp])

    out = said()
    assert out =~ "2 temoin(s) d'accord"
    assert out =~ "1 exercant un cas DISCRIMINANT"
    # Having a discriminating witness silences the "nothing distinguishes" caveat — it no longer
    # applies, and printing it anyway would understate a real confrontation.
    refute out =~ "aucun temoin ne DISTINGUE"
  end

  test "a slug the mirror could not have produced is a DISAGREEMENT, and exits nonzero", %{
    tmp_dir: tmp
  } do
    # The only verdict a directory NAME alone permits: it must live in `slugify/1`'s image. An
    # underscore is outside the charset, so the vendor that wrote it ran another algorithm.
    witness(tmp, "pods/pod_delta", "-home-under_score")

    assert catch_exit(run(["--root", tmp])) == {:shutdown, 1}
    assert said() =~ "TEMOIN EN DESACCORD"
  end
end
