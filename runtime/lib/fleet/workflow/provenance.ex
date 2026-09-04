defmodule Fleet.Workflow.Provenance do
  @moduledoc """
  The doctrine's **SHA triplet**: SLSA/in-toto provenance of a deliverable.

  Assembles an in-toto Statement `(brief_sha, input_sha, livrable_sha)` — WHAT was asked (the brief),
  WHAT we started from (the base state), WHAT came out (the deliverable) — and commits it into
  `provenance/issue-<n>-<sha7>.json` (no `:issue` attr → bare `provenance/<livrable_sha>.json`).
  The directory says what the files ARE: mechanical attestations, NOT deliverables — the
  deliverable itself is the git commit the statement points at. **bash+jq+git on the doctrine
  side; HERE Jason + Git, ZERO external tooling** (no cosign, no SLSA CLI).

  - `livrable_sha` = subject digest + file name (the anchor: the provenance of ONE given deliverable).
    The deliverable is a **git commit** (what was pushed) → its digest is labeled `gitCommit`
    (honest in-toto algo), NOT `sha256`: it is a commit SHA-1, not a content sha256 — lying about
    the algorithm would make an in-toto verifier fail (the triplet must be falsifiable, hence exact).
  - `brief_sha`/`brief_ref` = `invocation.configSource` (what was asked — the committed brief object).
    `brief_sha` is the COMMIT that introduced the brief version (cf. `BriefArtifact`) → `gitCommit`
    digest, same honest label as the subject: three homogeneous git anchors.
  - `input_sha` = `buildConfig.input_sha` (the pinned `base_sha` — the starting state; a bare field,
    no algorithm claim).

  **Degraded-tolerant**: if `brief_sha` is missing (brief not materialized, cf. `BriefArtifact`), the
  Statement omits the configSource digest but still records input→output (2/3 beats 0). Idempotent by
  content-address (same `livrable_sha` = same file = no-op).
  """

  # Writes go through the SERIALIZER (CI-11): up to 16 concurrent completion Tasks engrave provenance
  # onto the same project's ops worktree → `.git/index.lock` race. `OpsObjectSync` serializes one
  # git transaction at a time; `OpsObject` stays the engine (reached only via the gate).
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
  Records the deliverable's in-toto provenance into `work_dir`
  (`provenance/issue-<n>-<sha7>.json`, cf. `statement_name/2`), committed. `attrs.livrable_sha`
  REQUIRED (the anchor); the rest enriches the Statement (degrades when absent).

  `opts`: `:author` `{name, email}` (system default); `:push` `{remote, refspec}` — BEST-EFFORT
  publication (a push failure logs LOUD, never fails the emit); `:subject_workspace` (path, opt) —
  arms the BL-6-34 wall: the subject must be a commit reachable from that workspace, else
  `{:error, {:subject_unreachable, workspace}}` (or `{:subject_unverifiable, reason}`).
  `{:error, term()}`: work_dir missing / write failure / git failure — propagated (fail-loud,
  non-fatal caller-side).
  """
  @spec emit(Path.t(), attrs(), keyword()) ::
          {:ok, %{path: String.t(), ref: String.t()}} | {:error, term()}
  def emit(work_dir, %{livrable_sha: livrable_sha} = attrs, opts \\ [])
      when is_binary(work_dir) and is_binary(livrable_sha) and livrable_sha != "" do
    {subject_workspace, opts} = Keyword.pop(opts, :subject_workspace)

    cond do
      not safe_path_segment?(livrable_sha) ->
        # BND-120: `livrable_sha` is interpolated into the provenance FILE PATH. A
        # separator/traversal (`/`, `\`, `..`) would escape the ops dir. It IS a git commit
        # digest (hex) in production — a value carrying a path separator is refused, never
        # trusted as a path segment. (Layout sanitizes too — belt kept: this refuses LOUDLY
        # instead of silently mangling a corrupt anchor into a plausible name.)
        {:error, {:invalid_livrable_sha, livrable_sha}}

      true ->
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
          # The push state is DELIBERATELY not surfaced here: a provenance statement is an audit
          # artifact whose consumers read it from the worktree, and this function's result is
          # already `%{path:, ref:}` — a caller wanting the publication asks the object, not the
          # emitter. Matched explicitly so a future third element cannot slip through unread.
          {:ok, %{path: Path.join(work_dir, ref), ref: ref}}
        end
    end
  end

  # Path-SAFE segment for the provenance filename (BND-120): no separator, no traversal.
  defp safe_path_segment?(s), do: not String.contains?(s, ["/", "\\", ".."])

  # BL-6-34 wall, twin of the BND-120 refusal above: when the caller names the workspace its
  # publication ran in (`:subject_workspace` opt), the SUBJECT must be a commit reachable there.
  # A statement engraved from a viewpoint that never saw its subject attests "delivered" for a
  # publication that did not happen — refused as a typed error (the caller decides how loud), and
  # an UNVERIFIABLE subject is refused too: never a statement we could not check. Opt absent/nil
  # → no viewpoint claimed, no check (the pre-wall contract, kept for viewpoint-less callers).
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
        # `gitCommit` (not `sha256`): the deliverable is the published git commit (SHA-1), not a
        # content sha256 — an honest label, without which an in-toto verifier would fail on the algorithm.
        %{
          "name" => Map.get(a, :subject_name, "deliverable"),
          "digest" => %{"gitCommit" => livrable_sha}
        }
      ],
      "predicateType" => "https://slsa.dev/provenance/v1.0",
      "predicate" => %{
        "buildType" => @build_type,
        # configSource = what was asked: the committed brief object. Digest omitted if the brief was not
        # materialized (degraded) — the triplet becomes an input→output pair, never a provenance that
        # LIES about a brief_sha.
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

  # `invocation.environment` — builder-controlled inputs that are not build PARAMETERS. Today one
  # fact: was the fleet running in debug visibility (`fleet start --debug`) when this deliverable
  # was produced. It belongs in the attestation because a pod a human could attach to and type into
  # is not the same builder as an unattended one, and the triplet's job is to be falsifiable about
  # what actually happened.
  #
  # Stamped ONLY when the caller states it. A missing key means "this runtime did not say", never
  # "we certify it was clean" — same rule as the brief digest above: omit rather than invent. So a
  # `false` here is a CLAIM (the fleet was not in debug), which is why it is written out and not
  # dropped as a falsy value.
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
  Renders the in-toto Statement of `attrs` as JSON, WITHOUT writing anything.

  The publication path needs the content before it has a place to put it: the attestation now rides
  the same `git push` as the brick it attests (BL-6-43), so it is built here and written as a git
  object by the publisher — not committed to a second face afterwards.
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
