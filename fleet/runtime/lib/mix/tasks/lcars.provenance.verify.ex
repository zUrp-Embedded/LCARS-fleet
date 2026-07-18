defmodule Mix.Tasks.Lcars.Provenance.Verify do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.Workflow).
  use Boundary, classify_to: Fleet.Workflow
  @shortdoc "Verify every provenance statement of a project (deterministic, non-LLM)"
  @moduledoc """
  Deterministic verification of a project's provenance triplets — the manual/CI face of
  `Fleet.Workflow.Provenance.Verifier` (brief: `beyond_#6/BRIEF-provenance-verifier.md`).

      mix lcars.provenance.verify <project-name>
      mix lcars.provenance.verify <project-name> --work-root /path --projects-root /path

  Walks `provenance/*.json` in the project's work/ops repo (`<work_root>/<name>`),
  verifies each statement against the CODE repo (`<projects_root>/<name>` — the
  deliverable and base commits live there), prints one verdict per statement, and exits
  non-zero on the first failing batch. No statement at all = a loud note, exit 0 (a
  fresh project has nothing to attest yet — absence is not incoherence).

  Phase 1 tool: NOT wired as a hard gate (Phase 2 = a separate user decision).

  **Last revised**: 2026-07-18
  """
  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} =
      OptionParser.parse(argv, strict: [work_root: :string, projects_root: :string])

    case args do
      [name] ->
        work_dir = Path.join(Keyword.get(opts, :work_root, Fleet.Layout.work_root()), name)
        project_dir = Path.join(Keyword.get(opts, :projects_root, Fleet.Layout.projects_root()), name)
        verify_all(name, work_dir, project_dir)

      _ ->
        Mix.raise("usage: mix lcars.provenance.verify <project-name> [--work-root …] [--projects-root …]")
    end
  end

  defp verify_all(name, work_dir, project_dir) do
    unless File.dir?(work_dir), do: Mix.raise("work/ops repo not found: #{work_dir}")
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
          verdict = Fleet.Workflow.Provenance.Verifier.verify(ref, work_dir: work_dir, project_dir: project_dir)
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
