defmodule Fleet.Project.Onboard.Card do
  @moduledoc """
  Revises project declarations and resets CI templates through temporary main clones.
  Both operations lift direct-push protection, push, then attempt canonical protection
  restoration. These steps are not transactional; exceptions can bypass restoration.
  """

  alias Fleet.Project.GitOps
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Repo
  alias Fleet.Project.Onboard.Scaffold
  alias Fleet.Project.Roles

  require Logger

  @doc """
  Replaces CI files on main with the shipped templates, requiring a nonempty justification.

  This repairs workflows that cannot satisfy main's required CI status; templates do not
  guarantee a passing run. Unlike adoption's add-missing operation, existing files are replaced.
  Existing PR branches and the local showcase are not updated.

  CI stance comes from options/the explicitly supplied workflow map, otherwise required.
  The justification is checked but not recorded; `:reset_by` is not consumed.
  A landed push returns `:reset` with the protection restoration outcome as a string;
  an unchanged clone returns `:unchanged`.
  """
  @spec reset_ci_rail(String.t(), keyword()) ::
          {:ok, Onboard.reset_ci_result()} | {:error, term()}
  def reset_ci_rail(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Faces.code_root(opts), name)

    with :ok <- Onboard.require_on_machine(full_name, proj_dir),
         :ok <- require_justification(opts),
         {:ok, url} <- Repo.repo_url(full_name, opts) do
      scratch = scratch_dir(name)

      try do
        with :ok <- Faces.clone_main(url, scratch),
             {:ok, files} <-
               Scaffold.reset_ci_workflows(scratch, name, Onboard.with_ci_stance(full_name, opts)),
             {:ok, :changed} <- revision_changed(scratch) do
          publish_ci_rail(full_name, scratch, files, opts)
        else
          {:ok, :unchanged} ->
            {:ok, %{repo: full_name, outcome: :unchanged, files: []}}

          {:error, _} = err ->
            err
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  defp publish_ci_rail(full_name, scratch, files, opts) do
    msg = "ci(reset): rail CI remis a l'etat livre (#{Enum.join(files, ", ")})"

    with :ok <- Faces.commit(scratch, msg),
         :ok <- lift_protection(full_name, opts) do
      case Faces.push(scratch, "main", false) do
        :ok ->
          protection = restore_protection(full_name, opts)

          Logger.info(
            "ProjectOnboard: #{full_name} rail CI remis a l'etat livre — #{Enum.join(files, ", ")}"
          )

          {:ok,
           %{repo: full_name, outcome: :reset, files: files, protection: to_string(protection)}}

        {:error, reason} ->
          _ = restore_protection(full_name, opts)
          {:error, {:ci_rail_push_failed, reason}}
      end
    end
  end

  @doc """
  Revises a project card, requiring a loadable workflow map and nonempty justification.

  Writes and commits in a disposable clone. Previous card and carried max_fan come from the
  local declaration, which may lag remote main. After pushing, showcase sync is best-effort,
  then protection is rebuilt from local state; failed sync can leave the old jury in that rule.
  Existing issues retain their recorded route.

  Push errors attempt protection restoration and return an error. After a successful push,
  restoration failure is reported in the successful result. An identical declaration returns
  `:unchanged`; the recorded revision date can make a later-day repeat differ.
  """
  @spec revise_card(String.t(), keyword()) :: {:ok, Onboard.revise_result()} | {:error, term()}
  def revise_card(full_name, opts \\ []) when is_binary(full_name) do
    name = Fleet.Layout.project_name(full_name)
    proj_dir = Path.join(Faces.code_root(opts), name)
    card = Keyword.get(opts, :workflow_map)

    with :ok <- Onboard.require_on_machine(full_name, proj_dir),
         :ok <- require_justification(opts),
         :ok <- require_loadable_card(card, full_name, opts),
         {:ok, url} <- Repo.repo_url(full_name, opts) do
      previous = declared_card(proj_dir)
      scratch = scratch_dir(name)

      try do
        with :ok <- Faces.clone_main(url, scratch),
             :ok <-
               Onboard.write_declaration(
                 scratch,
                 full_name,
                 revision_write_opts(opts, current_declaration(proj_dir))
               ),
             {:ok, :changed} <- revision_changed(scratch) do
          publish_revision(full_name, scratch, card, previous, opts)
        else
          {:ok, :unchanged} ->
            {:ok, %{repo: full_name, card: card, previous_card: previous, outcome: :unchanged}}

          {:error, _} = err ->
            err
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  defp require_justification(opts) do
    case Keyword.get(opts, :justification) do
      j when is_binary(j) and j != "" -> :ok
      _ -> {:error, :justification_required}
    end
  end

  # Use Declaration's shared validation, but require a card here: creation may omit one.
  defp require_loadable_card(card, repo, opts) when is_binary(card) and card != "",
    do: Fleet.Project.Declaration.declarable_card(card, repo, opts)

  defp require_loadable_card(_absent, _repo, _opts), do: {:error, :workflow_map_required}

  defp declared_card(proj_dir) do
    with {:ok, raw} <- File.read(Path.join(proj_dir, Fleet.Layout.project_declaration_file())),
         {:ok, %{"pipeline_default" => card}} when is_binary(card) <- Jason.decode(raw) do
      card
    else
      _ -> nil
    end
  end

  defp scratch_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "lcars-card-revision-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  # Carry max_fan from the local declaration when no truthy override is supplied; composing
  # from revision options alone would silently delete it. declared_by names the last writer,
  # including for carried fields: the schema has no per-field provenance.
  # This rebuilt list drops other options, including workflow_maps_root used by preflight.
  defp revision_write_opts(opts, previous) do
    [
      workflow_map: Keyword.get(opts, :workflow_map),
      justification: Keyword.get(opts, :justification),
      max_fan: Keyword.get(opts, :max_fan) || Map.get(previous, "max_fan"),
      onboarded_by: Keyword.get(opts, :revised_by) || "unknown"
    ]
  end

  defp current_declaration(proj_dir) do
    with {:ok, raw} <- File.read(Path.join(proj_dir, Fleet.Layout.project_declaration_file())),
         {:ok, %{} = decl} <- Jason.decode(raw) do
      decl
    else
      _ -> %{}
    end
  end

  defp revision_changed(scratch) do
    case GitOps.read(["-C", scratch, "status", "--porcelain"], auth: false) do
      {:ok, ""} -> {:ok, :unchanged}
      {:ok, _dirty} -> {:ok, :changed}
      {:error, _} = err -> err
    end
  end

  defp publish_revision(full_name, scratch, card, previous, opts) do
    jury_delta = jury_delta(previous, card, opts)
    msg = "card revision: #{previous || "(undeclared)"} -> #{card}#{jury_suffix(jury_delta)}"

    with :ok <- Faces.commit(scratch, msg),
         :ok <- lift_protection(full_name, opts) do
      case Faces.push(scratch, "main", false) do
        :ok ->
          sync_showcase(full_name, opts)
          protection = restore_protection(full_name, opts)
          announce_jury_delta(full_name, previous, card, jury_delta)

          {:ok,
           %{
             repo: full_name,
             card: card,
             previous_card: previous,
             outcome: :revised,
             jury_delta: jury_delta,
             protection: protection
           }}

        {:error, reason} ->
          _ = restore_protection(full_name, opts)
          {:error, {:card_push_failed, reason}}
      end
    end
  end

  # A jury reduction is allowed but reported in the commit, log and result alongside the card.
  # An uncomputable delta is nil, not zero. This lookup uses workflow_maps_root, not repo scope.
  defp jury_delta(previous, card, opts) do
    with {:ok, before} <- jury_size(previous, opts),
         {:ok, after_} <- jury_size(card, opts) do
      after_ - before
    else
      _ -> nil
    end
  end

  defp jury_size(nil, _opts), do: :error

  defp jury_size(name, opts) do
    loader_opts = Keyword.take(opts, [:workflow_maps_root])
    {:ok, length(Roles.jury(Fleet.Workflow.Loader.load!(name, loader_opts), []))}
  rescue
    _ -> :error
  end

  defp jury_suffix(delta) when is_integer(delta) and delta < 0,
    do: " (JURY REDUIT DE #{abs(delta)} — moins de juges sur chaque livrable a venir)"

  defp jury_suffix(_not_a_reduction), do: ""

  defp announce_jury_delta(repo, previous, card, delta) when is_integer(delta) and delta < 0 do
    Logger.warning(
      "ProjectOnboard: #{repo} card revision #{previous} -> #{card} REDUCES the jury by " <>
        "#{abs(delta)} — future deliverables carry fewer judges and main-protection re-projects " <>
        "with fewer required approvals. Justified and recorded; named here because the card name " <>
        "alone does not say it."
    )

    :ok
  end

  defp announce_jury_delta(_repo, _previous, _card, _delta), do: :ok

  defp lift_protection(repo, opts) do
    rule = %{
      rule_name: "main",
      enable_push: true,
      enable_push_whitelist: true,
      push_whitelist_usernames: [Fleet.Credentials.ForgeIdentity.system_identity().name]
    }

    case Repo.repo_mod(opts).protect_branch(repo, rule, Repo.fc_opts(opts)) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> {:error, {:protection_lift_failed, reason}}
    end
  end

  defp restore_protection(repo, opts) do
    case Faces.protect_main(repo, opts) do
      :ok ->
        :restored

      {:error, reason} ->
        Logger.error(
          "ProjectOnboard: card revision of #{repo} — protection restore FAILED " <>
            "(#{inspect(reason)}) — the periodic protection pass will converge the rule"
        )

        :restore_failed
    end
  end

  defp sync_showcase(repo, opts) do
    sync =
      Keyword.get(opts, :sync_showcase, fn r -> Fleet.Project.WorktreeSync.sync_now(r, "main") end)

    case sync.(repo) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "ProjectOnboard: card revision of #{repo} landed but the showcase sync degraded " <>
            "(#{inspect(other)}) — burns read the OLD card until the next worktree sync"
        )

        :ok
    end
  catch
    kind, why ->
      Logger.warning(
        "ProjectOnboard: card revision of #{repo} landed but the showcase sync degraded " <>
          "(#{inspect(kind)}: #{inspect(why)}) — burns read the OLD card until the next worktree sync"
      )

      :ok
  end
end
