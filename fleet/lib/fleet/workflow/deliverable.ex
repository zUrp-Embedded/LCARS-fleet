defmodule Fleet.Workflow.Deliverable do
  @moduledoc """
  System publication boundary for pod deliverables. Payload and native-git modes
  differ only while materializing content; both pass the same hardened gate and
  bounded system-owned push.
  """

  require Logger

  alias Fleet.Workflow.{DeliverableGate, Git, PayloadGuard}

  @type mode :: :payload | :git_native

  @type opts :: %{
          required(:mode) => mode(),
          required(:workspace) => Path.t(),
          required(:base_sha) => String.t(),
          required(:allowed_emails) => [String.t()],
          optional(:remote) => String.t(),
          optional(:target_branch) => String.t(),
          optional(:push?) => boolean(),
          optional(:local_ref) => String.t(),
          optional(:coauthor_role) => String.t() | nil,
          optional(:files) => [map()],
          optional(:identity) => map(),
          optional(:message) => String.t(),
          optional(:add_paths) => [String.t()]
        }

  @type result :: %{commit_sha: String.t(), pushed?: boolean(), mode: mode()}

  # Git reads remain delegated to the bounded Git authority.

  @common_keys [:mode, :workspace, :base_sha, :allowed_emails]
  @payload_keys [:files, :identity, :message]
  @identity_keys [:author_name, :author_email, :committer_name, :committer_email]

  @doc """
  Publishes content through gate then push; gate failure prevents publication.

  ⚠ THE GATE IS A FLOOR, NOT A CLEARANCE, and this is the site where the difference matters: what
  passes here gets pushed to a repository. Its ancestry, identity and trailer checks are decidable;
  its secret scan matches known credential SHAPES on added text and cannot see a shapeless one --
  a Gitea token is 40 hex, indistinguishable from a SHA (scope on
  `DeliverableGate.scan_secrets/2`). Reading `{:ok, :verified}` as "no secret in
  this chain" is the one mistake this door invites, because it is the only door there is.
  """
  @spec publish(opts()) :: {:ok, result()} | {:error, term()}
  def publish(opts) when is_map(opts) do
    with :ok <- validate(opts),
         :ok <- materialize_content(opts),
         {:ok, :verified} <-
           DeliverableGate.verify(
             opts.workspace,
             opts.base_sha,
             opts.allowed_emails,
             Map.get(opts, :coauthor_role)
           ),
         {:ok, sha} <- head_sha(opts.workspace),
         {:ok, extra_refspecs} <- with_provenance(opts, sha),
         {:ok, pushed?} <- push_deliverable(opts, extra_refspecs) do
      {:ok, %{commit_sha: sha, pushed?: pushed?, mode: opts.mode}}
    end
  end

  # LA PREUVE PART AVEC LA BRIQUE, ET C'EST TOUT LE FIX (BL-6-43).
  #
  # Une attestation ecrite EN SECOND, sur une AUTRE face, APRES le PR et en best-effort, porte
  # trois proprietes qui sont toutes mauvaises : elle peut ne pas exister pour une brique PUBLIEE ;
  # elle peut exister pour un AUTRE sha que celui qu'on scelle ; et son absence est indiscernable de
  # son echec. Le sceau ne peut alors que gerer des consequences.
  #
  # Ici elle devient un objet git de l'espace de travail, sous une ref NOMMEE PAR LE SHA
  # (`refs/lcars/provenance/<sha>`), poussee dans le MEME `git push` que la branche. Deux
  # consequences, par construction et non par vigilance :
  #   - la ref ne peut pas manquer pour une brique publiee : si le push echoue, la branche n'est pas
  #     publiee non plus, donc il n'y a rien a attester ;
  #   - elle ne peut pas parler d'un autre commit : son NOM est le commit.
  #
  # Une ecriture d'attestation qui echoue FAIT ECHOUER la publication, et c'est delibere. « Jamais
  # une PR bloquee pour un fichier de trace » vaut quand la trace est un fichier de courtoisie sur
  # une autre face ; ici l'ecriture est LOCALE
  # (hash-object + update-ref, aucun reseau) — elle ne peut echouer que sur un depot casse, cas ou
  # publier serait pire.
  defp with_provenance(opts, sha) do
    case Map.get(opts, :provenance) do
      attrs when is_map(attrs) and map_size(attrs) > 0 ->
        with {:ok, json} <-
               Fleet.Workflow.Provenance.statement_json(Map.put(attrs, :livrable_sha, sha)),
             :ok <- Git.write_provenance(opts.workspace, sha, json) do
          ref = Git.provenance_ref(sha)
          {:ok, ["#{ref}:#{ref}"]}
        end

      _ ->
        {:ok, []}
    end
  end

  defp validate(opts) do
    with :ok <- check_keys(opts, @common_keys),
         :ok <- check_mode(opts.mode),
         :ok <- check_types(opts),
         :ok <- check_mode_keys(opts) do
      check_push_keys(opts)
    end
  end

  # Presence alone is insufficient at the publication boundary.
  defp check_types(opts) do
    cond do
      not is_binary(opts.workspace) ->
        {:error, {:bad_opt, {:workspace, opts.workspace}}}

      not is_binary(opts.base_sha) ->
        {:error, {:bad_opt, {:base_sha, opts.base_sha}}}

      # ⚠ TYPE N'EST PAS FORME, et ce champ part en INTERPOLATION dans quatre commandes git de la
      # porte (`"#{base_sha}..HEAD"` — log, name-only, trailer, secrets) plus le `merge-base` de
      # l'ancetre. Une valeur commencant par `-` y devient une OPTION de git, pas une revision. La
      # valeur nominale vient du pinning hors-pod (`ProjectResolver`, sortie de `git ls-remote`),
      # mais elle transite aussi par un payload de pod (`gate_base_sha` / `base_sha` du
      # `step_run_build`), et un champ qui traverse le pod ne se valide pas par sa provenance.
      # C'est ici le point de passage unique : cinq sites en aval, une seule porte.
      not Fleet.GitRef.valid?(opts.base_sha) ->
        {:error, {:bad_opt, {:base_sha, opts.base_sha}}}

      not (is_list(opts.allowed_emails) and Enum.all?(opts.allowed_emails, &is_binary/1)) ->
        {:error, {:bad_opt, {:allowed_emails, opts.allowed_emails}}}

      true ->
        :ok
    end
  end

  defp check_keys(opts, keys) do
    case Enum.reject(keys, &Map.has_key?(opts, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_opts, missing}}
    end
  end

  defp check_mode(m) when m in [:payload, :git_native], do: :ok
  defp check_mode(m), do: {:error, {:invalid_mode, m}}

  # Only payload mode supplies content fields.
  defp check_mode_keys(%{mode: :payload} = opts) do
    with :ok <- check_keys(opts, @payload_keys) do
      check_keys(opts.identity, @identity_keys)
    end
  end

  defp check_mode_keys(_opts), do: :ok

  # A push requires remote and validated source/target refs.
  defp check_push_keys(opts) do
    if push?(opts) do
      with :ok <- check_keys(opts, [:remote, :target_branch]),
           :ok <- check_ref(opts.target_branch) do
        check_ref(local_ref(opts))
      end
    else
      :ok
    end
  end

  # GitRef is the single ref-validation authority.
  defp check_ref(ref) do
    if Fleet.GitRef.valid?(ref), do: :ok, else: {:error, {:invalid_ref, ref}}
  end

  # PayloadGuard owns payload write security.
  defp materialize_content(%{mode: :payload} = opts) do
    with :ok <- PayloadGuard.apply_files(opts.workspace, opts.files),
         {:ok, _sha} <- Git.commit(commit_opts(opts)) do
      :ok
    end
  end

  # Native mode requires HEAD to advance; the shared gate catches rewrite.
  defp materialize_content(%{mode: :git_native} = opts) do
    head_advanced(opts.workspace, opts.base_sha)
  end

  # Keep git read failure distinct from an empty native deliverable.
  defp head_advanced(workspace, base_sha) do
    case Git.read_head_sha(workspace) do
      {:ok, sha} when sha != base_sha -> :ok
      {:ok, _same_as_base} -> {:error, :no_deliverable_commit}
      {:error, reason} -> {:error, {:head_read_failed, reason}}
    end
  end

  defp commit_opts(opts) do
    opts.identity
    |> Map.take(@identity_keys)
    |> Map.merge(%{
      workspace: opts.workspace,
      message: opts.message,
      add_paths: Map.get(opts, :add_paths, ["."])
    })
  end

  # The completer creates the target branch before publication.
  # Le refspec du livrable se construit ICI et pas plus haut : sans push, il n'y a pas de
  # `target_branch` a lire (mode local, cf. `check_push_keys`) — le calculer d'avance faisait lever
  # une `KeyError` sur un chemin qui ne pousse rien. Les refs d'attestation, elles, sont deja
  # ecrites localement : elles accompagnent le push quand il y en a un.
  defp push_deliverable(opts, extra_refspecs) do
    if push?(opts) do
      refspec = "#{local_ref(opts)}:#{opts.target_branch}"
      Git.push(opts.workspace, opts.remote, [refspec | extra_refspecs])
    else
      {:ok, false}
    end
  end

  defp push?(opts), do: Map.get(opts, :push?, true)
  defp local_ref(opts), do: Map.get(opts, :local_ref, "HEAD")

  # Delegated to bounded Git authority.
  defp head_sha(workspace), do: Git.read_head_sha(workspace)
end
