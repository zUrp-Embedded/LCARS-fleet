defmodule Fleet.Workflow.Provenance do
  @moduledoc """
  The doctrine's **SHA triplet**: SLSA/in-toto provenance of a deliverable (design:
  `beyond_#6/DESIGN-brief-physique-dispatch-unique-triplet-sha.md`).

  Assembles an in-toto Statement `(brief_sha, input_sha, livrable_sha)` — WHAT was asked (the brief),
  WHAT we started from (the base state), WHAT came out (the deliverable) — and commits it
  content-addressed into `livrables/<livrable_sha>-provenance.json`. **bash+jq+git on the doctrine
  side; HERE Jason + Git, ZERO external tooling** (no cosign, no SLSA CLI).

  - `livrable_sha` = subject digest + file name (the anchor: the provenance of ONE given deliverable).
    The deliverable is a **git commit** (what was pushed) → its digest is labeled `gitCommit`
    (honest in-toto algo), NOT `sha256`: it is a commit SHA-1, not a content sha256 — lying about
    the algorithm would make an in-toto verifier fail (the triplet must be falsifiable, hence exact).
  - `brief_sha`/`brief_ref` = `invocation.configSource` (what was asked — the committed brief object).
    The brief IS content-addressed `sha256(content)` (cf. `BriefArtifact`) → `sha256` digest, that one true.
  - `input_sha` = `buildConfig.input_sha` (the pinned `base_sha` — the starting state; a bare field,
    no algorithm claim).

  **Degraded-tolerant**: if `brief_sha` is missing (brief not materialized, cf. `BriefArtifact`), the
  Statement omits the configSource digest but still records input→output (2/3 beats 0). Idempotent by
  content-address (same `livrable_sha` = same file = no-op).

  **Last revised**: 2026-07-18
  """

  require Logger

  alias Fleet.Workflow.Git

  @livrables_subdir "livrables"
  @system_author {"lcars-system", "system@lcars.local"}
  @build_type "lcars-fleet-pipeline-v2"

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
          optional(:finished_at) => String.t() | nil
        }

  @doc """
  Records the deliverable's in-toto provenance into `work_dir`
  (`livrables/<livrable_sha>-provenance.json`), committed. `attrs.livrable_sha` REQUIRED (the anchor);
  the rest enriches the Statement (degrades when absent).

  `opts`: `:author` `{name, email}` (system default); `:push` `{remote, refspec}` (default local commit).
  `{:error, term()}`: work_dir missing / write failure / git failure — propagated (fail-loud,
  non-fatal caller-side).
  """
  @spec emit(Path.t(), attrs(), keyword()) :: {:ok, %{path: String.t(), ref: String.t()}} | {:error, term()}
  def emit(work_dir, %{livrable_sha: livrable_sha} = attrs, opts \\ [])
      when is_binary(work_dir) and is_binary(livrable_sha) and livrable_sha != "" do
    ref = Path.join(@livrables_subdir, livrable_sha <> "-provenance.json")
    abs = Path.join(work_dir, ref)

    cond do
      not safe_path_segment?(livrable_sha) ->
        # BND-120: `livrable_sha` is interpolated into the provenance FILE PATH
        # (`livrables/<sha>-provenance.json`). A separator/traversal (`/`, `\`, `..`) would escape the
        # work/ops dir. It IS a git commit digest (hex) in production — a value carrying a path separator
        # is refused, never trusted as a path segment.
        {:error, {:invalid_livrable_sha, livrable_sha}}

      not File.dir?(work_dir) ->
        {:error, {:work_dir_missing, work_dir}}

      File.exists?(abs) ->
        {:ok, %{path: abs, ref: ref}}

      true ->
        write_and_commit(work_dir, abs, ref, statement(attrs), opts)
    end
  end

  # Path-SAFE segment for the provenance filename (BND-120): no separator, no traversal.
  defp safe_path_segment?(s), do: not String.contains?(s, ["/", "\\", ".."])

  @doc "The in-toto Statement (JSON-able map) — pure, no I/O (testable + reusable)."
  @spec statement(attrs()) :: map()
  def statement(%{livrable_sha: livrable_sha} = a) do
    %{
      "_type" => "https://in-toto.io/Statement/v0.1",
      "subject" => [
        # `gitCommit` (not `sha256`): the deliverable is the published git commit (SHA-1), not a
        # content sha256 — an honest label, without which an in-toto verifier would fail on the algorithm.
        %{"name" => Map.get(a, :subject_name, "deliverable"), "digest" => %{"gitCommit" => livrable_sha}}
      ],
      "predicateType" => "https://slsa.dev/provenance/v1.0",
      "predicate" => %{
        "buildType" => @build_type,
        # configSource = what was asked: the committed brief object. Digest omitted if the brief was not
        # materialized (degraded) — the triplet becomes an input→output pair, never a provenance that
        # LIES about a brief_sha.
        "invocation" => %{"configSource" => config_source(a)},
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

  defp config_source(a) do
    case Map.get(a, :brief_sha) do
      sha when is_binary(sha) and sha != "" ->
        drop_nil(%{"uri" => Map.get(a, :brief_ref), "digest" => %{"sha256" => sha}})

      _ ->
        # Brief not materialized: record the uri when known, never an invented digest.
        drop_nil(%{"uri" => Map.get(a, :brief_ref)})
    end
  end

  defp write_and_commit(work_dir, abs, ref, statement, opts) do
    with {:ok, json} <- encode(statement),
         :ok <- File.mkdir_p(Path.dirname(abs)),
         :ok <- File.write(abs, json),
         {:ok, _sha} <- Git.commit(commit_opts(work_dir, ref, opts)),
         :ok <- maybe_push(work_dir, opts) do
      {:ok, %{path: abs, ref: ref}}
    end
  end

  defp encode(statement) do
    {:ok, Jason.encode!(statement, pretty: true) <> "\n"}
  rescue
    e -> {:error, {:provenance_encode_failed, Exception.message(e)}}
  end

  defp commit_opts(work_dir, ref, opts) do
    {name, email} = Keyword.get(opts, :author, @system_author)

    %{
      workspace: work_dir,
      author_name: name,
      author_email: email,
      committer_name: name,
      committer_email: email,
      message: "provenance: #{ref}",
      add_paths: [ref]
    }
  end

  defp maybe_push(work_dir, opts) do
    case Keyword.get(opts, :push) do
      nil -> :ok
      {remote, refspec} -> Git.push(work_dir, remote, refspec)
    end
  end

  defp drop_nil(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)
end
