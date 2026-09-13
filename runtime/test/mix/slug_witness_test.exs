defmodule Mix.Tasks.Lcars.SlugWitnessTest do
  @moduledoc """
  Synthetic directory tests for hidden-path traversal, empty scans, consecutive
  hyphen counts and rejection of an underscore-containing basename.

  These fixtures do not establish vendor behaviour or recover original cwd values.
  The first test calls the draining said/0 twice: its second refutation observes
  an empty mailbox, not the original output. Empty-scan wording is tested separately.
  The task succeeds on no witnesses; only a disputed name exits nonzero.
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
    # Exercise both recursive pod directories and the hidden .claude segment.
    witness(tmp, "pods/pod_alpha", "-home-alpha")

    run(["--root", tmp])

    assert said() =~ "1 temoin(s) d'accord"
    refute said() =~ "AUCUN TEMOIN"
  end

  test "ZERO witnesses is NOT a verdict — it says it measured nothing", %{tmp_dir: tmp} do
    run(["--root", tmp])

    out = said()
    assert out =~ "AUCUN TEMOIN"
    assert out =~ "ne mesure RIEN"
    refute out =~ "aucun temoin ne DISTINGUE"
  end

  test "a witness that DISCRIMINATES is counted as such", %{tmp_dir: tmp} do
    # Consecutive hyphens exercise the task's counting predicate.
    witness(tmp, "pods/pod_beta", "-home-beta")
    witness(tmp, "pods/pod_gamma", "-tmp-x--home-y")

    run(["--root", tmp])

    out = said()
    assert out =~ "2 temoin(s) d'accord"
    assert out =~ "1 exercant un cas DISCRIMINANT"

    refute out =~ "aucun temoin ne DISTINGUE"
  end

  test "a slug the mirror could not have produced is a DISAGREEMENT, and exits nonzero", %{
    tmp_dir: tmp
  } do
    # This synthetic name lies outside the mirror's output charset.
    witness(tmp, "pods/pod_delta", "-home-under_score")

    assert catch_exit(run(["--root", tmp])) == {:shutdown, 1}
    assert said() =~ "TEMOIN EN DESACCORD"
  end
end
