defmodule Fleet.Workflow.Provenance.Verifier do
  @moduledoc """
  Deterministically verifies provenance plumbing with JSON and Git: claimed
  deliverable, base ancestry, and brief commit. C-DEGRADED/DR-010 means an absent
  claimed brief digest passes; the verifier checks claims, not completeness.
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
  Verifies parsed statement type, deliverable commit, base ancestry, and any claimed
  brief commit. `:work_dir` is required; `:project_dir` and expected brief are optional.
  """
  @spec verify(String.t(), keyword()) :: :ok | {:error, failure()}
  def verify(ref, opts) when is_binary(ref) and is_list(opts) do
    work_dir = Keyword.fetch!(opts, :work_dir)
    project_dir = Keyword.get(opts, :project_dir, work_dir)

    with {:ok, statement} <- parse(Path.join(work_dir, ref)),
         {:ok, livrable} <- subject_sha(statement),
         :ok <- commit_exists(project_dir, livrable, {:unknown_livrable, livrable}),
         :ok <- base_descends(project_dir, statement, livrable),
         :ok <- brief_coherent(work_dir, statement, Keyword.get(opts, :expected_brief_sha)) do
      :ok
    end
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
        with :ok <- commit_exists(work_dir, claimed, {:unknown_brief_commit, claimed}) do
          case expected do
            nil -> :ok
            ^claimed -> :ok
            other -> {:error, {:brief_mismatch, claimed, other}}
          end
        end

      _ ->
        # C-DEGRADED: absent claimed digest is valid.
        :ok
    end
  end
end
