defmodule Mix.Tasks.Lcars.Catalogue.Roles do
  # Z4 — Mix task classified into the boundary of its subject (Fleet.Application): the orchestrator
  # `Fleet.Application.CatalogueRoles` is a sub-module of that boundary, so this task reaches it.
  use Boundary, classify_to: Fleet.Application

  @shortdoc "Prints the forge roster a catalogue declares — names, or the recipe's input JSON"

  @moduledoc """
  Lists the roles a catalogue declares a forge identity for: the accounts and tokens a deployment
  must create before that catalogue can work.

      mix lcars.catalogue.roles <root>            # one name per line
      mix lcars.catalogue.roles <root> --tfvars   # the forge recipe's input JSON

  `--tfvars` emits the four lists (`roles`, `writers`, `judges`, `externals`) in the shape tofu
  reads natively from a `*.auto.tfvars.json`. It emits DATA, never a recipe — see
  `Fleet.Application.CatalogueRoles` for why that line is where it is.

  Nothing but the payload on stdout: the consumer is a shell capturing it. Reasons go to stderr, so
  a failed run captures the empty string instead of a diagnostic parsed as a role name.

  Twin of the release doors (`eval_main/1` and `eval_tfvars/1`, reachable in an image as
  `docker run --rm IMAGE roles <root>` and `... roles-tfvars <root>`), for the two contexts that
  exist: a repo with `mix`, and a delivered image without it. Both call the same function.

  ReservedSeats are INCLUDED in `roles`: a seat cannot be spawned but still owns its account, and
  holding the name is the whole point.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, args, _} = OptionParser.parse(argv, switches: [tfvars: :boolean])

    case args do
      [root] ->
        _ = Mix.Task.run("loadpaths")

        if Keyword.get(opts, :tfvars, false),
          do: report_tfvars(Fleet.Application.CatalogueRoles.tfvars(root), root),
          else: report_names(Fleet.Application.CatalogueRoles.list(root), root)

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

  # Both exit; the specs say so. Without them dialyzer reports `no_return` on a helper whose ONLY
  # job is to end the task — the twin in `lcars.catalogue.verify` escapes it by having a sibling
  # clause that returns, which is an accident of shape, not a difference of intent.
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
