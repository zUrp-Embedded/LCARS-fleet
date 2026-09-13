defmodule Fleet.Pilot.StepRunCompleter.Attestations do
  @moduledoc """
  Writes deliverable provenance and machine verdicts on the project's ops face.
  `:ops_root` selects that worktree; provenance and findings request an ops push,
  but their success does not certify remote publication.

  Returned write errors and missing material log and return :ok. Malformed input,
  serialization and dependency exceptions can still raise. Missing directories do
  not by themselves prove the project was never onboarded.
  """

  require Logger

  alias Fleet.Layout

  @doc "The project's ops worktree, or `nil` when the project has none (nowhere to pin)."
  @spec verdict_work_dir(String.t(), keyword()) :: Path.t() | nil
  def verdict_work_dir(repo, opts) do
    dir =
      Path.join(
        Keyword.get(opts, :ops_root, Layout.ops_root()),
        Layout.project_name(repo)
      )

    if File.dir?(dir), do: dir
  end

  # Keep input/output provenance when no brief digest is available; never invent one.
  @doc "Writes available provenance on ops; returned errors and missing material log and return :ok."
  @spec maybe_emit_provenance(map(), String.t(), keyword()) :: :ok
  def maybe_emit_provenance(step_run, livrable_sha, opts) do
    ops_root = Keyword.get(opts, :ops_root, Layout.ops_root())
    repo = Map.get(step_run, :repo)

    case {Map.get(step_run, :deliverable_opts), repo} do
      {%{} = dopts, repo} when is_binary(repo) ->
        work_dir = Path.join(ops_root, Layout.project_name(repo))

        if File.dir?(work_dir) do
          emit_provenance(work_dir, step_run, dopts, livrable_sha)
        else
          Logger.warning(
            "StepRunCompleter: provenance NOT engraved (#{repo}): {:work_dir_missing, " <>
              "#{inspect(work_dir)}} — the project has no ops face. PERMANENT until it is " <>
              "onboarded; the brick #{String.slice(livrable_sha, 0, 7)} carries NO attestation"
          )

          :ok
        end

      {nil, repo} ->
        Logger.error(
          "StepRunCompleter: provenance NOT engraved (#{inspect(repo)}): no :deliverable_opts on " <>
            "the publication path — a producer deliverable reached open_deliverable_pr without the " <>
            "shape that names its base. Brick #{String.slice(livrable_sha, 0, 7)} unattested"
        )

        :ok

      {_dopts, other} ->
        Logger.error(
          "StepRunCompleter: provenance NOT engraved: repo is #{inspect(other)}, not a binary — " <>
            "brick #{String.slice(livrable_sha, 0, 7)} unattested"
        )

        :ok
    end
  end

  defp emit_provenance(work_dir, step_run, dopts, livrable_sha) do
    attrs = %{
      livrable_sha: livrable_sha,
      brief_sha: Map.get(step_run, :brief_sha),
      brief_ref: Map.get(step_run, :brief_ref),
      input_sha: Map.get(dopts, :base_sha) || Map.get(dopts, "base_sha"),
      pod_id: Map.get(step_run, :pod_id),
      role: Map.get(step_run, :role),
      issue: Map.get(step_run, :issue_number),
      # Read the builder's visibility through the launch authority at completion time.
      # This is not a per-pod launch snapshot if application configuration changes.
      debug_visibility: Fleet.Spawner.debug_visibility?()
    }

    # Check optional subject_workspace for local commit resolution, not ancestry or remote
    # publication. Nil skips that check. Returned refusals log without failing completion.
    emit_opts = [
      push: :ops,
      subject_workspace: Map.get(dopts, :workspace) || Map.get(dopts, "workspace")
    ]

    case Fleet.Workflow.Provenance.emit(work_dir, attrs, emit_opts) do
      {:ok, _} ->
        :ok

      {:error, {:subject_unreachable, workspace}} ->
        Logger.error(
          "StepRunCompleter: provenance subject #{livrable_sha} is NOT a commit of the publish " <>
            "workspace #{workspace} — engrave REFUSED (proof from the wrong viewpoint)"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "StepRunCompleter: provenance NOT engraved (#{Map.get(step_run, :repo)}): " <>
            "#{inspect(reason)} — degraded (completion preserved)"
        )

        :ok
    end
  end

  # JSON is an ops object beside the prose pin, not a summarized comment. The review body
  # separately transports FindingsWire; losing the archive need not lose machine transport.
  @doc "Writes findings beside their prose pin; missing/refused payloads and returned write errors log and return :ok."
  @spec maybe_engrave_findings(map(), Path.t() | nil, String.t()) :: :ok
  def maybe_engrave_findings(step_run, work_dir, role) do
    case {Map.get(step_run, :review_findings), work_dir} do
      # Missing and schema-refused payloads need distinct diagnostics: repair form vs emission.
      {nil, _} ->
        if Map.get(step_run, :review_findings_refused) do
          Logger.warning(
            "StepRunCompleter: judge #{role} DID submit details.findings on " <>
              "#{Map.get(step_run, :repo)}##{Map.get(step_run, :issue_number)}, and it was " <>
              "REFUSED upstream (see the schema error logged by StepRunConsumer just above). " <>
              "Its measure is lost to the rail — but the judge did its part: fix the form, not " <>
              "the judge."
          )
        else
          Logger.warning(
            "StepRunCompleter: judge #{role} submitted NO details.findings on " <>
              "#{Map.get(step_run, :repo)}##{Map.get(step_run, :issue_number)} — its verdict " <>
              "survives as prose only. The SP asks every judge for the machine payload; without " <>
              "it no aggregation can weigh this verdict, it can only count it."
          )
        end

        :ok

      {findings, nil} ->
        Logger.warning(
          "StepRunCompleter: findings NOT engraved (#{Map.get(step_run, :repo)}##{Map.get(step_run, :issue_number)} " <>
            "role=#{role}): the project has no ops face — the judge's machine verdict " <>
            "(#{length(Map.get(findings, "findings", []))} finding(s)) survives only as prose"
        )

        :ok

      {findings, work_dir} ->
        ref = Layout.verdict_findings_ref(Map.fetch!(step_run, :issue_number), role)

        case Fleet.Workflow.OpsObjectSync.commit_object(
               work_dir,
               ref,
               Jason.encode!(findings, pretty: true) <> "\n",
               label: "verdict",
               push: :ops
             ) do
          {:ok, _sha, _push_state} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "StepRunCompleter: findings NOT engraved at #{ref} (#{inspect(reason)}) — " <>
                "the review posts anyway; the machine verdict survives only as prose"
            )

            :ok
        end
    end
  end
end
