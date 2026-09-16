defmodule Fleet.MCP.PodTools.Delegation.Scratchpad do
  @moduledoc """
  Appends project-bound notes in the workshop face behind the delegation gate.
  Local writes are authoritative for the receipt; commit/push is best effort.
  """

  require Logger

  alias Fleet.Credentials.ForgeIdentity
  alias Fleet.MCP.PodTools.Delegation.{Gate, Workshop}
  alias Fleet.Project.GitOps

  @scratch_file "scratchpad.md"
  # Count note headings rather than physical lines in multiline blocks.
  @scratch_nudge_at 150

  @doc """
  Appends one timestamped note, then attempts commit/push of workshop.
  One text argument avoids path/format choices while recording context that session
  compaction would lose. The tool only appends; manual triage can edit the mounted file.

  At #{@scratch_nudge_at} counted headings, the receipt asks for triage. Counting is
  based on #### lines (including any in note content), not authenticated note records.
  The workshop push preserves notes beyond the container without merging into product.
  A successful receipt does not prove publication.
  """
  @spec scratch(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def scratch(state, note) when is_binary(note) do
    # mcp.tools_gated requires the gate in this public entry point, before payload validation.
    with {:ok, %{repo: repo, role: role}} <- Gate.require_architect(state) do
      case String.trim(note) do
        "" -> {:error, :note_empty}
        trimmed -> scratch_write(repo, role, trimmed)
      end
    end
  end

  defp scratch_write(repo, role, note) do
    dir = Workshop.lot_workspace(repo)
    path = Path.join(dir, @scratch_file)

    if File.dir?(dir) do
      case File.write(path, scratch_block(role, note), [:append]) do
        :ok ->
          _ = scratch_publish(dir, repo, role)
          {:ok, scratch_receipt(path)}

        {:error, reason} ->
          {:error, {:scratch_write_failed, reason}}
      end
    else
      {:error, {:no_workshop_face, dir}}
    end
  end

  # A blank line before --- prevents a Setext heading. Use #### so manual triage can
  # group notes under ### headings without rewriting their blocks.
  #
  # LE ROLE EST DANS LE TITRE parce que le COMMIT ne peut pas le porter : il est signe par le
  # systeme des deux cotes (la garde du livrable refuserait sinon la livraison suivante faite depuis
  # cette face). Sans ce mot, une note relue trois semaines plus tard n'a aucun auteur.
  defp scratch_block(role, note) do
    {{y, mo, d}, {h, mi, _s}} = :calendar.local_time()

    stamp =
      :io_lib.format("~4..0B-~2..0B-~2..0B - ~2..0B:~2..0B", [y, mo, d, h, mi])
      |> IO.iodata_to_binary()

    "\n#### #{stamp} — #{role}\n\n#{String.trim(note)}\n\n---\n"
  end

  # Keep the local note on publication failure. Add/commit failures are logged here;
  # a returned push failure bypasses this else and its result is discarded by the caller.
  # The commit carries the scratchpad ALONE (pathspec); HEAD is pushed without isolation or
  # rollback, so commits already made on the face travel with it.
  defp scratch_publish(dir, repo, role) do
    branch = Fleet.Layout.workshop_branch()

    with :ok <- GitOps.run(["-C", dir, "add", "--", @scratch_file], auth: false),
         :ok <-
           GitOps.run(
             [
               "-C",
               dir,
               # Demandee a `ForgeIdentity`, jamais recopiee : c'est lui l'autorite du nom systeme.
               "-c",
               "user.name=#{ForgeIdentity.system_identity().name}",
               "-c",
               "user.email=#{ForgeIdentity.system_email()}",
               "commit",
               "-q",
               "-m",
               "chore(scratch): note d'atelier (#{role})\n\n" <>
                 ForgeIdentity.coauthor_trailer(role),
               # Le chemin est la PORTEE du commit : sans lui, la note emportait tout ce qui
               # etait indexe a cote, et un document partait sur la forge sous ce message-la.
               # Ce qu'un delegateur veut publier passe par `workshop_publish`, qui le nomme.
               "--",
               @scratch_file
             ],
             auth: false
           ) do
      GitOps.run(["-C", dir, "push", "origin", "HEAD:" <> branch], auth: true)
    else
      other ->
        Logger.warning(
          "Delegation: scratch note ECRITE mais non publiee (#{repo}) — #{inspect(other)} ; " <>
            "elle vit dans la face atelier locale et partira au prochain geste qui pousse"
        )

        other
    end
  end

  # Read failure yields zero, so the receipt count does not prove a successful reread.
  defp scratch_receipt(path) do
    notes =
      case File.read(path) do
        {:ok, c} -> Regex.scan(~r/^#### /m, c) |> length()
        _ -> 0
      end

    base = %{"ok" => true, "notes" => notes}

    if notes >= @scratch_nudge_at do
      Map.put(
        base,
        "next",
        "Le scratchpad porte #{notes} notes. Propose un tri a ton humain : ce qui reste a faire " <>
          "part au backlog, ce qui est specifie part en plans/, ce qui attend son jour de neige " <>
          "reste nomme, le reste se jette. Puis vide ce qui a ete range — l'append-only vaut pour " <>
          "l'ecriture au fil de l'eau, pas contre le menage."
      )
    else
      base
    end
  end
end
