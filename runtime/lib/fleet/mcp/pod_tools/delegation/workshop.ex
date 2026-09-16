defmodule Fleet.MCP.PodTools.Delegation.Workshop do
  @moduledoc """
  Workshop face: root/workspace resolution for lots and scratchpad, and the PUBLICATION of what a
  delegator wrote there.

  A pod never pushes — `git_ops_denied: [push]` in every cap-profile, because publication is a
  system act. Before this delegation, the only thing that pushed the workshop face was a scratchpad
  note, whose commit swept along whatever was staged beside it: documents reached the forge as a
  SIDE EFFECT of the next note, or never (measured 2026-09-16). `publish/2` is that act, named: the
  runtime stages the face, commits it with the message the pod gives, and pushes.

  The commit carries the system identity on BOTH sides, and a `Co-authored-by` trailer naming the
  role that asked: the signature says the runtime published, the trailer says who wrote. It is a runtime commit on a shared face,
  and `Fleet.Workflow.DeliverableGate` does not judge a pure system commit as a producer's identity
  — an author/committer split would refuse the next delivery made from that face.
  """

  require Logger

  alias Fleet.Credentials.ForgeIdentity
  alias Fleet.MCP.PodTools.Delegation.Gate
  alias Fleet.Project.GitOps

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

  A clean face publishes nothing and says so — that is a state, not a failure. Local writes stay
  whatever happens: a push refused by the forge leaves the commit in place, and the next
  publication carries it. The receipt names the files as Git saw them, so a pod reads what it
  actually sent rather than what it meant to send.
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

  defp publish_face(repo, role, message) do
    dir = lot_workspace(repo)

    if File.dir?(dir) do
      with :ok <- GitOps.run(["-C", dir, "add", "-A", "--", "."], auth: false),
           {:ok, files} <- staged_files(dir) do
        publish_staged(dir, repo, role, message, files)
      end
    else
      {:error, {:no_workshop_face, dir}}
    end
  end

  defp publish_staged(_dir, _repo, _role, _message, []) do
    {:ok,
     %{
       "ok" => true,
       "published" => false,
       "why" =>
         "rien à publier : la face atelier est propre. Écris tes documents dans l'atelier du " <>
           "projet, puis rappelle-moi."
     }}
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
      {:ok, Map.merge(receipt(files, sha), pushed(dir, repo))}
    end
  end

  defp pushed(dir, repo) do
    branch = Fleet.Layout.workshop_branch()

    case GitOps.run(["-C", dir, "push", "origin", "HEAD:" <> branch], auth: true) do
      :ok ->
        %{"pushed" => true}

      other ->
        Logger.warning(
          "Delegation: atelier COMMITE mais non publie (#{repo}) — #{inspect(other)} ; " <>
            "le commit reste dans la face locale et partira a la prochaine publication"
        )

        %{
          "pushed" => false,
          "why" =>
            "commité localement, mais la forge n'a pas pris la publication — dis-le à ton humain " <>
              "et rappelle-moi plus tard : rien n'est perdu."
        }
    end
  end

  defp receipt(files, sha) do
    %{"ok" => true, "published" => true, "commit" => sha, "files" => files}
  end

  # Names as Git staged them, so the receipt cannot claim a file the commit does not carry.
  defp staged_files(dir) do
    case GitOps.read(["-C", dir, "diff", "--cached", "--name-only"], auth: false) do
      {:ok, out} -> {:ok, out |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}
      other -> other
    end
  end

  defp head_sha(dir), do: GitOps.read(["-C", dir, "rev-parse", "HEAD"], auth: false)
end
