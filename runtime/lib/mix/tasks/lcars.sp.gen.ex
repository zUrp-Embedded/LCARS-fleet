defmodule Mix.Tasks.Lcars.Sp.Gen do
  alias Fleet.SPBuilder.Blocks

  # Z4 — Mix task classified into the boundary of its subject (Fleet.SPBuilder).
  use Boundary, classify_to: Fleet.SPBuilder

  @shortdoc "Compose per-role SPs: sp_builder/sp_blocks/ -> sp_builder/sp_drafts/agent-<role>-base.md"
  @moduledoc """
  Generates committed per-role system prompts through `Fleet.SPBuilder.Blocks`.

      mix lcars.sp.gen
      mix lcars.sp.gen --catalogue /path/to/my-catalogue

  Without `--catalogue` it composes the bundled reference. With it, ANY catalogue root — which is
  what turns the composer into a tool FOR the operator instead of a tool of this repository. A
  deployment rewriting the SP package in another language then has seven `core/` blocks to
  translate rather than eight SPs each carrying its own copy of the substrate.

  The composition is preceded by an AUDIT of the whole catalogue (`Blocks.audit!/2`): every role
  owes exactly one source for its SP — a block list or a draft, never both, never neither. Missing
  roles or blocks fail hard; drift of the generated flats is tested.
  """
  use Mix.Task

  # BOTH ends are catalogue trees, resolved through `Fleet.Catalogue` rather than by a relative
  # `Path.expand` from this file. `core/` lives in the system catalogue as a supersedable default,
  # so the two halves are read by ONE search path — which no hardcoded pair of paths can express.
  #
  # These resolve under `_build`, and the writes still land in the SOURCE tree: Mix symlinks
  # `_build/<env>/lib/<app>/priv` to it. That symlink is what makes a generator addressing the
  # app_dir correct rather than a way to write into a build artifact nobody commits.
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

  # Points the WHOLE catalogue layer at `root` for the duration, and restores what was there — the
  # same discipline as `Fleet.Application.CatalogueVerify.verify/1`, and for the same reason: the
  # root is global state, so a task that leaves it moved poisons everything after it in the same VM
  # (an `iex -S mix` session, a chained alias).
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

  # `confined?` is what `--catalogue` MEANS: compose THAT catalogue, and write nothing outside it.
  # Without the flag we are composing the bundled reference, whose map legitimately generates the
  # two mechanism drafts that ship in the system catalogue.
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

  # An ABSENT map is a legitimate catalogue, not an error: one that ships hand-written drafts owes
  # no blocks. `Blocks.role_map/1` stays fail-loud for the callers that require a map to exist (the
  # no-drift test would otherwise compare nothing against nothing); the choice belongs here, where
  # the absence is a shape rather than a fault.
  defp read_map(blocks) do
    if blocks |> Path.join("sp-map.yaml") |> File.regular?() do
      Blocks.role_map(blocks)
    else
      %{}
    end
  end

  # Seats INCLUDED: a ReservedSeat is not spawnable but still owns an SP when the catalogue
  # composes one for it (`vulcan` does), so leaving them out would let a map entry for a seat go
  # unaudited.
  defp catalogue_roles! do
    case Fleet.CapProfile.forge_roster() do
      {:ok, roster} -> Enum.map(roster, & &1.name)
      {:error, reason} -> Mix.raise("catalogue roles unreadable (#{inspect(reason)})")
    end
  end
end
