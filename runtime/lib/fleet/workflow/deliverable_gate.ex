defmodule Fleet.Workflow.DeliverableGate do
  @moduledoc """
  Reads Git ancestry, author/committer emails, optional coauthor trailers and per-commit diffs.
  Deliverable.publish stops before push on a returned failure. Checks are sequential Git reads,
  not a locked snapshot; metadata matches do not authenticate who created a commit.
  Secret scanning recognizes configured patterns only, with the limits described in scan_secrets/2.
  """

  alias Fleet.Credentials.ForgeIdentity

  @git_timeout_ms 15_000

  # Distinctive prefixes reduce false positives at a blocking gate. Unprefixed 40-hex Gitea
  # tokens resemble Git SHAs, so credential isolation must not rely on this scan detecting them.
  @secret_patterns [
    {~r/sk-ant-[A-Za-z0-9_\-]{8,}/, "anthropic_key"},
    # JWT-like prefix/segments, without signature or payload validation.
    {~r/eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{10,}/, "jwt_token"},
    {~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "private_key"},
    {~r/AKIA[0-9A-Z]{16}/, "aws_access_key"},
    # Include OAuth/tooling and GitLab families, not just classic ghp_. Length floors avoid
    # assuming one fixed token size, but character classes do not cover every possible format.
    {~r/gh[pousr]_[A-Za-z0-9]{20,}/, "github_token"},
    {~r/github_pat_[A-Za-z0-9_]{20,}/, "github_pat_fine_grained"},
    {~r/glpat-[A-Za-z0-9_\-]{20,}/, "gitlab_pat"},
    {~r/gloas-[A-Za-z0-9_\-]{20,}/, "gitlab_oauth_secret"},
    {~r/xox[baprs]-[A-Za-z0-9\-]{10,}/, "slack_token"},
    {~r/AIza[0-9A-Za-z_\-]{35}/, "google_api_key"}
  ]

  # Files forbidden in a diff (creds/secrets by name). Match on basename.
  @secret_file_re ~r/(^|\/)(\.credentials\.json|\.env(\..+)?|\.netrc|\.tok|id_rsa.*|.*\.pem|.*\.key)$/

  @type reason ::
          {:base_not_ancestor, String.t()}
          | {:bad_identity, [String.t()]}
          | {:missing_coauthor_trailer, String.t(), [String.t()]}
          | {:secret_detected, String.t(), String.t()}
          | {:forbidden_path_in_diff, String.t()}
          | {:git_error, term()}
          | {:git_timeout, term()}

  @doc """
  First error in order: ancestry, identity, optional trailer, filenames, then added-text patterns.
  Identity/trailer traversal is first-parent; secret scans traverse the full base..HEAD range,
  rendering merge diffs against first parent. Empty ranges can pass. expected_role nil skips
  trailer checking in either publication mode; other non-binary values have no clause.
  """
  @spec verify(Path.t(), String.t(), [String.t()], String.t() | nil) ::
          {:ok, :verified} | {:error, reason()}
  def verify(workspace, base_sha, allowed_emails, expected_role \\ nil) do
    with :ok <- check_base_ancestor(workspace, base_sha),
         :ok <- check_identity(workspace, base_sha, allowed_emails),
         :ok <- maybe_check_trailer(workspace, base_sha, expected_role),
         :ok <- scan_secrets(workspace, base_sha) do
      {:ok, :verified}
    end
  end

  # Trailer checking is opt-in through expected_role, independent of publication mode.
  defp maybe_check_trailer(_workspace, _base_sha, nil), do: :ok

  defp maybe_check_trailer(workspace, base_sha, role) when is_binary(role),
    do: check_coauthor_trailer(workspace, base_sha, role)

  @doc "Requires `base_sha` to be an ancestor of HEAD."
  @spec check_base_ancestor(Path.t(), String.t()) :: :ok | {:error, reason()}
  def check_base_ancestor(workspace, base_sha) do
    # Git owns rc classification; this gate shapes diagnostics.
    case Fleet.Workflow.Git.ancestor?(workspace, base_sha, "HEAD") do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        # Failure-only HEAD/parent detail distinguishes amend from a reset.
        {:error,
         {:base_not_ancestor,
          "#{String.slice(to_string(base_sha), 0, 12)} ⊄ HEAD=#{head_diag(workspace)}"}}

      {:error, {:git_timeout, _} = e} ->
        {:error, e}

      {:error, {:git_error, _} = e} ->
        {:error, e}

      # Unknown results remain hard git errors.
      {:error, other} ->
        {:error, {:git_error, "merge-base: #{inspect(other)}"}}
    end
  end

  # Best-effort failure diagnostic; it cannot replace the already-known result.
  defp head_diag(workspace) do
    case rev_parse_short(workspace, "HEAD") do
      {:ok, head} ->
        case rev_parse_short(workspace, "HEAD~1") do
          {:ok, parent} -> "#{head} (parent #{parent})"
          _ -> "#{head} (root)"
        end

      _ ->
        "unreadable"
    end
  end

  # Split calls keep a root HEAD's absent parent from poisoning its own SHA.
  defp rev_parse_short(workspace, ref) do
    case Fleet.Credentials.Shell.git(
           ["rev-parse", "--short=12", ref],
           cd: workspace,
           timeout_ms: 5_000
         ) do
      {:ok, {out, 0}} -> {:ok, String.trim(out)}
      _ -> :error
    end
  end

  @doc """
  Requires each FIRST-PARENT commit author and committer email to be allowed; empty range is valid.

  A commit whose author AND committer are BOTH the system identity passes whatever `allowed` says.
  The runtime writes on the shared faces a producer delivers from — workshop scratchpad notes,
  onboarding scaffolds — and a producer inherits those commits by aligning its face. It can neither
  remove them nor sign them, so judging them as ITS identity refuses a delivery for someone else's
  commit (measured 2026-09-16: a scratchpad note refused the deliverable of a workshop ticket).
  A commit carrying the system identity on ONE side only is still judged: a pod borrowing the
  system's name for its own work is exactly what this check exists to see.
  """
  # A0: do not demand this producer's identity on commits imported from another merge parent.
  # First-parent ancestry is the chosen cut, not proof that other parents were previously gated.
  @spec check_identity(Path.t(), String.t(), [String.t()]) :: :ok | {:error, reason()}
  def check_identity(workspace, base_sha, allowed) do
    case git(workspace, ["log", "--first-parent", "#{base_sha}..HEAD", "--format=%ae%n%ce"]) do
      {out, 0} -> identity_verdict(out, allowed)
      {out, rc} -> {:error, classify_git_error(out, rc)}
    end
  end

  defp identity_verdict("", _allowed), do: :ok

  defp identity_verdict(out, allowed) do
    allowed_set = MapSet.new(allowed)
    system = ForgeIdentity.system_email()

    bad =
      out
      # Remove only the record terminator so empty identity fields remain rejectable.
      |> String.replace_suffix("\n", "")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      # Two lines per commit (%ae then %ce): the pair is what decides, not each line alone.
      |> Enum.chunk_every(2)
      |> Enum.flat_map(&judge_commit(&1, allowed_set, system))
      |> Enum.uniq()

    # Exact membership after trimming; an empty email is rejected unless the allowed set contains "".
    case bad do
      [] -> :ok
      bad -> {:error, {:bad_identity, Enum.map(bad, &label_email/1)}}
    end
  end

  defp judge_commit([system, system], _allowed, system), do: []

  defp judge_commit(pair, allowed, _system),
    do: Enum.reject(pair, &MapSet.member?(allowed, &1))

  # Render rejected empty identity fields visibly.
  defp label_email(""), do: "<empty-email>"
  defp label_email(e), do: e

  @doc """
  Requires a Git-parsed Co-authored-by value starting with the expected LCARS-role name
  on each first-parent commit. The comparison is a prefix, not exact role/email authentication.

  A PURE system commit is skipped, for the same reason as in `check_identity/3`: the runtime writes
  on the shared faces a producer delivers from, and demanding this producer's trailer on someone
  else's commit refuses a delivery for a note it did not write.
  """
  # Same first-parent cut as identity so sibling producers need not carry this role's trailer.
  @spec check_coauthor_trailer(Path.t(), String.t(), String.t()) :: :ok | {:error, reason()}
  def check_coauthor_trailer(workspace, base_sha, expected_role) when is_binary(expected_role) do
    # F-03: use Git's trailer parser rather than searching the whole commit message.
    needle =
      ForgeIdentity.coauthor_trailer(expected_role)
      |> String.replace_prefix("Co-authored-by: ", "")
      |> String.split(" <")
      |> hd()

    # NUL separates commits, unit separator splits SHA and trailer values.
    case git(workspace, [
           "log",
           "--first-parent",
           "#{base_sha}..HEAD",
           "--format=%H%x1f%ae%x1f%ce%x1f%(trailers:key=Co-authored-by,valueonly)%x00"
         ]) do
      {out, 0} ->
        systeme = ForgeIdentity.system_email()

        missing =
          out
          |> String.split(<<0>>, trim: true)
          |> Enum.flat_map(&uncovered_sha(&1, needle, systeme))

        case missing do
          [] -> :ok
          shas -> {:error, {:missing_coauthor_trailer, expected_role, shas}}
        end

      {out, rc} ->
        {:error, classify_git_error(out, rc)}
    end
  end

  @doc """
  Scans per-commit filenames and added text, catching introduction then removal that a net diff
  would miss. Full range traversal includes side-parent commits; merge diffs use first parent.
  Filenames are split on LF without unquoting Git's escaped names. Text keeps + lines except +++
  lines, which also drops additions whose content begins ++. Binary/non-added content, passwords,
  connection strings and unrecognized token formats are outside the scan. :ok is no detected match,
  not a clean bill. Existing base content and dirty worktree files are not scanned.
  """
  @spec scan_secrets(Path.t(), String.t()) :: :ok | {:error, reason()}
  def scan_secrets(workspace, base_sha) do
    with :ok <- scan_secret_filenames(workspace, base_sha) do
      scan_secret_content(workspace, base_sha)
    end
  end

  defp scan_secret_filenames(workspace, base_sha) do
    # --diff-merges changes merge rendering; it does not restrict traversal to --first-parent.
    case git(workspace, [
           "log",
           "-p",
           "--name-only",
           "--diff-merges=first-parent",
           "--pretty=format:",
           "#{base_sha}..HEAD"
         ]) do
      {out, 0} ->
        files = String.split(out, "\n", trim: true)

        # BL-6-16: reuse the filename listing for governance-path checks, including deletions.
        forbidden_file(files)

      {out, rc} ->
        {:error, classify_git_error(out, rc)}
    end
  end

  # Producers must not change their governance: any .claude component, nested CLAUDE.md, or
  # root .lcars.json. That declaration selects pipeline_default, hence the next ticket's jury/CI.
  # Root CLAUDE.md remains project documentation; nested .lcars.json is not the declaration.
  # Direct human edits outside this publication path are not governed by this check.
  defp forbidden_governance_path?(path) do
    segments = Path.split(path)

    ".claude" in segments or
      (Path.basename(path) == "CLAUDE.md" and length(segments) > 1) or
      segments == [Fleet.Layout.project_declaration_file()]
  end

  defp scan_secret_content(workspace, base_sha) do
    case git(workspace, [
           "log",
           "-p",
           "--unified=0",
           "--diff-merges=first-parent",
           "--pretty=format:",
           "#{base_sha}..HEAD"
         ]) do
      {out, 0} ->
        added =
          out
          |> String.split("\n")
          |> Enum.filter(&(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
          |> Enum.join("\n")

        refuse_secret(added, "diff added lines")

      {out, rc} ->
        {:error, classify_git_error(out, rc)}
    end
  end

  # Fixed safe-config arguments and per-call timeout; the injected runner can override execution.
  @hooks_off Fleet.Credentials.Shell.git_safe_config_args()

  defp git(workspace, args) do
    # Shell kills the git process group at the deadline; timeout remains distinct from git failure.
    runner =
      Application.get_env(
        :lcars_fleet,
        :workflow_deliverable_gate_git_runner,
        &Fleet.Credentials.Shell.git/2
      )

    case runner.(@hooks_off ++ ["-C", workspace] ++ args, timeout_ms: @git_timeout_ms) do
      {:ok, {out, code}} -> {out, code}
      {:error, {:timeout, ms}} -> {"git timeout (#{ms}ms)", 124}
      {:error, {:exit, reason}} -> {"git exec error: #{inspect(reason)}", 125}
      # Preserve future Shell errors as hard git failures.
      {:error, reason} -> {"git shell error: #{inspect(reason)}", 125}
    end
  end

  # First matching pattern in declaration order, with its kind rather than the matched secret.
  defp refuse_secret(texte, ou) do
    case Enum.find_value(@secret_patterns, &matched_secret_kind(&1, texte)) do
      nil -> :ok
      kind -> {:error, {:secret_detected, kind, ou}}
    end
  end

  # Governance rejection precedes the secret-filename blacklist so the diagnostic names that rule.
  defp forbidden_file(files) do
    cond do
      f = Enum.find(files, &forbidden_governance_path?/1) ->
        {:error, {:forbidden_path_in_diff, f}}

      f = Enum.find(files, &Regex.match?(@secret_file_re, &1)) ->
        {:error, {:secret_detected, "blacklisted_file", f}}

      true ->
        :ok
    end
  end

  defp matched_secret_kind({re, kind}, texte), do: if(Regex.match?(re, texte), do: kind)

  # Chunks without the expected separator are ignored, not reported as missing trailers.
  defp uncovered_sha(chunk, needle, systeme) do
    case String.split(chunk, <<0x1F>>, parts: 4) do
      [_sha, ae, ce, _values] when ae == systeme and ce == systeme ->
        []

      [sha, _ae, _ce, values] ->
        couvert? =
          values
          |> String.split("\n", trim: true)
          |> Enum.any?(&(String.trim_leading(&1) |> String.starts_with?(needle)))

        if couvert?, do: [], else: [String.trim(sha)]

      _ ->
        []
    end
  end

  # Synthetic rc 124 denotes timeout; all other nonzero codes are git errors.
  defp classify_git_error(out, 124), do: {:git_timeout, String.trim(out)}
  defp classify_git_error(out, _rc), do: {:git_error, String.trim(out)}
end
