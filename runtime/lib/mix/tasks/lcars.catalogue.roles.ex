defmodule Mix.Tasks.Lcars.Catalogue.Roles do
  use Boundary, classify_to: Fleet.Application

  @shortdoc "Prints the forge roster a catalogue declares — names, or the recipe's input JSON"

  @moduledoc """
  Prints forge identities declared by a catalogue, including non-spawnable ReservedSeats.

    mix lcars.catalogue.roles <root>           # one name per line
    mix lcars.catalogue.roles <root> --tfvars  # JSON for *.auto.tfvars.json

  The JSON includes roles, writers, judges and externals; see Fleet.Roster for
  the projection. Release equivalents are `roles` and `roles-tfvars`.

  Shell consumers capture stdout as data. The task redirects the default Logger
  handler to stderr; roster errors and empty results exit 1 without a payload.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    # The installer parses stdout as JSON; redirect Logger before any work.
    Fleet.ReleaseDoor.claim_stdout!()

    {opts, args, _} = OptionParser.parse(argv, switches: [tfvars: :boolean])

    case args do
      [root] ->
        _ = Mix.Task.run("loadpaths")

        if Keyword.get(opts, :tfvars, false),
          do: report_tfvars(Fleet.Roster.tfvars(root), root),
          else: report_names(Fleet.Roster.list(root), root)

      _ ->
        Mix.raise("usage: mix lcars.catalogue.roles <catalogue-root> [--tfvars]")
    end
  end

  defp report_names({:ok, []}, root), do: empty(root)
  defp report_names({:ok, roles}, _root), do: for(role <- roles, do: IO.puts(role))
  defp report_names({:error, reason}, root), do: unreadable(reason, root)

  defp report_tfvars({:ok, %{"roles" => []}}, root), do: empty(root)
  defp report_tfvars({:ok, vars}, _root), do: IO.puts(Jason.encode!(vars, pretty: true))
  defp report_tfvars({:error, reason}, root), do: unreadable(reason, root)

  @spec empty(String.t()) :: no_return()
  defp empty(root) do
    Mix.shell().error("catalogue #{root}: no role declares a forge identity — nothing to enroll")
    exit({:shutdown, 1})
  end

  @spec unreadable(term(), String.t()) :: no_return()
  defp unreadable(reason, root) do
    Mix.shell().error("catalogue #{root}: roster unreadable (#{inspect(reason)})")
    exit({:shutdown, 1})
  end
end
