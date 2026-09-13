defmodule Fleet.Workflow.BriefArtifact do
  @moduledoc """
  Brief naming and materialization over OpsObjectSync/OpsObject.
  A version is {path, commit}, supplying brief_sha in the provenance triplet alongside input_sha
  and livrable_sha. The commit is the version anchor; the hintless filename's SHA256 is not.
  Availability still depends on retaining the Git object and, for forge readers, publishing it.

  Ticket creation uses physicalize_attrs to tolerate returned materialization errors while ops
  is not ready. Dispatch uses materialize's causes to choose its failure policy. The work item
  carries brief content as well as the optional citation; this module does not deliver the order.
  Local commit success is distinct from best-effort publication (F-15).
  """

  require Logger

  # CI-11: use OpsObjectSync to avoid index.lock races when its serializer is running.
  # That module can fall back to a direct write if the serializer is absent.
  alias Fleet.Layout
  alias Fleet.Workflow.{OpsObject, OpsObjectSync}

  @type ok :: %{ref: String.t(), sha: String.t(), push: OpsObject.push_state() | :unknown}

  @doc """
  Commits content under Layout.brief_ref and returns %{ref, sha, push}; errors propagate.
  OpsObject owns content-version reuse and push outcomes, including :unknown on recovered replies.
  :name_hint is sanitized by Layout, or defaults to content SHA256. :kind == "judge" selects
  gate-briefs/, otherwise briefs/. :author defaults to system identity; :push supports :ops or
  {remote, refspec}. A local commit does not imply remote publication.
  """
  @spec commit(Path.t(), String.t(), keyword()) :: {:ok, ok()} | {:error, term()}
  def commit(work_dir, content, opts \\ []) when is_binary(work_dir) and is_binary(content) do
    ref = Layout.brief_ref(Keyword.get(opts, :kind), object_name(content, opts))

    case OpsObjectSync.commit_object(work_dir, ref, content, Keyword.put(opts, :label, "brief")) do
      # Keep publication outcome for callers reporting forge-pointer availability.
      {:ok, commit_sha, push} -> {:ok, %{ref: ref, sha: commit_sha, push: push}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Adds atom-key ref/SHA on success, retaining brief content. Returned failures leave attrs
  unchanged, including any prior ref/SHA; exceptions are not caught.
  """
  @spec physicalize_attrs(map(), String.t() | nil, keyword()) :: map()
  def physicalize_attrs(attrs, repo, opts \\ [])

  def physicalize_attrs(%{brief: brief} = attrs, repo, opts) do
    case physicalize(brief, repo, opts) do
      {ref, sha} when is_binary(sha) -> Map.merge(attrs, %{brief_ref: ref, brief_sha: sha})
      _ -> attrs
    end
  end

  def physicalize_attrs(attrs, _repo, _opts), do: attrs

  @doc """
  Tuple adapter for materialize/3: every returned error becomes {nil, nil}; exceptions propagate.
  Callers needing the cause must use materialize/3. :ops_root is injectable.
  """
  @spec physicalize(String.t() | nil, String.t() | nil, keyword()) ::
          {String.t() | nil, String.t() | nil}
  def physicalize(brief, repo, opts \\ []) do
    case materialize(brief, repo, opts) do
      {:ok, {ref, sha}} -> {ref, sha}
      {:error, _cause} -> {nil, nil}
    end
  end

  @doc """
  Commits under ops_root/project_name(repo), returning {ref, sha} and discarding push status.
  Rejects empty/non-binary repo as :no_repo, then empty/non-binary brief as :no_brief;
  whitespace strings pass. Missing work_dir retains its cause, all other returned commit errors
  become {:git, reason}. That wrapper does not prove transience: permissions, invalid refs or
  configuration errors can persist. Callers own defer/retry policy; no retry happens here.
  """
  @spec materialize(String.t() | nil, String.t() | nil, keyword()) ::
          {:ok, {String.t(), String.t()}} | {:error, term()}
  def materialize(brief, repo, opts \\ [])

  def materialize(brief, repo, opts)
      when is_binary(brief) and brief != "" and is_binary(repo) and repo != "" do
    ops_root = Keyword.get(opts, :ops_root, Layout.ops_root())
    work_dir = Path.join(ops_root, Layout.project_name(repo))

    case commit(work_dir, brief, Keyword.delete(opts, :ops_root)) do
      # The pair represents local materialization; remote publication is intentionally omitted.
      {:ok, %{ref: ref, sha: sha, push: _}} ->
        {:ok, {ref, sha}}

      {:error, {:work_dir_missing, _} = cause} ->
        Logger.warning(
          "BriefArtifact: brief NOT materialized (repo=#{repo}): #{inspect(cause)} — the project " <>
            "has no ops. PERMANENT until it is onboarded; a caller that degrades here " <>
            "produces work nobody can prove was asked for."
        )

        {:error, cause}

      {:error, reason} ->
        Logger.warning(
          "BriefArtifact: brief NOT materialized (repo=#{repo}): #{inspect(reason)} — " <>
            "transient git failure"
        )

        {:error, {:git, reason}}
    end
  end

  def materialize(_brief, repo, _opts) do
    cause = if is_binary(repo) and repo != "", do: :no_brief, else: :no_repo
    {:error, cause}
  end

  @doc """
  Reads ref at the supplied Git revision from ops_root/project_name(repo), after checking the
  brief-path pattern and directory. Git.show owns revision argument checks and command errors;
  this function does not require a full commit SHA or validate author/provenance.
  """
  @spec resolve(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve(repo, ref, sha, opts \\ [])
      when is_binary(repo) and is_binary(ref) and is_binary(sha) do
    ops_root = Keyword.get(opts, :ops_root, Layout.ops_root())
    work_dir = Path.join(ops_root, Layout.project_name(repo))

    cond do
      not Layout.valid_brief_ref?(ref) -> {:error, {:invalid_pointer_ref, ref}}
      not File.dir?(work_dir) -> {:error, {:work_dir_missing, work_dir}}
      true -> Fleet.Workflow.Git.show(work_dir, sha, ref)
    end
  end

  # Human hint or content hash; versions live in Git history.
  defp object_name(content, opts) do
    case Keyword.get(opts, :name_hint) do
      nil -> :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
      hint -> hint
    end
  end
end
