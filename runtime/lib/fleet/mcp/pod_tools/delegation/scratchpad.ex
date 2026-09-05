defmodule Fleet.MCP.PodTools.Delegation.Scratchpad do
  @moduledoc """
  SCRATCHPAD channel — the architect's running notes on a project, kept in the `workshop` face
  and published as a commit rather than held in a process.

  The gate is the DELEGATION one (`Gate.require_architect/1`): the notes belong to the project the
  channel is bound to, and there is no scratchpad outside a project.
  """

  require Logger

  alias Fleet.MCP.PodTools.Delegation.{Gate, Workshop}
  alias Fleet.Project.GitOps

  @scratch_file "scratchpad.md"
  # En NOTES. Une note occupe plusieurs lignes : compter les lignes reclamerait le tri cinq fois
  # trop tot.
  @scratch_nudge_at 150

  @doc """
  Appends one stamped note to the project's workshop scratchpad, commits and pushes it.

  THE REFLEX IS THE FEATURE. A pod's L0 — session-level, ephemeral, alive — is exactly what a
  compaction eats, and LCARS turned the vendor's own memory OFF for every pod
  (`autoMemoryEnabled: false`: siloed, useless to the fleet, doctrine pollution). What replaces it
  has to cost nothing at the moment of the thought: ONE argument, no path, no format, no decision
  about where things live. An architect who must choose a file at the instant it has an idea does
  not park the idea — measured on real architects, it writes its in-flight state into `backlog.md`
  under a `## en vol` section it invents, because that file is the only one that LOOKS like it
  accepts what happened.

  APPEND-ONLY IS A PROPERTY OF THE DOOR, NOT A PROMISE. This tool only knows how to add, so the
  discipline holds during the whole flow without anyone maintaining it. Cleaning is a separate,
  deliberate act: the architect has the face mounted RW and edits the file by hand at triage time.
  An absolute ban would end in a 50k-line file nobody can exploit, which is the same uselessness
  by the other door.

  THE NUDGE RIDES ON THE RETURN VALUE, and that is the whole mechanism. Past `#{@scratch_nudge_at}`
  NOTES the answer stops being a receipt and asks for a triage. An agent cannot NOT read what the
  tool it just called gave back — this is the only place in the system where a rule reaches it AT
  THE MOMENT OF THE GESTURE, instead of a spawn-time instruction that a compaction removes first.

  It PUSHES, and that is a change of contract for this face: `workshop` was declared "nothing
  pushes it on its own". Pushing an orphan branch that is never merged publishes nothing into the
  product — it makes the notes survive the container, which is the point of writing them.
  """
  @spec scratch(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def scratch(state, note) when is_binary(note) do
    # LA PORTE EST ICI, DANS CE CORPS, et pas un cran plus bas : le contrat `mcp.tools_gated` lit
    # l'AST et exige que la fonction de delegation appelee par le tool porte elle-meme son gate —
    # un tool dont la porte vit dans un helper prive est, pour lui, un tool sans porte. C'est la
    # bonne exigence : elle empeche qu'un refactor deplace la garde hors de vue sans que rien ne
    # le dise. Et autoriser AVANT de valider la charge utile est l'ordre juste de toute facon.
    with {:ok, %{repo: repo}} <- Gate.require_architect(state) do
      case String.trim(note) do
        "" -> {:error, :note_empty}
        trimmed -> scratch_write(repo, trimmed)
      end
    end
  end

  # La racine passe par `workshop_root/0` : une porte qui ecrit un chemin de production en dur ne
  # peut etre prouvee par aucun test.
  defp scratch_write(repo, note) do
    dir = Workshop.lot_workspace(repo)
    path = Path.join(dir, @scratch_file)

    if File.dir?(dir) do
      case File.write(path, scratch_block(note), [:append]) do
        :ok ->
          _ = scratch_publish(dir, repo)
          {:ok, scratch_receipt(path)}

        {:error, reason} ->
          {:error, {:scratch_write_failed, reason}}
      end
    else
      {:error, {:no_workshop_face, dir}}
    end
  end

  # Un bloc markdown par note — le fichier est lu dans un rendu, et la note garde sa mise en forme.
  #
  #     <ligne vide>
  #     #### AAAA-MM-JJ - hh:mm
  #     <ligne vide>
  #     la note
  #     <ligne vide>
  #     ---
  #
  # ⚠ LA LIGNE VIDE AVANT `---` EST PORTANTE. Colle sous du texte, `---` n'est pas une barre : c'est
  # un SOULIGNEMENT DE TITRE, et il transforme la derniere ligne de la note en `<h2>`. Le defaut ne
  # se voit qu'au rendu.
  #
  # `####` et pas `###` : au tri, les notes se rangent sous les titres `###` que l'architecte pose,
  # sans retoucher chaque bloc.
  defp scratch_block(note) do
    {{y, mo, d}, {h, mi, _s}} = :calendar.local_time()

    stamp =
      :io_lib.format("~4..0B-~2..0B-~2..0B - ~2..0B:~2..0B", [y, mo, d, h, mi])
      |> IO.iodata_to_binary()

    "\n#### #{stamp}\n\n#{String.trim(note)}\n\n---\n"
  end

  # Best-effort DELIBERE : une note ecrite mais non poussee est une note ecrite. Faire echouer le
  # tool sur un push rate apprendrait a l'agent que le geste est cher, et un geste cher n'est plus
  # un reflexe — c'est exactement la propriete qu'on achete ici.
  defp scratch_publish(dir, repo) do
    branch = Fleet.Layout.workshop_branch()

    with :ok <- GitOps.run(["-C", dir, "add", "--", @scratch_file], auth: false),
         :ok <-
           GitOps.run(
             [
               "-C",
               dir,
               # Demandee a `ForgeIdentity`, jamais recopiee : c'est lui l'autorite du nom systeme.
               "-c",
               "user.name=#{Fleet.Credentials.ForgeIdentity.system_identity().name}",
               "-c",
               "user.email=#{Fleet.Credentials.ForgeIdentity.system_email()}",
               "commit",
               "-q",
               "-m",
               "chore(scratch): note d'atelier"
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

  # On compte les TITRES, c'est-a-dire les notes. Compter les lignes rend le meme nombre tant
  # qu'une note vaut une ligne ; en blocs, cinq fois trop.
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
