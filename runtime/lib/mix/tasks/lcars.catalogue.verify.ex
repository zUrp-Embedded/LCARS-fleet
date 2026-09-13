defmodule Mix.Tasks.Lcars.Catalogue.Verify do
  use Boundary, classify_to: Fleet.Application

  @shortdoc "Runs the boot's catalogue checks without starting the fleet"

  @moduledoc """
  Runs the catalogue checks used at boot without starting the fleet.

    mix lcars.catalogue.verify <root>
    mix lcars.catalogue.verify <root> -q  # suppress this task's report

  Failures exit 1. Quiet mode does not suppress the verifier's logs.
  Deployment credentials and per-tree overrides remain printed assumptions.
  The verifier publishes global images; see Fleet.Application.CatalogueVerify
  before reusing the VM. Success does not prove the entire boot will succeed.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, aliases: [q: :quiet], strict: [quiet: :boolean])

    quiet? = Keyword.get(opts, :quiet, false)

    # `strict:` et non `switches:` : une option inconnue (`--quite`) n'est pas un mot de plus, c'est
    # un appel que l'operateur n'a pas voulu. Refusee avec l'usage, jamais jetee en silence.
    case {args, invalid} do
      {[root], []} ->
        # Avoid runtime deployment configuration while loading compiled modules and priv paths.
        _ = Mix.Task.run("loadpaths")
        report(Fleet.Application.CatalogueVerify.verify(root), quiet?)

      {_, invalid} ->
        Mix.raise(
          "usage: mix lcars.catalogue.verify <catalogue-root> [-q]" <> unknown_options(invalid)
        )
    end
  end

  defp unknown_options([]), do: ""

  defp unknown_options(invalid),
    do: " — option(s) inconnue(s) : #{Enum.map_join(invalid, " ", &elem(&1, 0))}"

  defp report({:ok, %{assumptions: assumptions}}, quiet?) do
    unless quiet? do
      print_assumptions(assumptions)

      # Keep the coverage claim aligned with the release verifier.
      Mix.shell().info(
        "catalogue OK — les controles catalogue du boot passent (cf. hypotheses ci-dessus)."
      )
    end
  end

  defp report({:error, %{findings: findings, assumptions: assumptions}}, quiet?) do
    _ =
      unless quiet? do
        print_assumptions(assumptions)
        Mix.shell().error("catalogue REFUSED — #{length(findings)} check(s) failed:")

        for %{stage: stage, error: error} <- findings do
          Mix.shell().error("  ✗ #{stage}: #{error}")
        end
      end

    exit({:shutdown, 1})
  end

  defp print_assumptions(assumptions) do
    Mix.shell().info("— verifier assumptions —")
    for a <- assumptions, do: Mix.shell().info("  · #{a}")
    Mix.shell().info("")
  end
end
