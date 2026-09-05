defmodule Fleet.Pilot.StepRunCompleter.Attestations do
  @moduledoc """
  The PROOFS a completion engraves in GIT beside its forge writes: the provenance triplet of a
  deliverable (`refs/lcars/provenance/<sha>`) and a judge's machine verdict
  (`verdicts/issue-<n>-<role>.json`), both committed on the ops face and pushed best-effort —
  never through the forge API, which is the ordered sequence's own. The two `maybe_*` engravers
  return `:ok` by contract, absence recorded loud and never fabricated: an effect whose failure
  never invalidates the act it documents (`Emissions` holds the same rule for the bus).
  `verdict_work_dir/2` is the path reader that precedes them.

  `:ops_root` is a seam because the real root is a hardcoded global path.
  """

  require Logger

  alias Fleet.Layout

  # The project's ops worktree, or `nil` when there is none — a project that was never onboarded
  # has nowhere to pin, and `Pinning.render/2` then leaves the body inline. Same `:ops_root` seam as
  # the provenance emission below, for the same reason: the real root is a hardcoded global path.
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

  # Triplet de provenance a l'EXTRACTION : le brief, l'entree, le livrable. Emis UNIQUEMENT pour un
  # vrai livrable git.
  #
  # ⚠ UN BRIEF ABSENT DONNE UNE PROVENANCE PARTIELLE — entree vers sortie — JAMAIS UN DIGEST INVENTE.
  #
  # La racine d'ops est une COUTURE parce que la vraie est un chemin global en dur : sans
  # l'injecter, le vert ne marche jamais sur le chemin reel.
  #
  # ⚠ AUCUNE DE CES SORTIES N'EST MUETTE. Un `else` fourre-tout rendant `:ok` laisse une brique
  # etre publiee, mergee et scellee sans qu'une ligne n'ait dit que sa preuve n'avait pas ete
  # ECRITE — et vu du sceau, ce silence est indiscernable d'une gravure RATEE, qui elle loggue. La
  # seule question posable en aval devient alors « faut-il bloquer une brique sans preuve ? » quand
  # la vraie est « pourquoi n'y en a-t-il pas ? », a laquelle plus personne ne peut repondre.
  #
  # Les trois sorties ne valent PAS la meme chose, et c'est pour ca qu'elles se NOMMENT :
  #   - l'absence d'options de livrable ICI est une ANOMALIE, pas le cas nominal — le chemin
  #     verdict-seul ne passe pas par cette fonction ;
  #   - l'absence d'ops dit que le projet n'a pas de face atelier : un fait PERMANENT jusqu'a
  #     l'onboard, qui doit se dire aussi fort ici qu'ailleurs.
  @doc "Engraves the provenance triplet of a git deliverable on the ops face; `:ok` always, loud on every absence."
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
      # Debug visibility is a property of the BUILDER, not of this deliverable: a pod a human could
      # attach to and type into is not the same builder as an unattended one, and the triplet only
      # serves an auditor if it is falsifiable about that. Read from the single authority
      # (`Fleet.Spawner.debug_visibility?/0`), one value for a whole fleet life — so the mode at
      # completion IS the mode the pod launched under, with nothing to thread through the step_run.
      debug_visibility: Fleet.Spawner.debug_visibility?()
    }

    # Published best-effort (F-15): the statement only serves auditors if it is READABLE from the
    # forge; a push failure warns inside emit and never fails the completion. `:subject_workspace`
    # arms the BL-6-34 wall inside Provenance: the subject must be a commit reachable from the
    # workspace the publish ran in — true by construction today (the sha IS that workspace's
    # pushed HEAD), pinned against any future claimed-sha threading. A refusal is logged ERROR
    # (a proof from the wrong viewpoint is a protocol violation, not a degrade), the completion
    # itself stays unharmed either way (the deliverable is real and pushed).
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

  # The machine verdict's git write — a SIMPLE ops commit, deliberately NOT `Pinning.render`:
  # Pinning is comment-oriented (summary + pointer posted on the forge surface), and a JSON object
  # has no surface to summarize onto — its only home is the file. Same tree and basename as the
  # prose pin (`verdicts/issue-<n>-<role>.{md,json}`): one act, two renderings, side by side.
  #
  # NONE of these exits is mute except the nominal absence (no `:review_findings` = a legacy judge,
  # today's path). A judge that DID emit machine findings and finds no ops face loses the machine
  # copy — that fact is recorded loud (same doctrine as the provenance `{:work_dir_missing, _}`:
  # absence is recorded, never fabricated), and the review posts regardless: a broken or homeless
  # OPTIONAL payload never blocks a valid verdict.
  @doc "Commits a judge's machine verdict beside its prose pin; `:ok` always, loud when there is nothing or nowhere to engrave."
  @spec maybe_engrave_findings(map(), Path.t() | nil, String.t()) :: :ok
  def maybe_engrave_findings(step_run, work_dir, role) do
    case {Map.get(step_run, :review_findings), work_dir} do
      # SILENCE HERE READS "no key = a legacy judge, today's path", and that is only true while
      # `findings` is new and no SP names it. Every judge's composed SP names it, so an absence
      # is NOT a judge that never heard of the key: it is a judge that was told and did not.
      # MEASURED on the bench: a qualifier returns an excellent verdict — it names the planted
      # faux-vert structurally — and NO machine payload at all, with nothing anywhere saying so.
      #
      # That silence is what would make the verdict function of C2 blind: f reads findings, an
      # absent payload starves it, and a starved f degrades to exactly today's boolean AND while
      # LOOKING like it is weighing severities. A rail that silently stops being fed is worse than
      # one that was never built. So: loud, per verdict, naming the judge.
      {nil, _} ->
        # DEUX PHRASES, PARCE QUE CE SONT DEUX FAITS : « ce juge n'a rien envoyé » et « ce juge a
        # envoyé, le schéma a refusé en amont (`take_findings`) ». Une seule phrase accuse le juge
        # à tort dès que le schéma refuse, et envoie chercher pourquoi il se tait (mesuré sur une
        # campagne entière). Un rail qui nomme mal la panne qu'il observe coûte plus cher qu'un
        # rail muet.
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
