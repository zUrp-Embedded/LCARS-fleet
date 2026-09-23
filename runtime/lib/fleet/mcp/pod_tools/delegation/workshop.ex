defmodule Fleet.MCP.PodTools.Delegation.Workshop do
  @moduledoc """
  Workshop face: root/workspace resolution for lots and scratchpad, and the PUBLICATION of what a
  delegator wrote there.

  A producer never pushes — `git_ops_denied: [push]` in its cap-profile, because publication is a
  system act. Nothing published this face on PURPOSE: the runtime pushes it when onboarding
  scaffolds it, and a scratchpad note pushed HEAD, sweeping along whatever was committed beside it.
  A document therefore reached the forge as a SIDE EFFECT of the next note, or never (measured
  2026-09-16). `publish/2` is that act, named: the runtime stages the face, commits it with the
  message the pod gives, and pushes.

  The commit carries the system identity on BOTH sides, and a `Co-authored-by` trailer naming the
  role that asked: the signature says the runtime published, the trailer says who wrote. It is a runtime commit on a shared face,
  and `Fleet.Workflow.DeliverableGate` does not judge a pure system commit as a producer's identity
  — an author/committer split would refuse the next delivery made from that face.
  """

  require Logger

  alias Fleet.Credentials.ForgeIdentity
  alias Fleet.MCP.PodTools.Delegation.Gate
  alias Fleet.Project.GitOps
  alias Fleet.Workflow.Deliverable

  # Resolve the project's basename under workshop; this is a layout rule, not an authorization check.
  @doc false
  @spec lot_workspace(String.t()) :: String.t()
  def lot_workspace(repo), do: Path.join(root(), Fleet.Layout.project_name(repo))

  @doc false
  @spec root() :: String.t()
  def root,
    do: Application.get_env(:lcars_fleet, :mcp_workshop_root) || Fleet.Layout.workshop_root()

  @doc """
  Publishes the project's workshop face: stage everything, commit under `message`, push.

  LA MEME GARDE QUE POUR UN LIVRABLE court sur ce qui part (`Fleet.Workflow.DeliverableGate`) :
  secrets connus, fichiers de credentials par leur nom, chemins de gouvernance. C'est un chemin
  d'ecriture vers la forge declenche par un pod, et la face porte ce qu'un humain y a laisse — un
  `.env`, une cle, un PDF prive. Un refus DEFAIT le commit et garde les fichiers : rien n'est
  perdu, rien n'est publie.

  Une face propre ne publie rien et le dit — sauf si un commit precedent n'a pas pu etre pousse,
  auquel cas cette passe le pousse. Le recu nomme les fichiers tels que Git les a vus.
  """
  @spec publish(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def publish(state, message) when is_binary(message) do
    # mcp.tools_gated requires the gate in this public entry point, before payload validation.
    with {:ok, %{repo: repo, role: role}} <- Gate.require_architect(state) do
      case String.trim(message) do
        "" -> {:error, :message_empty}
        trimmed -> publish_face(repo, role, trimmed)
      end
    end
  end

  @doc """
  Brings the workshop face level with the forge before a local writer commits and pushes there.

  ⚠ THE FORGE ALSO MOVES WITHOUT A MERGE: the deck's deposit door commits into the ready room
  through the forge's API. Without this step the architect's next push is refused
  (non-fast-forward) until the next merge — silently for the scratchpad. A failure is logged and
  blocks nothing: the push that follows says so itself if it does not go through.
  """
  @spec align(String.t(), String.t()) :: :ok | :up_to_date | {:error, term()}
  def align(repo, dir) do
    case Fleet.Project.WorktreeSync.align_before_push(dir, Fleet.Layout.workshop_branch()) do
      {:error, reason} = err ->
        Logger.warning(
          "Delegation: workshop face of #{repo} could not follow the forge before writing " <>
            "(#{inspect(reason)}) — the push that follows may be refused"
        )

        err

      ok ->
        ok
    end
  end

  defp publish_face(repo, role, message) do
    dir = lot_workspace(repo)

    if File.dir?(dir) do
      _ = align(repo, dir)

      with :ok <- GitOps.run(["-C", dir, "add", "-A", "--", "."], auth: false),
           {:ok, files} <- staged_files(dir) do
        publish_staged(dir, repo, role, message, files)
      end
    else
      {:error, {:no_workshop_face, dir}}
    end
  end

  # Rien a indexer ne veut pas dire rien a publier : un commit qu'un push refuse a laisse en local
  # part ici, sinon il attendrait qu'une autre ecriture passe par hasard.
  defp publish_staged(dir, repo, _role, _message, []) do
    if en_avance?(dir) do
      {:ok, sha} = head_sha(dir)
      publie(dir, repo, [], sha)
    else
      {:ok,
       %{
         "ok" => true,
         "published" => false,
         "why" =>
           "rien à publier : la face atelier est propre, et la forge a déjà tout ce qu'elle porte. " <>
             "Écris tes documents dans l'atelier du projet, puis rappelle-moi."
       }}
    end
  end

  defp publish_staged(dir, repo, role, message, files) do
    identity = ForgeIdentity.system_identity()

    with :ok <-
           GitOps.run(
             [
               "-C",
               dir,
               "-c",
               "user.name=#{identity.name}",
               "-c",
               "user.email=#{identity.email}",
               "commit",
               "-q",
               "-m",
               # Le trailer dit QUI a ecrit ce que le systeme publie : le commit, lui, est signe par
               # le systeme des deux cotes, sinon la livraison suivante faite depuis cette face
               # serait refusee sur cette signature.
               message <> "\n\n" <> ForgeIdentity.coauthor_trailer(role)
             ],
             auth: false
           ),
         {:ok, sha} <- head_sha(dir) do
      publie(dir, repo, files, sha)
    end
  end

  # LE MEME RAIL QU'UN LIVRABLE, ET C'EST LE POINT : `Deliverable.publish/1` verifie (ascendance,
  # identite, secrets connus, fichiers de credentials, chemins de gouvernance) PUIS pousse. Ecrire
  # ici une seconde garde, c'est ecrire une garde qui divergera.
  #
  # Les identites admises sont celle du systeme : ce commit est le sien, sur une face partagee.
  defp publie(dir, repo, files, sha) do
    case Deliverable.publish(%{
           mode: :git_native,
           workspace: dir,
           base_sha: base_de(dir, sha),
           allowed_emails: [ForgeIdentity.system_email()],
           remote: "origin",
           target_branch: Fleet.Layout.workshop_branch(),
           push?: true
         }) do
      {:ok, %{pushed?: true}} ->
        {:ok, Map.merge(receipt(files, sha), %{"pushed" => true})}

      {:error, {:git_push_failed, _, _} = raison} ->
        {:ok, Map.merge(receipt(files, sha), push_manque(repo, raison))}

      {:error, {:git_push_exit, _} = raison} ->
        {:ok, Map.merge(receipt(files, sha), push_manque(repo, raison))}

      {:error, raison} ->
        defaire(dir, repo, sha, raison)
    end
  end

  # Sans parent (le premier commit d'une face), la plage est vide et la garde est vacante : c'est un
  # etat, pas une dispense — il n'y a rien avant ce commit a mettre en regard.
  defp base_de(dir, sha) do
    case GitOps.read(["-C", dir, "rev-parse", "--verify", "-q", sha <> "^"], auth: false) do
      {:ok, parent} -> parent
      _ -> sha
    end
  end

  # Un refus de la garde DEFAIT le commit et garde les fichiers : rien n'est perdu, rien n'est
  # publie, et le pod lit ce qui l'a arrete.
  defp defaire(dir, repo, sha, raison) do
    _ = GitOps.run(["-C", dir, "reset", "--mixed", "-q", base_de(dir, sha)], auth: false)

    Logger.warning(
      "Delegation: publication d'atelier REFUSEE par la garde (#{repo}, #{inspect(raison)}) — " <>
        "le commit est defait, les fichiers restent dans la face"
    )

    {:error, {:atelier_refuse, raison}}
  end

  defp push_manque(repo, raison) do
    Logger.warning(
      "Delegation: atelier COMMITE mais non publie (#{repo}) — #{inspect(raison)} ; " <>
        "le commit reste dans la face locale et part a la publication suivante"
    )

    %{
      "pushed" => false,
      "why" =>
        "commité localement, mais la forge n'a pas pris la publication — dis-le à ton humain " <>
          "et rappelle-moi plus tard : rien n'est perdu, la prochaine publication l'emporte."
    }
  end

  # 0 commit d'avance = la forge a tout ; un ref de suivi absent se lit comme « rien a pousser »,
  # et la publication suivante le dira.
  defp en_avance?(dir) do
    branch = Fleet.Layout.workshop_branch()

    case GitOps.read(["-C", dir, "rev-list", "--count", "origin/#{branch}..HEAD"], auth: false) do
      {:ok, n} -> n != "0"
      _ -> false
    end
  end

  defp receipt(files, sha) do
    %{"ok" => true, "published" => true, "commit" => sha, "files" => files}
  end

  # Names as Git staged them, so the receipt cannot claim a file the commit does not carry.
  # `-z` : sans lui, Git CITE les noms non-ASCII ou a espaces (`"caf\303\251.md"`), et le recu
  # nommerait un fichier qui n'existe pas sous ce nom-la.
  defp staged_files(dir) do
    case GitOps.read(["-C", dir, "diff", "--cached", "-z", "--name-only"], auth: false) do
      {:ok, out} -> {:ok, String.split(out, <<0>>, trim: true)}
      other -> other
    end
  end

  defp head_sha(dir), do: GitOps.read(["-C", dir, "rev-parse", "HEAD"], auth: false)
end
