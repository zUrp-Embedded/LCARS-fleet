defmodule Mix.Tasks.Lcars.ProjectTemplate.Sync do
  # Z4 — Mix task classified into the boundary of its subject (the onboarding forge surface).
  use Boundary, classify_to: Fleet.Pilot

  @shortdoc "Projects the catalogue project_template onto the forge template repo (fleet/project-template)"

  @moduledoc """
  Front for `Fleet.Project.TemplateSync` — the projection itself lives there.

  ⚠ IT WAS THE WHOLE THING, AND THAT WAS THE DEFECT. `mix` is a build tool: it is not in the
  runtime image, so the only poser of the template could not run on a deployed box, and nothing
  outside the bench ever called it. A production forge had no `project-template` and `Onboard`
  degraded to bare-create on every project. The body moved to a plain module, reachable by a
  release `eval` — this task stays because a dev tree is still the natural place to run it from.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("loadpaths")

    # `--catalogue <root>`, and it exists because the obvious spelling SILENTLY does the wrong
    # thing: `LCARS_CATALOGUE_ROOT` reaches `:lcars_fleet, :catalogue_root` through `config/runtime.exs`,
    # which a mix task never evaluates (no `app.start`, by design here). Setting the variable and
    # running this task therefore pushes the BUNDLED template and reports success — the deployment
    # ends up with a scaffolding from a catalogue it does not run, and nothing says so.
    # An explicit option cannot be set and ignored.
    case OptionParser.parse(args, switches: [catalogue: :string]) do
      {[catalogue: root], _, _} ->
        File.dir?(root) || Mix.raise("--catalogue: #{root} is not a readable directory")
        Application.put_env(:lcars_fleet, :catalogue_root, root)
        Mix.shell().info("project-template: catalogue root = #{root}")

      _ ->
        :ok
    end

    fc =
      case Fleet.Project.TemplateSync.forge_opts_from_env() do
        {:ok, fc} ->
          fc

        {:error, reason} ->
          Mix.raise("project-template: #{inspect(reason)} (source ~/.lcars/fleet_v2.env)")
      end

    case Fleet.Project.TemplateSync.standalone_sync(fc) do
      {:ok, repo} ->
        Mix.shell().info("project-template: #{repo} synced (content + template flag + labels)")

      {:error, reason} ->
        Mix.raise("project-template sync FAILED: #{inspect(reason)}")
    end
  end
end
