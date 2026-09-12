defmodule Mix.Tasks.Lcars.Catalogue.Verify do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.Application): the orchestrator
  # `Fleet.Application.CatalogueVerify` is a sub-module of that boundary, so this task reaches it.
  use Boundary, classify_to: Fleet.Application

  @shortdoc "Proves a catalogue root the way the boot would — off the supervision path"

  @moduledoc """
  Proves a catalogue directory with the daemon's own boot checks without starting a fleet.

      mix lcars.catalogue.verify <root>     # human report + exit 0/1
      mix lcars.catalogue.verify <root> -q  # exit code only

  The root is read whole. Deployment credentials and fine per-tree overrides are
  intentionally outside this proof and are printed as assumptions.
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

      # LA MEME PHRASE VIT A DEUX ENDROITS — ici et sur la porte release — donc corriger l'un sans
      # l'autre laisse le mensonge sur le chemin `mix`, celui que l'operateur lance A LA MAIN
      # (6-008). Elle ne dit PAS « every check the boot runs passed » : il suffit que le rail de
      # boot joue une garde `validate_*!` de plus que ce verificateur pour qu'un vert d'ici precede
      # un boot rouge.
      Mix.shell().info(
        "catalogue OK — les controles catalogue du boot passent (cf. hypotheses ci-dessus)."
      )
    end
  end

  defp report({:error, %{findings: findings, assumptions: assumptions}}, quiet?) do
    # `_ =` — the `unless` value (the comprehension's list) is discarded; the exit below is the point.
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
