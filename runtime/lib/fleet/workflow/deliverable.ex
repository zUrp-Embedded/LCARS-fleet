defmodule Fleet.Workflow.Deliverable do
  @moduledoc """
  Publication sequence for payload and native-git deliverables: materialize, verify HEAD,
  optionally write provenance, then push through the system Git authority.
  No workspace lock or rollback spans these operations; callers must control concurrent writers.
  """

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

  @common_keys [:mode, :workspace, :base_sha, :allowed_emails]
  @payload_keys [:files, :identity, :message]
  @identity_keys [:author_name, :author_email, :committer_name, :committer_email]

  @doc """
  Validates options, materializes content and verifies base..HEAD before attempting a push.
  Payload writes/commits can remain after gate failure. The gate checks known secret shapes,
  not absence of secrets (unprefixed 40-hex tokens resemble Git SHAs; see scan_secrets/2).
  Options are partly validated: malformed identity maps or unchecked downstream values can raise.

  push? defaults true; false/nil skips publication. local_ref defaults HEAD but may name another
  source, which is not compared with the verified HEAD. commit_sha reports the HEAD read after
  verification. Optional nonempty provenance is written locally and included in the same push;
  Git.push does not request atomic ref updates, so errors may follow partial remote changes.
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

  # BL-6-43: bind supplied provenance to the read HEAD and write it before publication.
  # Failure here prevents this push; absent/empty/non-map provenance skips attestation entirely.
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

  defp check_types(opts) do
    cond do
      not is_binary(opts.workspace) ->
        {:error, {:bad_opt, {:workspace, opts.workspace}}}

      not is_binary(opts.base_sha) ->
        {:error, {:bad_opt, {:base_sha, opts.base_sha}}}

      # base_sha is interpolated into Git ranges downstream; binary alone allows option injection.
      # GitRef accepts revisions as well as SHAs, so native HEAD comparison below is textual.
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

  # Checks key presence only; identity must already be a map for Map.has_key?/2.
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

  # Compares the resolved HEAD string with base_sha as supplied; a symbolic base can differ
  # while resolving to the same commit. The gate separately checks ancestry, not a nonempty range.
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

  # Build the refspec only in push mode: local-only callers need not supply target_branch.
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

  defp head_sha(workspace), do: Git.read_head_sha(workspace)
end
