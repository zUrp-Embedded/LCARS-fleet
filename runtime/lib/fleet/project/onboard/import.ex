defmodule Fleet.Project.Onboard.Import do
  @moduledoc """
  Copies external or personal-space repositories into a new catalogue-org repository.
  Sources are retained. Both entry points share adoption checks and finish steps; returned
  finish errors attempt deletion of the new destination and three local faces. Exceptions
  bypass that compensation, while scratch cleanup is attempted in after.
  """

  alias Fleet.Credentials.Shell
  alias Fleet.Project.Onboard
  alias Fleet.Project.Onboard.Faces
  alias Fleet.Project.Onboard.Repo

  require Logger

  @doc """
  Copies a public personal-space source into an installed catalogue org.
  Source must be owner/name outside installed catalogue orgs. The destination name defaults
  to the source basename and may be overridden with name.

  Personal-space content passes the same adoption gate as an external repository:
  internal transport does not establish trusted provenance. The source is not consumed.
  The visibility probe precedes destination name/card admission, unlike import_external.
  """
  @spec import_deposit(String.t(), String.t(), keyword()) ::
          {:ok, Onboard.result()} | {:error, term()}
  def import_deposit(source, catalogue, opts \\ [])
      when is_binary(source) and is_binary(catalogue) do
    with {:ok, owner, src_name} <- split_repo(source),
         :ok <- refute_source_in_org(owner, source),
         :ok <- require_destination_catalogue(catalogue),
         # Source syntax and catalogue checks are local; destination name/card checks occur after this read.
         :ok <- require_public_source(source, opts) do
      name = Keyword.get(opts, :name, src_name)
      full_name = "#{catalogue}/#{name}"
      dirs = Faces.face_dirs(name, opts)

      with :ok <- Onboard.admit(catalogue, name, opts),
           :ok <- Repo.ensure_catalogue_org_on_forge(catalogue, opts),
           :ok <- require_machine_absent(full_name, dirs),
           :ok <- Repo.require_forge_absent(full_name, opts),
           {:ok, source_url} <- Repo.repo_url(source, opts) do
        scratch = external_scratch_dir(name)

        try do
          with :ok <- clone_deposit(source_url, scratch, opts),
               :ok <- adoption_gate(scratch),
               :ok <- normalize_default_branch(scratch),
               {:ok, forge_url} <- Repo.repo_url(full_name, opts),
               {:ok, full_name} <- Repo.create_empty_repo(name, catalogue, opts) do
            case finish_external(
                   full_name,
                   forge_url,
                   scratch,
                   dirs,
                   name,
                   Keyword.put(opts, :source_host, "depot:#{owner}")
                 ) do
              {:ok, result} ->
                {:ok, Map.put(result, :from, source)}

              {:error, reason} = err ->
                compensate_external(full_name, dirs, reason, opts)
                err
            end
          end
        after
          _ = File.rm_rf(scratch)
        end
      end
    end
  end

  @doc """
  Lists user repositories whose basenames are absent from every installed catalogue org.
  Name-based suppression avoids repeatedly offering the retained source copy; it is not a
  content or provenance comparison and can suppress unrelated same-name repositories.

  Reports name admissibility and guidance before import. It does not check source visibility
  or adoption material. An unreadable catalogue org aborts the listing rather than widening it.
  """
  @spec deposit_candidates(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def deposit_candidates(human, opts \\ []) when is_binary(human) do
    repo = Repo.repo_mod(opts)
    fc = Repo.fc_opts(opts)

    with {:ok, mine} <- repo.list_user_repos(human, fc),
         {:ok, enrolled} <- enrolled_names(repo, fc) do
      {:ok,
       mine
       |> Enum.reject(&(Fleet.Layout.project_name(&1) in enrolled))
       |> Enum.sort()
       |> Enum.map(&describe_candidate/1)}
    end
  end

  defp describe_candidate(full_name) do
    name = Fleet.Layout.project_name(full_name)

    case Onboard.validate_name(name) do
      :ok ->
        %{"source" => full_name, "name" => name, "admissible" => true}

      {:error, {:invalid_name, _}} ->
        %{
          "source" => full_name,
          "name" => name,
          "admissible" => false,
          "reason" =>
            "le nom doit être en kebab-case minuscule (`[a-z0-9]`, tirets internes) — " <>
              "renomme le dépôt sur la forge, ou donne-lui son nom de destination à l'import"
        }
    end
  end

  defp enrolled_names(repo, fc) do
    Enum.reduce_while(Onboard.installed_orgs(), {:ok, MapSet.new()}, fn org, {:ok, acc} ->
      case repo.list_org_repos(org, fc) do
        {:ok, names} ->
          {:cont, {:ok, Enum.into(Enum.map(names, &Fleet.Layout.project_name/1), acc)}}

        {:error, reason} ->
          {:halt, {:error, {:enrolled_scan_failed, org, reason}}}
      end
    end)
  end

  defp split_repo(full_name) do
    case String.split(full_name, "/") do
      [owner, name] when owner != "" and name != "" -> {:ok, owner, name}
      _ -> {:error, {:not_a_repo_name, full_name}}
    end
  end

  # A source in an installed catalogue org belongs to the import/migrate paths.
  defp refute_source_in_org(owner, source) do
    if owner in Onboard.installed_orgs(),
      do: {:error, {:source_already_enrolled, source, owner}},
      else: :ok
  end

  defp require_destination_catalogue(catalogue), do: Onboard.require_installed(catalogue)

  # Probe visibility before authenticated cloning: successful access does not authorize
  # copying private source content into an org repository with different visibility.
  defp require_public_source(source, opts) do
    case Repo.repo_mod(opts).private?(source, Repo.fc_opts(opts)) do
      {:ok, false} -> :ok
      {:ok, true} -> {:error, {:deposit_not_public, source}}
      {:error, reason} -> {:error, {:deposit_visibility_unreadable, source, reason}}
    end
  end

  defp clone_deposit(url, scratch, opts) do
    timeout = Keyword.get(opts, :clone_timeout_ms, 120_000)

    case Shell.git(["clone", "--no-recurse-submodules", url, scratch],
           timeout_ms: timeout
         ) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {out, code}} ->
        {:error, {:deposit_clone_failed, {code, String.slice(out, 0, 500)}}}

      {:error, reason} ->
        {:error, {:deposit_clone_failed, reason}}
    end
  end

  # User-defined external host perimeter; changing it is a deliberate scope change.
  @external_hosts ~w(github.com gitlab.com)

  @doc """
  Copies an external repository into a new catalogue-org project; it is not a mirror.

  The default URL gate accepts https on #{inspect(@external_hosts)}. Git clones without
  recursive submodules into a scratch directory using inherited credential-helper setup;
  clone_timeout_ms defaults to 120000. Adoption refuses .claude directories and scans
  CLAUDE.md files with ReceptionFilter, excluding .git paths. This is a bounded material
  check, not validation of the whole repository.

  Keeps main if it is current; otherwise renames the default branch unless origin/main
  already exists, which returns branch_collision. Publishes that main history, not all refs.
  Creates an empty destination, seeds labels, adds missing declaration/CI files, pushes,
  then imports local faces and applies protection.

  Existing local paths or a known forge destination are refusals. After successful creation,
  returned finish errors attempt direct forge deletion and all three local cleanups.
  Cleanup outcomes are logged; they do not replace the original error or guarantee a clean retry.
  Scratch removal is attempted in after, including exceptions; process death can bypass it.
  """
  @spec import_external(String.t(), String.t(), keyword()) ::
          {:ok, Onboard.result()} | {:error, term()}
  def import_external(url, name, opts \\ []) when is_binary(url) and is_binary(name) do
    dirs = Faces.face_dirs(name, opts)
    # Tests can override the URL gate for file:// fixtures.
    url_gate = Keyword.get(opts, :url_gate, &default_external_url_gate/1)

    with {:ok, org} <- Onboard.required_org(opts),
         :ok <- Onboard.admit(org, name, opts),
         full_name = "#{org}/#{name}",
         :ok <- url_gate.(url),
         :ok <- Repo.ensure_catalogue_org_on_forge(org, opts),
         :ok <- require_machine_absent(full_name, dirs),
         :ok <- Repo.require_forge_absent(full_name, opts) do
      scratch = external_scratch_dir(name)

      try do
        with :ok <- clone_external(url, scratch, opts),
             :ok <- adoption_gate(scratch),
             :ok <- normalize_default_branch(scratch),
             {:ok, forge_url} <- Repo.repo_url(full_name, opts),
             {:ok, full_name} <- Repo.create_empty_repo(name, org, opts) do
          source_host =
            case URI.parse(url).host do
              h when h in [nil, ""] -> "external"
              h -> h
            end

          case finish_external(
                 full_name,
                 forge_url,
                 scratch,
                 dirs,
                 name,
                 Keyword.put(opts, :source_host, source_host)
               ) do
            {:ok, result} ->
              {:ok, result}

            {:error, reason} = err ->
              compensate_external(full_name, dirs, reason, opts)
              err
          end
        end
      after
        _ = File.rm_rf(scratch)
      end
    end
  end

  # Keep provenance-specific commit wording for the shared external/deposit finish path.
  defp declaration_commit_message(opts) do
    door =
      case Keyword.get(opts, :source_host, "") do
        "depot:" <> _ -> "import-depot"
        _ -> "import-externe"
      end

    "chore(#{door}): déclaration de criticité (.lcars.json)"
  end

  defp finish_external(full_name, forge_url, scratch, dirs, name, opts) do
    with :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         :ok <- Repo.seed_protocol_labels(full_name, opts),
         :ok <-
           Onboard.ensure_declaration(scratch, full_name, opts, declaration_commit_message(opts)),
         :ok <-
           Onboard.ensure_ci_workflows(
             scratch,
             name,
             Onboard.with_ci_stance(full_name, opts),
             "ci(import): rail CI du depot (.gitea/workflows)"
           ),
         :ok <- Faces.set_origin(scratch, forge_url),
         :ok <- Faces.push(scratch, "main", true),
         :ok <- Fleet.Forge.WriteSpacing.gap(opts),
         {:ok, result} <- Onboard.finish_import(full_name, dirs, name, opts) do
      Logger.info(
        "ProjectOnboard: #{full_name} imported from EXTERNAL " <>
          "#{Keyword.get(opts, :source_host, "external")} — history preserved, origin " <>
          "re-pointed at the org (the source URL is never logged: it may carry the operator token)"
      )

      {:ok, result}
    end
  end

  defp default_external_url_gate(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, {:unsupported_forge, {:scheme, uri.scheme}}}
      uri.host in @external_hosts -> :ok
      true -> {:error, {:unsupported_forge, uri.host}}
    end
  end

  defp require_machine_absent(full_name, dirs) do
    if Enum.any?([dirs.code, dirs.ops, dirs.workshop], &File.exists?/1),
      do: {:error, {:already_on_machine, full_name}},
      else: :ok
  end

  # Scratch is unique within this VM; destination absence probes do not serialize concurrent imports.
  defp external_scratch_dir(name) do
    Path.join(
      System.tmp_dir!(),
      "lcars-import-#{name}-#{:erlang.unique_integer([:positive])}"
    )
  end

  defp clone_external(url, scratch, opts) do
    timeout = Keyword.get(opts, :clone_timeout_ms, 120_000)

    # Shell.git uses ForgeAuth's anti-prompt environment and configured internal-host auth;
    # external authentication depends on inherited credential helpers. Clone error output is
    # returned in bounded form and may contain the URL, despite the success log omitting it.
    case Shell.git(
           ["clone", "--no-recurse-submodules", url, scratch],
           timeout_ms: timeout
         ) do
      {:ok, {_, 0}} ->
        :ok

      {:ok, {out, code}} ->
        {:error, {:external_clone_failed, {code, String.slice(out, 0, 500)}}}

      {:error, reason} ->
        {:error, {:external_clone_failed, reason}}
    end
  end

  # Scan instruction material only, to avoid broad code/README false positives.
  # .gitmodules is not inspected; this clone does not fetch submodules. Any matched .claude
  # directory is refused, even empty; a regular file named .claude is not covered.
  defp adoption_gate(scratch) do
    case foreign_claude_dirs(scratch) do
      [] -> scan_claude_mds(scratch)
      dirs -> {:error, {:foreign_claude_dir, dirs}}
    end
  end

  defp foreign_claude_dirs(scratch) do
    scratch
    |> Path.join("**/.claude")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, scratch))))
    |> Enum.filter(&File.dir?/1)
    |> Enum.map(&Path.relative_to(&1, scratch))
  end

  defp scan_claude_mds(scratch) do
    scratch
    |> Path.join("**/CLAUDE.md")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&(".git" in Path.split(Path.relative_to(&1, scratch))))
    |> Enum.reduce_while(:ok, &scan_one_md(&1, &2, scratch))
  end

  defp scan_one_md(path, :ok, scratch) do
    rel = Path.relative_to(path, scratch)

    case File.read(path) do
      {:ok, content} -> filter_verdict(Fleet.ReceptionFilter.scan(content), rel)
      {:error, reason} -> {:halt, {:error, {:unreadable_material, rel, reason}}}
    end
  end

  defp filter_verdict(:clean, _rel), do: {:cont, :ok}

  defp filter_verdict({:match, label, _excerpt}, rel),
    do: {:halt, {:error, {:hostile_material, label, rel}}}

  defp rename_to_main(scratch, head) do
    case Shell.git(["-C", scratch, "branch", "-m", head, "main"], env: []) do
      {:ok, {_, 0}} -> :ok
      {:ok, {out, code}} -> {:error, {:branch_rename_failed, {code, String.slice(out, 0, 300)}}}
      {:error, reason} -> {:error, {:branch_rename_failed, reason}}
    end
  end

  # If default differs from main but origin/main exists, let the operator resolve the ambiguity.
  defp normalize_default_branch(scratch) do
    with {:ok, {head_out, 0}} <-
           Shell.git(["-C", scratch, "symbolic-ref", "--short", "HEAD"],
             env: []
           ),
         {:ok, {remotes_out, 0}} <-
           Shell.git(
             ["-C", scratch, "branch", "-r", "--format=%(refname:short)"],
             env: []
           ) do
      head = String.trim(head_out)
      remote_main? = "origin/main" in String.split(remotes_out, "\n", trim: true)

      cond do
        head == "main" -> :ok
        remote_main? -> {:error, {:branch_collision, {head, "main"}}}
        true -> rename_to_main(scratch, head)
      end
    else
      other -> {:error, {:default_branch_unreadable, other}}
    end
  end

  # Delete the newly created repo directly: an empty repo can look absent to a default-branch probe.
  # Cleanup failures are logged; the caller still receives the original finish error.
  defp compensate_external(full_name, dirs, reason, opts) do
    forge =
      case Repo.repo_mod(opts).delete_repo(full_name, Repo.fc_opts(opts)) do
        :ok -> :deleted
        {:error, e} -> {:delete_failed, e}
      end

    Logger.warning(
      "ProjectOnboard: import_external #{full_name} FAILED (#{inspect(reason)}) — compensated: " <>
        "forge #{inspect(forge)}, project_dir #{inspect(Faces.compensate_dir(dirs.code))}, " <>
        "work_dir #{inspect(Faces.compensate_dir(dirs.ops))}, " <>
        "doc_dir #{inspect(Faces.compensate_dir(dirs.workshop))} (a clean retry is possible)"
    )
  end
end
