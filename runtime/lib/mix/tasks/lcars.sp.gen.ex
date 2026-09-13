defmodule Mix.Tasks.Lcars.Sp.Gen do
  alias Fleet.SPBuilder.Blocks

  use Boundary, classify_to: Fleet.SPBuilder

  @shortdoc "Compose per-role SPs: sp_builder/sp_blocks/ -> sp_builder/sp_drafts/agent-<role>-base.md"
  @moduledoc """
  Writes per-role system prompt drafts through Fleet.SPBuilder.Blocks.

    mix lcars.sp.gen
    mix lcars.sp.gen --catalogue /path/to/my-catalogue

  The default composes the bundled reference; --catalogue selects a root and
  requests confined generation. Blocks.audit!/2 checks prompt sources for the
  forge roster, including ReservedSeats. An absent map permits handwritten drafts.
  Generated files still need to be committed by the caller.
  """
  use Mix.Task

  # Fleet.Catalogue resolves system core defaults and target drafts.
  # In a Mix checkout, the priv symlink makes app_dir writes reach source files.
  @impl Mix.Task
  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:yaml_elixir)
    {opts, _rest, invalid} = OptionParser.parse(argv, strict: [catalogue: :string])

    # ⚠ UNE OPTION INCONNUE EST REFUSEE, PAS IGNOREE — et ici l'oubli COUTAIT. `--catalog x` (une
    # lettre de moins) tombait dans `invalid`, `invalid` etait jete, et la tache composait la
    # reference EMBARQUEE, `confined?: false`, en ecrivant dans le catalogue systeme : la faute de
    # frappe changeait l'ENDROIT ou la tache ecrit. Mesure du 2026-09-12.
    if invalid != [] do
      Mix.raise(
        "usage: mix lcars.sp.gen [--catalogue <root>] — option(s) inconnue(s) : " <>
          Enum.map_join(invalid, " ", &elem(&1, 0))
      )
    end

    case opts[:catalogue] do
      nil -> compose(false)
      root -> with_root(root, fn -> compose(true) end)
    end
  end

  # Restore catalogue_root for callers that reuse the VM.
  defp with_root(root, fun) do
    root = Path.expand(root)

    unless File.dir?(root) do
      Mix.raise("--catalogue #{root} is not a directory")
    end

    previous = Application.fetch_env(:lcars_fleet, :catalogue_root)
    Application.put_env(:lcars_fleet, :catalogue_root, root)

    try do
      fun.()
    after
      case previous do
        {:ok, value} -> Application.put_env(:lcars_fleet, :catalogue_root, value)
        :error -> Application.delete_env(:lcars_fleet, :catalogue_root)
      end
    end
  end

  # Bundled generation may write system mechanism drafts; --catalogue requests confinement.
  defp compose(confined?) do
    blocks = Fleet.Catalogue.sp_blocks_root()
    map = read_map(blocks)

    :ok = Blocks.audit!(catalogue_roles!(), map)

    if map == %{} do
      Mix.shell().info(
        "No sp-map.yaml under #{blocks} — nothing to compose. The catalogue audit passed: " <>
          "every role carries its own draft."
      )
    else
      roles =
        Blocks.generate!(blocks, Fleet.Catalogue.sp_drafts_root(), confined?: confined?)

      Mix.shell().info("Per-role SPs generated (#{length(roles)}): #{Enum.join(roles, ", ")}")
    end
  end

  # Handwritten catalogues need no map; callers requiring one use Blocks.role_map/1.
  defp read_map(blocks) do
    if blocks |> Path.join("sp-map.yaml") |> File.regular?() do
      Blocks.role_map(blocks)
    else
      %{}
    end
  end

  # Seats can own generated prompts even though they cannot spawn.
  defp catalogue_roles! do
    case Fleet.CapProfile.forge_roster() do
      {:ok, roster} -> Enum.map(roster, & &1.name)
      {:error, reason} -> Mix.raise("catalogue roles unreadable (#{inspect(reason)})")
    end
  end
end
