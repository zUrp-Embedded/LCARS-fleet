defmodule Fleet.Workflow.Provenance do
  @moduledoc """
  Builds an unsigned JSON statement linking the brief commit, input commit and
  deliverable commit. Subject and brief digests use gitCommit; input_sha remains
  a buildConfig field. It emits the declared in-toto/SLSA type labels without
  schema validation or proof of standards compliance.

  emit/3 stores a versioned ops artifact; statement_json/1 supplies bytes for the
  deliverable publisher's provenance ref. Missing brief_sha omits its digest;
  absent fields do not establish completeness despite the fixed metadata flags.
  The same deliverable SHA can produce different JSON and another commit when
  other attributes change. Issue names use only seven SHA characters and can collide.
  """

  # Serialize cooperating brief and provenance writes to shared ops worktrees.
  alias Fleet.Workflow.OpsObjectSync

  @build_type "lcars-fleet-pipeline"

  @type attrs :: %{
          required(:livrable_sha) => String.t(),
          optional(:brief_sha) => String.t() | nil,
          optional(:brief_ref) => String.t() | nil,
          optional(:input_sha) => String.t() | nil,
          optional(:subject_name) => String.t(),
          optional(:pod_id) => String.t() | nil,
          optional(:role) => String.t() | nil,
          optional(:issue) => term(),
          optional(:started_at) => String.t() | nil,
          optional(:finished_at) => String.t() | nil,
          optional(:debug_visibility) => boolean() | nil
        }

  @doc """
  Encodes and commits the statement through OpsObjectSync, returning its local path
  and ref while discarding commit SHA and push state. Paths use issue-<n>-<sha7>
  when issue is an integer, otherwise the full livrable_sha, under provenance/.

  Requires a nonempty binary livrable_sha without /, backslash or ..; this is not
  SHA validation. Optional :subject_workspace checks whether Git can resolve it
  as a local commit, not ancestry, branch reachability or remote publication.
  Nil skips that check. Other options pass through to OpsObject (author, push).
  Returned file/Git/serialization errors propagate; malformed arguments can raise.
  """
  @spec emit(Path.t(), attrs(), keyword()) ::
          {:ok, %{path: String.t(), ref: String.t()}} | {:error, term()}
  def emit(work_dir, %{livrable_sha: livrable_sha} = attrs, opts \\ [])
      when is_binary(work_dir) and is_binary(livrable_sha) and livrable_sha != "" do
    {subject_workspace, opts} = Keyword.pop(opts, :subject_workspace)

    # Refuse separators before Layout derives a filename; do not silently sanitize the anchor.
    if safe_path_segment?(livrable_sha) do
      ref = Fleet.Layout.provenance_ref(statement_name(livrable_sha, attrs))

      with :ok <- subject_reachable(subject_workspace, livrable_sha),
           {:ok, json} <- encode(statement(attrs)),
           {:ok, _commit_sha, _push} <-
             OpsObjectSync.commit_object(
               work_dir,
               ref,
               json,
               Keyword.put(opts, :label, "provenance")
             ) do
        # This API returns the artifact location, not evidence of remote publication.
        {:ok, %{path: Path.join(work_dir, ref), ref: ref}}
      end
    else
      {:error, {:invalid_livrable_sha, livrable_sha}}
    end
  end

  # Path-SAFE segment for the provenance filename (BND-120): no separator, no traversal.
  defp safe_path_segment?(s), do: not String.contains?(s, ["/", "\\", ".."])

  # Optional local commit resolution. Git nonzero exits also map to unreachable;
  # this neither fetches the subject nor proves a publication happened.
  defp subject_reachable(nil, _sha), do: :ok

  defp subject_reachable(workspace, sha) when is_binary(workspace) do
    case Fleet.Workflow.Git.commit_exists?(workspace, sha) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, {:subject_unreachable, workspace}}
      {:error, reason} -> {:error, {:subject_unverifiable, reason}}
    end
  end

  @doc "The in-toto Statement (JSON-able map) — pure, no I/O (testable + reusable)."
  @spec statement(attrs()) :: map()
  def statement(%{livrable_sha: livrable_sha} = a) do
    %{
      "_type" => "https://in-toto.io/Statement/v0.1",
      "subject" => [
        # These are Git commit identifiers, not SHA-256 hashes of artifact bytes.
        %{
          "name" => Map.get(a, :subject_name, "deliverable"),
          "digest" => %{"gitCommit" => livrable_sha}
        }
      ],
      "predicateType" => "https://slsa.dev/provenance/v1.0",
      "predicate" => %{
        "buildType" => @build_type,
        # Omit an unstated brief digest instead of inventing one.
        "invocation" =>
          drop_nil(%{
            "configSource" => config_source(a),
            "environment" => environment(a)
          }),
        "buildConfig" =>
          drop_nil(%{
            "input_sha" => Map.get(a, :input_sha),
            "pod_id" => Map.get(a, :pod_id),
            "role" => Map.get(a, :role),
            "issue" => Map.get(a, :issue)
          }),
        "metadata" =>
          drop_nil(%{
            "buildStartedOn" => Map.get(a, :started_at),
            "buildFinishedOn" => Map.get(a, :finished_at),
            "completeness" => %{"parameters" => true, "environment" => false, "materials" => true}
          })
      }
    }
  end

  # Caller-reported debug visibility is builder context, not a measured fact.
  # Preserve explicit false; omit absent or non-boolean values.
  defp environment(a) do
    case Map.get(a, :debug_visibility) do
      flag when is_boolean(flag) -> %{"debug_visibility" => flag}
      _ -> nil
    end
  end

  defp config_source(a) do
    case Map.get(a, :brief_sha) do
      sha when is_binary(sha) and sha != "" ->
        # Brief identity is also its introducing Git commit.
        drop_nil(%{"uri" => Map.get(a, :brief_ref), "digest" => %{"gitCommit" => sha}})

      _ ->
        # Record known URI without inventing a digest.
        drop_nil(%{"uri" => Map.get(a, :brief_ref)})
    end
  end

  @doc """
  Encodes statement/1 as pretty JSON with a trailing newline, without writing.
  The deliverable publisher can store these bytes in a Git object. Encoding failures
  return :provenance_encode_failed; this path does not check local commit existence.
  """
  @spec statement_json(attrs()) :: {:ok, String.t()} | {:error, term()}
  def statement_json(%{livrable_sha: sha} = attrs) when is_binary(sha) and sha != "",
    do: encode(statement(attrs))

  defp encode(statement) do
    {:ok, Jason.encode!(statement, pretty: true) <> "\n"}
  rescue
    e -> {:error, {:provenance_encode_failed, Exception.message(e)}}
  end

  # Issue-prefixed browse name; full digest remains inside the statement.
  defp statement_name(livrable_sha, attrs) do
    case Map.get(attrs, :issue) do
      n when is_integer(n) -> "issue-#{n}-#{String.slice(livrable_sha, 0, 7)}"
      _ -> livrable_sha
    end
  end

  defp drop_nil(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)
end
