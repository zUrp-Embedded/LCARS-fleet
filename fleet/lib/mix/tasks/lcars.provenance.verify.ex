defmodule Mix.Tasks.Lcars.Provenance.Verify do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.Workflow).
  use Boundary, classify_to: Fleet.Workflow
  @shortdoc "Verify every provenance statement of a project (deterministic, non-LLM)"
  @moduledoc """
  Deterministic manual/CI face of `Fleet.Workflow.Provenance.Verifier`.

      mix lcars.provenance.verify <project-name>
      mix lcars.provenance.verify <project-name> --work-root /path --projects-root /path

  It checks every ops provenance statement against code commits and exits
  nonzero on incoherence. No statement is reported but remains valid.
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv, strict: [ops_root: :string, projects_root: :string])

    case args do
      [name] ->
        work_dir = Path.join(Keyword.get(opts, :ops_root, Fleet.Layout.ops_root()), name)

        project_dir =
          Path.join(Keyword.get(opts, :projects_root, Fleet.Layout.code_root()), name)

        verify_all(name, work_dir, project_dir)

      _ ->
        Mix.raise(
          "usage: mix lcars.provenance.verify <project-name> [--work-root …] [--projects-root …]"
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

  defp format(:ok), do: "ok  "
  defp format({:error, reason}), do: "FAIL #{inspect(reason)}"
end
