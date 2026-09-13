defmodule Mix.Tasks.Lcars.Provenance.Verify do
  use Boundary, classify_to: Fleet.Workflow
  @shortdoc "Verifies local provenance JSON files against code commits"
  @moduledoc """
  Verifies local ops `provenance/*.json` files against the project's code repository.

    mix lcars.provenance.verify <project-name>
    mix lcars.provenance.verify <project-name> --ops-root /path --code-root /path

  Both project directories must exist. Verification failures exit nonzero;
  no JSON files is reported and succeeds. Git provenance refs are not enumerated
  or fetched, so an empty scan does not establish that no attestations exist.
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, invalid} =
      OptionParser.parse(argv, strict: [ops_root: :string, code_root: :string])

    # ⚠ UNE OPTION INCONNUE EST REFUSEE, PAS IGNOREE. Mesure du 2026-09-12 : l'usage disait
    # `--work-root` et `--projects-root` pendant que le parseur n'acceptait que `--ops-root` et
    # `--code-root` — un operateur qui tapait ce que la doc lui disait voyait son option JETEE en
    # silence, et la tache verifiait les racines PAR DEFAUT en pretendant avoir lu les siennes.
    case {args, invalid} do
      {[name], []} ->
        work_dir = Path.join(Keyword.get(opts, :ops_root, Fleet.Layout.ops_root()), name)

        project_dir =
          Path.join(Keyword.get(opts, :code_root, Fleet.Layout.code_root()), name)

        verify_all(name, work_dir, project_dir)

      {_, invalid} ->
        Mix.raise(
          "usage: mix lcars.provenance.verify <project-name> [--ops-root …] [--code-root …]" <>
            unknown_options(invalid)
        )
    end
  end

  defp verify_all(name, work_dir, project_dir) do
    unless File.dir?(work_dir), do: Mix.raise("ops repo not found: #{work_dir}")
    unless File.dir?(project_dir), do: Mix.raise("code repo not found: #{project_dir}")

    refs =
      Path.join(work_dir, "provenance")
      |> Path.join("*.json")
      |> Path.wildcard()
      |> Enum.map(&Path.join("provenance", Path.basename(&1)))
      |> Enum.sort()

    if refs == [] do
      Mix.shell().info("provenance.verify #{name}: no statement (nothing attested yet)")
    else
      results =
        Enum.map(refs, fn ref ->
          verdict =
            Fleet.Workflow.Provenance.Verifier.verify(ref,
              work_dir: work_dir,
              project_dir: project_dir
            )

          Mix.shell().info("  #{format(verdict)}  #{ref}")
          verdict
        end)

      fails = Enum.count(results, &(&1 != :ok))
      Mix.shell().info("provenance.verify #{name}: #{length(refs) - fails} ok, #{fails} fail")
      if fails > 0, do: Mix.raise("provenance verification FAILED (#{fails} statement(s))")
    end
  end

  defp unknown_options([]), do: ""

  defp unknown_options(invalid),
    do: " — option(s) inconnue(s) : #{Enum.map_join(invalid, " ", &elem(&1, 0))}"

  defp format(:ok), do: "ok  "
  defp format({:error, reason}), do: "FAIL #{inspect(reason)}"
end
