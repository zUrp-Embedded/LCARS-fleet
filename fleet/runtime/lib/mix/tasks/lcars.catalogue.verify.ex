defmodule Mix.Tasks.Lcars.Catalogue.Verify do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.Application): the orchestrator
  # `Fleet.Application.CatalogueVerify` is a sub-module of that boundary, so this task reaches it.
  use Boundary, classify_to: Fleet.Application

  @shortdoc "Proves a catalogue root the way the boot would — off the supervision path"

  @moduledoc """
  Standalone verification of a catalogue directory: the boot proof, run without starting a fleet.

      mix lcars.catalogue.verify <root>     # human report + exit 0/1
      mix lcars.catalogue.verify <root> -q  # exit code only

  `<root>` is a catalogue root — the directory that carries `catalogue.yaml` and the nine business
  trees. The task runs the SAME checks the daemon runs at boot, through the same functions
  (`Fleet.Application.CatalogueVerify`): manifest + api_version, both proven-good images, the canon
  spawn-proof, the card jury/step guards, the structural roles, and the escalation policies.

  It covers the catalogue, NEVER the deployment (no forge/token/credential guard — those are
  properties of a running fleet, not of a catalogue). It reads the root TAKEN WHOLE and ignores the
  fine per-tree overrides, which it states in a header: an operator who panachages a fine key can
  get a green here and a red boot, and the header is what makes that legible rather than a false
  green.

  The image face lives in the release, not here (`mix` does not ship in the image): the entrypoint
  calls the SAME `Fleet.Application.CatalogueVerify.verify/1` via a release `eval`. One truth, two
  doors.

  **Last revised**: 2026-08-01
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, aliases: [q: :quiet], switches: [quiet: :boolean])
    quiet? = Keyword.get(opts, :quiet, false)

    case args do
      [root] ->
        # `loadpaths`, NOT `app.config`: the latter evaluates `runtime.exs`, which demands the
        # deployment env (`FLEET_API_PORT` etc.) — the very deployment config this verifier exists to
        # stay clear of. loadpaths puts the compiled app on the code path (so `:code.priv_dir` and the
        # modules resolve) and applies the compile-time env, without a running fleet or its ports.
        _ = Mix.Task.run("loadpaths")
        report(Fleet.Application.CatalogueVerify.verify(root), quiet?)

      _ ->
        Mix.raise("usage: mix lcars.catalogue.verify <catalogue-root> [-q]")
    end
  end

  defp report({:ok, %{assumptions: assumptions}}, quiet?) do
    unless quiet? do
      print_assumptions(assumptions)
      Mix.shell().info("catalogue OK — every check the boot runs passed.")
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
