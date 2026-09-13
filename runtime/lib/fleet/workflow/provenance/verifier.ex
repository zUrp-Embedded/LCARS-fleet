defmodule Fleet.Workflow.Provenance.Verifier do
  @moduledoc """
  Checks statement type labels, the first subject's local commit, optional input
  ancestry, and an optional claimed brief commit. C-DEGRADED/DR-010 permits missing
  claims, even when expected_brief_sha is supplied. This is not signature, schema
  compliance, artifact-content or publication verification.

  Git accepts revision expressions; identifiers are not restricted to full SHAs.
  Nested shapes are assumed map-like: malformed structures can raise during get_in.
  Git nonzero exits in commit probes are classified as missing commits.
  """

  alias Fleet.Workflow.Git

  @statement_type "https://in-toto.io/Statement/v0.1"
  @predicate_type "https://slsa.dev/provenance/v1.0"

  @typedoc "Precise falsifiable failure with relevant SHA values."
  @type failure ::
          {:malformed, term()}
          | {:unknown_livrable, String.t()}
          | {:base_not_ancestor, String.t(), String.t()}
          | {:unknown_brief_commit, String.t()}
          | {:brief_mismatch, String.t(), String.t()}

  @doc """
  Reads ref joined under required :work_dir, without path containment validation.
  :project_dir defaults to work_dir. The brief commit is checked in work_dir;
  :expected_brief_sha, when non-nil, is compared only if a brief digest is claimed.
  """
  @spec verify(String.t(), keyword()) :: :ok | {:error, failure()}
  def verify(ref, opts) when is_binary(ref) and is_list(opts) do
    work_dir = Keyword.fetch!(opts, :work_dir)
    do_verify(parse(Path.join(work_dir, ref)), Keyword.put_new(opts, :project_dir, work_dir))
  end

  @doc """
  Verifies supplied JSON without locating or fetching an attestation ref.
  Requires :project_dir after successful parsing; :work_dir defaults to project_dir
  for brief commit checks. Unlike verify/2, project_dir has no work_dir fallback.
  """
  @spec verify_content(String.t(), keyword()) :: :ok | {:error, failure()}
  def verify_content(json, opts) when is_binary(json) and is_list(opts) do
    do_verify(decode_typed(json), opts)
  end

  defp do_verify({:error, _} = err, _opts), do: err

  defp do_verify({:ok, statement}, opts) do
    project_dir = Keyword.fetch!(opts, :project_dir)

    with {:ok, livrable} <- subject_sha(statement),
         :ok <- commit_exists(project_dir, livrable, {:unknown_livrable, livrable}),
         :ok <- base_descends(project_dir, statement, livrable),
         do:
           brief_coherent(
             Keyword.get(opts, :work_dir, project_dir),
             statement,
             Keyword.get(opts, :expected_brief_sha)
           )
  end

  defp decode_typed(raw) do
    with {:ok, json} <- decode(raw), :ok <- typed(json), do: {:ok, json}
  end

  defp parse(abs) do
    with {:ok, raw} <- read(abs),
         {:ok, json} <- decode(raw),
         :ok <- typed(json) do
      {:ok, json}
    end
  end

  defp read(abs) do
    case File.read(abs) do
      {:ok, raw} -> {:ok, raw}
      {:error, reason} -> {:error, {:malformed, {:unreadable, abs, reason}}}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, json} when is_map(json) -> {:ok, json}
      _ -> {:error, {:malformed, :invalid_json}}
    end
  end

  defp typed(%{"_type" => @statement_type, "predicateType" => @predicate_type}), do: :ok

  defp typed(json),
    do: {:error, {:malformed, {:unexpected_type, json["_type"], json["predicateType"]}}}

  defp subject_sha(%{"subject" => [%{"digest" => %{"gitCommit" => sha}} | _]})
       when is_binary(sha) and sha != "",
       do: {:ok, sha}

  defp subject_sha(_), do: {:error, {:malformed, :no_subject_digest}}

  defp commit_exists(repo_dir, sha, failure) do
    case Git.commit_exists?(repo_dir, sha) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, failure}
      {:error, reason} -> {:error, {:malformed, {:git_unavailable, reason}}}
    end
  end

  defp base_descends(project_dir, statement, livrable) do
    case get_in(statement, ["predicate", "buildConfig", "input_sha"]) do
      input when is_binary(input) and input != "" ->
        case Git.ancestor?(project_dir, input, livrable) do
          {:ok, true} -> :ok
          {:ok, false} -> {:error, {:base_not_ancestor, input, livrable}}
          {:error, reason} -> {:error, {:malformed, {:git_unavailable, reason}}}
        end

      _ ->
        # C-DEGRADED: verify claims, not absent fields.
        :ok
    end
  end

  defp brief_coherent(work_dir, statement, expected) do
    case get_in(statement, ["predicate", "invocation", "configSource", "digest", "gitCommit"]) do
      claimed when is_binary(claimed) and claimed != "" ->
        with :ok <- commit_exists(work_dir, claimed, {:unknown_brief_commit, claimed}),
             do: brief_matches(claimed, expected)

      _ ->
        # C-DEGRADED: absent claimed digest is valid.
        :ok
    end
  end

  # Without an expected SHA, a claimed brief is checked for commit existence only.
  defp brief_matches(_claimed, nil), do: :ok
  defp brief_matches(claimed, claimed), do: :ok
  defp brief_matches(claimed, other), do: {:error, {:brief_mismatch, claimed, other}}
end
